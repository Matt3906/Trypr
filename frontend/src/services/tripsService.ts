import {
  addDoc, collection, deleteDoc, doc, getDoc, onSnapshot, orderBy, query, setDoc, updateDoc,
  type DocumentData, type DocumentReference, type QueryDocumentSnapshot,
} from 'firebase/firestore'
import { auth, db } from '@/firebase'
import { tripFromMap, tripToMap, type TripModel } from '@/models/tripModel'

const userTripsRef = () => {
  const uid = auth.currentUser?.uid
  return uid ? collection(db, 'users', uid, 'trips') : null
}

export function tripRefPathFromData(data: DocumentData): string | null {
  const raw = data.tripRef
  if (typeof raw === 'string') return raw.trim() || null
  if (raw && typeof raw === 'object' && 'path' in raw) return (raw as DocumentReference).path
  const v = raw == null ? '' : String(raw).trim()
  return v || null
}

async function tripModelForDoc(d: QueryDocumentSnapshot): Promise<TripModel> {
  const local = d.data()
  const tripRefPath = tripRefPathFromData(local)
  const hasLocalWaypoints = Array.isArray(local.waypoints) && local.waypoints.length > 0
  const hasRoutingMetadata =
    local.transportMode != null ||
    Array.isArray(local.segmentTransportModes) ||
    Array.isArray(local.segmentRoutingTypes) ||
    Array.isArray(local.routeVia)

  if (hasLocalWaypoints && (hasRoutingMetadata || tripRefPath == null)) return tripFromMap(local, d.id)
  if (tripRefPath == null) return tripFromMap(local, d.id)

  try {
    const remoteDoc = await getDoc(doc(db, tripRefPath))
    if (!remoteDoc.exists()) return tripFromMap(local, d.id)
    const remote = remoteDoc.data() ?? {}
    const merged: Record<string, any> = { ...remote, ...local }
    const remoteWaypoints = remote.waypoints ?? remote.stops
    if (Array.isArray(remoteWaypoints) && remoteWaypoints.length) merged.waypoints = remoteWaypoints
    for (const k of ['transportMode', 'segmentTransportModes', 'segmentRoutingTypes', 'routeVia'] as const) {
      if (local[k] == null && remote[k] != null && (k === 'transportMode' || Array.isArray(remote[k]))) merged[k] = remote[k]
    }
    return tripFromMap(merged, d.id)
  } catch {
    return tripFromMap(local, d.id)
  }
}

/** Live list of the signed-in user's trips (newest first). Returns an unsubscribe fn. */
export function subscribeTrips(onData: (t: TripModel[]) => void, onError?: (e: Error) => void): () => void {
  const ref = userTripsRef()
  if (!ref) {
    onData([])
    return () => {}
  }
  return onSnapshot(
    query(ref, orderBy('createdAt', 'desc')),
    async (snap) => onData(await Promise.all(snap.docs.map(tripModelForDoc))),
    (e) => onError?.(e),
  )
}

export async function getTripById(tripId: string): Promise<TripModel | null> {
  try {
    const ref = userTripsRef()
    if (!ref) return null
    const d = await getDoc(doc(ref, tripId))
    return d.exists() ? tripFromMap(d.data(), d.id) : null
  } catch (e) {
    console.debug('Error fetching trip', e)
    return null
  }
}

export async function createTrip(trip: TripModel): Promise<string> {
  const ref = userTripsRef()
  if (!ref) throw new Error('User not signed in')
  return (await addDoc(ref, tripToMap(trip))).id
}

export async function updateTrip(tripId: string, trip: TripModel): Promise<void> {
  const ref = userTripsRef()
  if (!ref) throw new Error('User not signed in')
  await updateDoc(doc(ref, tripId), tripToMap(trip))
}

export async function deleteTrip(tripId: string): Promise<void> {
  const ref = userTripsRef()
  if (!ref) throw new Error('User not signed in')
  await deleteDoc(doc(ref, tripId))
}

/**
 * Hydrate a user's trip doc from the canonical `tripRef` doc when waypoints/routing
 * metadata are missing, writing the filled-in fields back (used when opening a trip).
 */
export async function resolveTripDataForOpen(userUid: string, tripId: string, local: Record<string, any>): Promise<Record<string, any>> {
  const hasWaypoints = Array.isArray(local.waypoints) && local.waypoints.length > 0
  const tripRefPath = tripRefPathFromData(local)
  if (tripRefPath == null) return local

  const needsHydration =
    !hasWaypoints || local.transportMode == null || local.segmentTransportModes == null ||
    local.segmentRoutingTypes == null || local.routeVia == null
  if (!needsHydration) return local

  try {
    const remoteDoc = await getDoc(doc(db, tripRefPath))
    if (!remoteDoc.exists()) return local
    const remote = remoteDoc.data() ?? {}
    const merged: Record<string, any> = { ...remote, ...local }
    const sync: Record<string, any> = {}
    const take = (k: string, cond = true) => {
      if (cond) {
        merged[k] = remote[k]
        sync[k] = remote[k]
      }
    }

    const remoteWaypoints = remote.waypoints ?? remote.stops
    if (!hasWaypoints && Array.isArray(remoteWaypoints) && remoteWaypoints.length) {
      merged.waypoints = remoteWaypoints
      sync.waypoints = remoteWaypoints
    }
    if (local.startDate == null && remote.startDate != null) take('startDate')
    if (local.endDate == null && remote.endDate != null) take('endDate')
    if (local.totalKm == null && remote.totalKm != null) take('totalKm')
    if (local.transportMode == null && remote.transportMode != null) take('transportMode')
    if (local.segmentTransportModes == null && Array.isArray(remote.segmentTransportModes)) take('segmentTransportModes')
    if (local.segmentRoutingTypes == null && Array.isArray(remote.segmentRoutingTypes)) take('segmentRoutingTypes')
    if (local.routeVia == null && Array.isArray(remote.routeVia)) take('routeVia')
    if (local.transitArrivalStop == null && remote.transitArrivalStop != null) take('transitArrivalStop')

    if (Object.keys(sync).length) {
      await setDoc(doc(db, 'users', userUid, 'trips', tripId), sync, { merge: true })
    }
    merged.tripRef = tripRefPath
    return merged
  } catch {
    return local
  }
}

const resolveCache = new Map<string, { key: string; promise: Promise<Record<string, any>> }>()

/** Like resolveTripDataForOpen but also hydrates route cache fields; memoized per doc revision (My Trips cards). */
export function resolvedTripData(userUid: string, docId: string, data: Record<string, any>): Promise<Record<string, any>> {
  const tripRef = tripRefPathFromData(data) ?? ''
  const wp = Array.isArray(data.waypoints) ? data.waypoints.length : 0
  const updated = String(data.updatedAt ?? data.createdAt ?? '')
  const key = `${docId}|${tripRef}|${wp}|${updated}`
  const existing = resolveCache.get(docId)
  if (existing && existing.key === key) return existing.promise
  const promise = resolveImpl(userUid, docId, data)
  resolveCache.set(docId, { key, promise })
  return promise
}

async function resolveImpl(userUid: string, docId: string, local: Record<string, any>): Promise<Record<string, any>> {
  const out = { ...local }
  const tripRefPath = tripRefPathFromData(out)
  if (tripRefPath == null) return out
  const hasWp = Array.isArray(out.waypoints) && out.waypoints.length > 0
  const needs =
    !hasWp || out.transportMode == null || out.segmentTransportModes == null || out.segmentRoutingTypes == null ||
    out.routeVia == null || out.routeGeometry3d == null || out.routeInstructions == null || out.routeCacheKey == null
  if (!needs) return out
  try {
    const remoteDoc = await getDoc(doc(db, tripRefPath))
    if (!remoteDoc.exists()) return out
    const remote = remoteDoc.data() ?? {}
    const merged: Record<string, any> = { ...remote, ...out }
    const sync: Record<string, any> = {}
    const remoteWp = remote.waypoints ?? remote.stops
    if (!(Array.isArray(local.waypoints) && local.waypoints.length) && Array.isArray(remoteWp) && remoteWp.length) {
      merged.waypoints = remoteWp
      sync.waypoints = remoteWp
    }
    for (const k of [
      'startDate', 'endDate', 'totalKm', 'transportMode', 'tripType', 'experienceLevel', 'segmentTransportModes', 'estimatedDurationMin',
      'segmentRoutingTypes', 'routeVia', 'routeGeometry3d', 'routeInstructions', 'routeCacheKey', 'transitArrivalStop',
    ]) {
      if (local[k] == null && merged[k] != null) sync[k] = merged[k]
    }
    merged.tripRef = tripRefPath
    if (Object.keys(sync).length) await setDoc(doc(db, 'users', userUid, 'trips', docId), sync, { merge: true })
    return merged
  } catch {
    return out
  }
}
