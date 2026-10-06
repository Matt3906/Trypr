import { MdLocationCity } from 'react-icons/md'
import { Spinner } from '@/components/ui'
import {
  activityEmoji, activityRecommendationMeta, cityFromStopFields, fallbackActivitiesForTown, fallbackActivityRecommendations,
  fallbackGalleryImageUrl, fallbackTownImageUrl, isBackcountryStop, looksPoiLabel, looksRegionLabel, stopImageUrls,
  trimAddressNoise, type ActivityRecommendation, type StopMap,
} from '@/lib/tripInsights'
import { focusedStopKey, type PoiInsight } from './stopInsights'

export function focusedStopTitle(stop: StopMap, stopNumber: number, trip: StopMap | null, insight?: PoiInsight): string {
  const explicit = String(stop.name ?? stop.title ?? '').trim()
  let cleaned = trimAddressNoise(explicit)
  if (cleaned.toLowerCase() === 'dropped pin') cleaned = ''
  if (isBackcountryStop(stop, trip) && cleaned) return cleaned
  if (cleaned && !looksRegionLabel(cleaned) && !looksPoiLabel(cleaned)) return cleaned
  const aiCity = (insight?.cityName ?? '').trim()
  if (aiCity) return aiCity
  const aiName = (insight?.displayName ?? '').trim()
  if (aiName) return aiName
  const fromFields = cityFromStopFields(stop)
  if (fromFields) return fromFields
  if (cleaned) return cleaned
  return `Stop ${stopNumber}`
}

function focusedStopActivities(stop: StopMap, title: string, insight?: PoiInsight): string[] {
  const out: string[] = []
  const seen = new Set<string>()
  const add = (v: string) => {
    const c = v.trim()
    if (!c || seen.has(c.toLowerCase())) return
    seen.add(c.toLowerCase())
    out.push(c)
  }
  if (insight?.categories?.length) {
    insight.categories.forEach(add)
    if (out.length) return out.slice(0, 6)
  }
  const raw = stop.activityCategories ?? stop.categories
  if (Array.isArray(raw)) raw.forEach((e) => add(String(e)))
  else if (typeof raw === 'string') raw.split(',').forEach(add)

  if (Array.isArray(stop.itinerary)) {
    const counts = new Map<string, number>()
    for (const day of stop.itinerary) {
      if (!day || !Array.isArray(day.activities)) continue
      for (const a of day.activities) {
        const c = String(a?.category ?? '').trim()
        if (c) counts.set(c, (counts.get(c) ?? 0) + 1)
      }
    }
    ;[...counts.entries()].sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0])).forEach(([k]) => add(k))
  }
  if (!out.length) fallbackActivitiesForTown(title).forEach(add)
  return out.slice(0, 6)
}

function focusedStopRecommendations(stop: StopMap, title: string, activities: string[], insight?: PoiInsight): ActivityRecommendation[] {
  const out: ActivityRecommendation[] = []
  const seen = new Set<string>()
  const add = (name: string, category?: string, rating?: unknown, price?: unknown) => {
    const n = name.trim()
    if (!n || seen.has(n.toLowerCase())) return
    seen.add(n.toLowerCase())
    const r = typeof rating === 'number' ? rating : parseFloat(String(rating))
    const p = typeof price === 'number' ? price : parseFloat(String(price))
    out.push({
      name: n,
      ...(category?.trim() ? { category: category.trim() } : {}),
      ...(Number.isFinite(r) ? { rating: r } : {}),
      ...(Number.isFinite(p) && p >= 0 ? { estimatedPrice: Math.round(p) } : {}),
    })
  }
  for (const r of insight?.activityRecommendations ?? []) add(r.name, r.category, r.rating, r.estimatedPrice)
  if (out.length) return out.slice(0, 5)

  if (Array.isArray(stop.itinerary)) {
    for (const day of stop.itinerary) {
      if (!day || !Array.isArray(day.activities)) continue
      for (const a of day.activities) {
        if (!a || typeof a !== 'object') continue
        add(String(a.name ?? a.title ?? ''), String(a.category ?? ''), a.rating, a.estimatedPrice ?? a.price_estimate ?? a.price)
      }
    }
    if (out.length) return out.slice(0, 5)
  }
  return fallbackActivityRecommendations(title, activities.length ? activities : fallbackActivitiesForTown(title))
}

function focusedStopSummary(stop: StopMap, title: string, activities: string[], insight?: PoiInsight): string {
  const ai = (insight?.summary ?? '').trim()
  if (ai) return ai
  let dayCount = 0
  let activityCount = 0
  if (Array.isArray(stop.itinerary)) {
    for (const day of stop.itinerary) {
      if (!day || typeof day !== 'object') continue
      dayCount++
      if (Array.isArray(day.activities)) activityCount += day.activities.length
    }
  }
  const focus = activities.length ? activities.slice(0, 3).join(', ').toLowerCase() : 'sightseeing and local exploration'
  if (activityCount > 0) {
    const dayText = dayCount > 0 ? `${dayCount} day${dayCount === 1 ? '' : 's'}` : 'this stop'
    return `${title} has ${activityCount} planned activit${activityCount === 1 ? 'y' : 'ies'} across ${dayText}, centered on ${focus}.`
  }
  return `${title} is a strong stop for ${focus}. Keep nearby points grouped together here for a smoother day plan.`
}

interface Props {
  stop: StopMap
  stopNumber: number
  totalStops: number
  trip: StopMap | null
  insight?: PoiInsight
  isLoading: boolean
  placePhotos: string[]
  attribution: Record<string, string>
  hasPremium: boolean | null
  maxWidth: number
  height: number
}

export default function StopInsightCard({ stop, stopNumber, totalStops, trip, insight, isLoading, placePhotos, attribution, hasPremium, maxWidth, height }: Props) {
  const title = focusedStopTitle(stop, stopNumber, trip, insight)
  const isBackcountry = isBackcountryStop(stop, trip)
  const showAi = hasPremium === true && !isBackcountry
  const urls = stopImageUrls(stop, title, placePhotos)
  const gallery = urls.length ? urls : [fallbackTownImageUrl(title)]
  const activities = showAi ? focusedStopActivities(stop, title, insight) : []
  const summary = showAi ? focusedStopSummary(stop, title, activities, insight) : ''
  const recs = showAi ? focusedStopRecommendations(stop, title, activities, insight) : []
  const loading = showAi && isLoading
  void focusedStopKey

  const previewCount = Math.min(gallery.length, 9)
  const cols = gallery.length <= 4 ? 2 : 3
  const remaining = gallery.length - previewCount

  return (
    <div className="insight-card" style={{ maxWidth, height }}>
      {gallery.length <= 1 ? (
        <div className="insight-single">
          <img src={gallery[0]} alt={`Preview photo for ${title}`} onError={(e) => { (e.currentTarget as HTMLImageElement).src = fallbackGalleryImageUrl(title, 0) }} />
          {attribution[gallery[0]] && <span className="photo-attr">{attribution[gallery[0]]}</span>}
        </div>
      ) : (
        <div className="insight-grid" style={{ gridTemplateColumns: `repeat(${cols}, 1fr)` }}>
          {gallery.slice(0, previewCount).map((u, i) => (
            <div key={u} className="insight-tile">
              <img src={u} alt={`Photo ${i + 1} of ${gallery.length} for ${title}`} onError={(e) => { (e.currentTarget as HTMLImageElement).src = fallbackGalleryImageUrl(title, i) }} />
              {i === 0 && <span className="photo-count">{gallery.length} photos</span>}
              {attribution[u] && <span className="photo-attr">{attribution[u]}</span>}
              {remaining > 0 && i === previewCount - 1 && <div className="photo-more">+{remaining}</div>}
            </div>
          ))}
        </div>
      )}

      <div className="row" style={{ marginTop: 10 }}>
        <MdLocationCity size={16} />
        <span style={{ fontSize: 12, fontWeight: 700, marginLeft: 6 }}>Location Insight</span>
        <span className="grow" />
        <span style={{ fontSize: 11, color: 'rgba(0,0,0,.54)' }}>Stop {stopNumber}/{totalStops}</span>
      </div>
      <div style={{ fontSize: 18, fontWeight: 800, marginTop: 8, display: '-webkit-box', WebkitLineClamp: 2, WebkitBoxOrient: 'vertical', overflow: 'hidden' }}>{title}</div>

      <div className="insight-scroll">
        {!showAi ? (
          <>
            <div style={{ fontSize: 12, fontWeight: 700 }}>{isBackcountry ? 'Backcountry stop preview' : 'Stop preview'}</div>
            <div style={{ fontSize: 12.5, color: 'rgba(0,0,0,.87)', marginTop: 4 }}>Showing stop name and related photos only.</div>
            {hasPremium !== true && <div style={{ fontSize: 11.5, color: 'rgba(0,0,0,.54)', marginTop: 8 }}>Upgrade to Premium to unlock AI summaries.</div>}
          </>
        ) : (
          <>
            <div style={{ fontSize: 12, fontWeight: 700 }}>AI Summary</div>
            {loading && (
              <div className="row gap-sm" style={{ marginTop: 4 }}>
                <Spinner size="sm" />
                <span style={{ fontSize: 12, color: 'rgba(0,0,0,.54)' }}>Generating with Gemini...</span>
              </div>
            )}
            <div style={{ fontSize: 12.5, marginTop: 4, color: 'rgba(0,0,0,.87)' }}>{summary}</div>

            <div style={{ fontSize: 12, fontWeight: 700, marginTop: 10 }}>Activities</div>
            <div className="row wrap" style={{ gap: 6, marginTop: 6 }}>
              {activities.slice(0, 8).map((a) => (
                <span key={a} style={{ padding: '5px 8px', borderRadius: 999, background: 'rgba(0,0,0,.06)', fontSize: 11.5, fontWeight: 600 }}>
                  {activityEmoji(a)} {a}
                </span>
              ))}
            </div>

            <div style={{ fontSize: 12, fontWeight: 700, marginTop: 12 }}>AI Activity Recommendations</div>
            {recs.length === 0 && loading ? (
              <div className="row gap-sm" style={{ marginTop: 6 }}>
                <Spinner size="sm" />
                <span style={{ fontSize: 12, color: 'rgba(0,0,0,.54)' }}>Generating activity recommendations...</span>
              </div>
            ) : (
              <div className="col" style={{ gap: 7, marginTop: 6 }}>
                {recs.slice(0, 4).map((r) => {
                  const meta = activityRecommendationMeta(r)
                  return (
                    <div key={r.name} style={{ padding: '8px 10px', borderRadius: 10, background: 'rgba(0,0,0,.045)' }}>
                      <div style={{ fontSize: 12.5, fontWeight: 700 }}>✨ {r.name.trim()}</div>
                      {meta && <div style={{ fontSize: 11.5, color: 'rgba(0,0,0,.54)', marginTop: 2 }}>{meta}</div>}
                    </div>
                  )
                })}
              </div>
            )}
          </>
        )}
      </div>
    </div>
  )
}
