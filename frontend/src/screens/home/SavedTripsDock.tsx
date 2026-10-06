import { useEffect, useState } from 'react'
import { collection, limit, onSnapshot, orderBy, query } from 'firebase/firestore'
import { MdAddCircleOutline, MdBookmarkBorder, MdPlace, MdVerified } from 'react-icons/md'
import { db } from '@/firebase'
import { useAuth } from '@/context/Auth'
import { Spinner, cx } from '@/components/ui'
import {
  inferTripDifficultyLabel, isAdventureTripType, normalizeTripType, tripFormattedDates, tripTypeBadgeLabel, type TripModel,
} from '@/models/tripModel'
import { subscribeTrips } from '@/services/tripsService'

export type DockTrip = Record<string, any>

const EMOJIS = ['✈️', '🌎', '🗺️', '🧳', '🌴', '🏔️', '🌅', '🎒']
const PALETTES: [string, string][] = [
  ['#667eea', '#764ba2'], ['#f093fb', '#f5576c'], ['#4facfe', '#00f2fe'], ['#43e97b', '#38f9d7'],
  ['#fa709a', '#fee140'], ['#a18cd1', '#fbc2eb'], ['#ffecd2', '#fcb69f'], ['#89f7fe', '#66a6ff'],
]

const javaHash = (s: string) => {
  let h = 0
  for (let i = 0; i < s.length; i++) h = (Math.imul(31, h) + s.charCodeAt(i)) | 0
  return Math.abs(h)
}

function tripEmoji(title: string): string {
  const t = title.toLowerCase()
  const has = (...k: string[]) => k.some((x) => t.includes(x))
  if (has('beach', 'island', 'coast')) return '🏖️'
  if (has('mountain', 'hiking', 'trek')) return '⛰️'
  if (has('city', 'urban', 'york', 'london', 'paris', 'tokyo')) return '🏙️'
  if (has('road', 'drive')) return '🚗'
  if (has('camp')) return '⛺'
  if (has('ski', 'snow')) return '🎿'
  if (has('safari', 'jungle', 'wildlife')) return '🦁'
  if (has('cruise', 'sail', 'boat')) return '🚢'
  if (t.includes('europe')) return '🇪🇺'
  if (t.includes('asia')) return '🌏'
  if (t.includes('africa')) return '🌍'
  return EMOJIS[javaHash(title) % EMOJIS.length]
}

function formatDistance(km: number | null | undefined, stopCount: number): string {
  if (stopCount < 2 || km == null || km <= 0) return 'No route yet'
  if (km < 1) return `${Math.round(km * 1000)} m`
  return `${km.toFixed(0)} km`
}

function DockCard({ compact, title, stops, distance, date, badge, difficulty, selected, onClick }: {
  compact: boolean; title: string; stops: number; distance: string; date: string; badge?: string; difficulty?: string | null; selected: boolean; onClick: () => void
}) {
  const [c0, c1] = PALETTES[javaHash(title) % PALETTES.length]
  const a = selected ? 0.85 : 0.65
  const mix = (c: string) => `color-mix(in srgb, ${c} ${a * 100}%, transparent)`
  return (
    <button
      type="button"
      className={cx('dock-card', selected && 'selected', compact && 'compact')}
      aria-pressed={selected}
      onClick={onClick}
      style={{
        background: `linear-gradient(135deg, ${mix(c0)}, ${mix(c1)})`,
        boxShadow: `0 6px ${selected ? 24 : 12}px color-mix(in srgb, ${c0} ${selected ? 40 : 15}%, transparent)`,
      }}
    >
      <div style={{ fontSize: compact ? 16 : 18 }}>{tripEmoji(title)}</div>
      <div className="dock-title" style={{ fontSize: compact ? 11 : 12 }}>{title}</div>
      <div className="row" style={{ gap: 4, color: 'rgba(255,255,255,.7)', fontSize: compact ? 8 : 9, fontWeight: 500, marginTop: 3 }}>
        <MdPlace size={compact ? 9 : 10} /> {stops} stops
        {distance && <><span style={{ opacity: .5 }}>·</span><span className="ellipsis">{distance}</span></>}
      </div>
      {(badge || difficulty) && (
        <div className="row wrap" style={{ gap: 6, marginTop: 5 }}>
          {badge && <span className="dock-badge primary" style={{ fontSize: compact ? 8 : 9 }}>{badge}</span>}
          {difficulty && <span className="dock-badge" style={{ fontSize: compact ? 8 : 9 }}>{difficulty}</span>}
        </div>
      )}
      {date && <div className="dock-date" style={{ fontSize: compact ? 8 : 9 }}>{date}</div>}
    </button>
  )
}

export default function SavedTripsDock({ compact, selectedTripId, onTripSelected }: { compact: boolean; selectedTripId?: string | null; onTripSelected: (t: DockTrip) => void }) {
  const { user } = useAuth()
  const [trips, setTrips] = useState<TripModel[] | null>(null)
  const [error, setError] = useState(false)
  const [verified, setVerified] = useState<{ id: string; data: Record<string, any> }[] | null>(null)

  useEffect(() => {
    if (!user) {
      setTrips(null)
      return
    }
    setError(false)
    return subscribeTrips(setTrips, () => setError(true))
  }, [user?.uid])

  useEffect(
    () =>
      onSnapshot(
        query(collection(db, 'verifiedTrips'), orderBy('createdAt', 'desc'), limit(10)),
        (s) => setVerified(s.docs.map((d) => ({ id: d.id, data: d.data() }))),
        () => setVerified([]),
      ),
    [],
  )

  const empty = (text: string, icon?: React.ReactNode) => <div className="dock-empty">{icon}{text}</div>

  return (
    <div className={cx('saved-dock', compact && 'compact')}>
      <div className="dock-label"><MdBookmarkBorder size={16} /> Your Trips</div>
      <div className="dock-row user">
        {!user ? empty('Sign in to see your trips')
          : error ? empty('Could not load trips')
          : trips == null ? <div className="center grow"><Spinner size="sm" white /></div>
          : trips.length === 0 ? empty('No trips yet — start planning!', <MdAddCircleOutline size={20} />)
          : trips.map((t) => {
              const tripType = normalizeTripType(t.tripType, { transportMode: t.transportMode, segmentTransportModes: t.segmentTransportModes })
              const difficulty = inferTripDifficultyLabel({
                tripType, experienceLevel: t.experienceLevel, distanceKm: t.distance,
                estimatedDurationMin: t.estimatedDurationMin, stopCount: t.stops.length, segmentTransportModes: t.segmentTransportModes,
              })
              const waypoints = t.stops.map((s) => ({ lat: s.latitude, lon: s.longitude, name: s.placeName }))
              const trip: DockTrip = {
                id: t.id, title: t.tripName, waypoints, stops: waypoints.length, distance: t.distance,
                startDate: t.startDate, endDate: t.endDate, description: t.description,
                ...(t.transportMode != null ? { transportMode: t.transportMode } : {}),
                ...(t.segmentTransportModes != null ? { segmentTransportModes: t.segmentTransportModes } : {}),
                ...(t.segmentRoutingTypes != null ? { segmentRoutingTypes: t.segmentRoutingTypes } : {}),
                ...(t.tripType != null ? { tripType: t.tripType } : {}),
                ...(t.experienceLevel != null ? { experienceLevel: t.experienceLevel } : {}),
                canEdit: true,
              }
              return (
                <DockCard key={t.id} compact={compact} title={t.tripName} stops={t.stops.length}
                  distance={formatDistance(t.distance, t.stops.length)} date={tripFormattedDates(t)}
                  badge={tripTypeBadgeLabel(tripType)}
                  difficulty={isAdventureTripType(tripType) || tripType === 'mixed' ? difficulty : null}
                  selected={selectedTripId === t.id} onClick={() => onTripSelected(trip)} />
              )
            })}
      </div>

      <div className="dock-label"><MdVerified size={16} /> Verified Trips</div>
      <div className="dock-row grow">
        {!verified || verified.length === 0 ? empty('No verified trips yet') : verified.map(({ id, data }) => {
          const title = String(data.title ?? 'Verified Trip')
          const wps = Array.isArray(data.waypoints) ? data.waypoints : []
          const daysRaw = data.recommendedDays ?? data.days
          const days = typeof daysRaw === 'number' ? `${Math.trunc(daysRaw)} days` : ''
          const segModes = Array.isArray(data.segmentTransportModes) ? data.segmentTransportModes.map(String) : []
          const tripType = normalizeTripType(String(data.tripType ?? ''), { transportMode: String(data.transportMode ?? '').trim(), segmentTransportModes: segModes })
          const difficulty = inferTripDifficultyLabel({
            tripType, experienceLevel: String(data.experienceLevel ?? ''), distanceKm: data.totalKm ?? data.distance,
            estimatedDurationMin: data.estimatedDurationMin, stopCount: wps.length, segmentTransportModes: segModes,
          })
          return (
            <DockCard key={id} compact={compact} title={title} stops={wps.length} distance={days} date=""
              badge={tripTypeBadgeLabel(tripType)} difficulty={isAdventureTripType(tripType) || tripType === 'mixed' ? difficulty : null}
              selected={false}
              onClick={() => {
                const points = wps.filter((w: any) => w && typeof w.lat === 'number' && typeof w.lon === 'number').map((w: any) => ({ lat: w.lat, lon: w.lon, name: String(w.name ?? '') }))
                if (!points.length) return
                onTripSelected({
                  id, title, waypoints: points, stops: wps.length,
                  ...(data.tripType != null ? { tripType: data.tripType } : {}),
                  ...(data.experienceLevel != null ? { experienceLevel: data.experienceLevel } : {}),
                  ...(data.transportMode != null ? { transportMode: data.transportMode } : {}),
                  ...(Array.isArray(data.segmentTransportModes) ? { segmentTransportModes: data.segmentTransportModes } : {}),
                  ...(Array.isArray(data.segmentRoutingTypes) ? { segmentRoutingTypes: data.segmentRoutingTypes } : {}),
                  canEdit: false,
                })
              }} />
          )
        })}
      </div>
    </div>
  )
}
