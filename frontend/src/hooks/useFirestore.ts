import { useEffect, useState } from 'react'
import {
  onSnapshot,
  type DocumentReference,
  type DocumentSnapshot,
  type Query,
  type QueryDocumentSnapshot,
} from 'firebase/firestore'

export interface StreamState<T> {
  data: T
  loading: boolean
  error: Error | null
}

/** Subscribe to a document. Pass `null` while the ref isn't ready yet. */
export function useDocument(ref: DocumentReference | null, deps: unknown[]): StreamState<DocumentSnapshot | null> {
  const [state, setState] = useState<StreamState<DocumentSnapshot | null>>({ data: null, loading: !!ref, error: null })
  useEffect(() => {
    if (!ref) {
      setState({ data: null, loading: false, error: null })
      return
    }
    setState((s) => ({ ...s, loading: true }))
    return onSnapshot(
      ref,
      (snap) => setState({ data: snap, loading: false, error: null }),
      (error) => setState({ data: null, loading: false, error }),
    )
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, deps)
  return state
}

/** Subscribe to a query. Pass `null` while the query isn't ready yet. */
export function useQuerySnapshot(q: Query | null, deps: unknown[]): StreamState<QueryDocumentSnapshot[]> {
  const [state, setState] = useState<StreamState<QueryDocumentSnapshot[]>>({ data: [], loading: !!q, error: null })
  useEffect(() => {
    if (!q) {
      setState({ data: [], loading: false, error: null })
      return
    }
    setState((s) => ({ ...s, loading: true }))
    return onSnapshot(
      q,
      (snap) => setState({ data: snap.docs, loading: false, error: null }),
      (error) => setState({ data: [], loading: false, error }),
    )
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, deps)
  return state
}
