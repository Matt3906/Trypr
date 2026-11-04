import { useEffect, useMemo, useState } from 'react'
import { createPortal } from 'react-dom'
import { MdAddCircleOutline, MdClose, MdExpandLess, MdExpandMore, MdOutlineOpenInNew, MdOutlineRemoveCircleOutline } from 'react-icons/md'
import { Button, SoftCard, Spinner, cx } from './ui'
import { apiUrl } from '@/backend/api'
import { openExternalUrl } from '@/services/openExternalUrl'
import { formatMoney, searchStays, type StayHotel, type StayOffer, type StaySearchResult } from '@/services/stays'
import { addIsoDays, isoDay, isoNightsBetween, type StayStop } from '@/lib/stays'

const CURRENCIES = ['USD', 'EUR', 'GBP', 'CAD', 'AUD']
const POLL_MS = 2500
const MAX_POLLS = 5

type Sort = 'price' | 'stars' | 'distance'

/** The trip's own dates when still upcoming; otherwise the same length of stay starting today. */
function datesFor(stop: StayStop, today: string): [string, string] {
  const nights = Math.max(1, isoNightsBetween(stop.checkIn, stop.checkOut) || 1)
  const checkIn = stop.checkIn >= today ? stop.checkIn : today
  return [checkIn, addIsoDays(checkIn, nights)]
}

const shortDay = (iso: string) => new Date(`${iso}T12:00:00`).toLocaleDateString(undefined, { month: 'short', day: 'numeric' })

/** Plain search links for when live comparison is unavailable. No prices are compared and nothing is earned on these. */
function directSearchLinks(place: string, checkIn: string, checkOut: string, adults: number) {
  const booking = new URLSearchParams({ ss: place, checkin: checkIn, checkout: checkOut, group_adults: String(adults), no_rooms: '1' })
  return [
    { label: 'Booking.com', url: `https://www.booking.com/searchresults.html?${booking}` },
    { label: 'Google Hotels', url: `https://www.google.com/travel/search?${new URLSearchParams({ q: `hotels in ${place}` })}` },
  ]
}

function initialCurrency(): string {
  try {
    const saved = localStorage.getItem('trypr.stayCurrency')
    if (saved && CURRENCIES.includes(saved)) return saved
  } catch { /* storage unavailable */ }
  return 'USD'
}

export interface StaysCompareProps {
  open: boolean
  onClose: () => void
  /** Places to look for a hotel, with the nights wanted at each. The user can switch between them and adjust dates. */
  stops: StayStop[]
  initialStop?: number
  groupSize?: number
  /** Adds the hotel to the trip as a stop. */
  onAddStop?: (hotel: { name: string; address: string; lat: number; lon: number; exact: true }) => Promise<void> | void
}

/** Compares hotel prices across booking sites and surfaces the cheapest place to book. */
export default function StaysCompareSheet(p: StaysCompareProps) {
  const [today] = useState(() => isoDay(new Date()))
  const [stopIdx, setStopIdx] = useState(() => Math.max(0, Math.min(p.initialStop ?? 0, p.stops.length - 1)))
  const stop = p.stops[stopIdx]
  const [checkIn, setCheckIn] = useState(() => datesFor(stop, today)[0])
  const [checkOut, setCheckOut] = useState(() => datesFor(stop, today)[1])
  const [adults, setAdults] = useState(Math.max(1, Math.min(8, p.groupSize ?? 2)))
  const [currency, setCurrency] = useState(initialCurrency)
  const [sort, setSort] = useState<Sort>('price')
  const [result, setResult] = useState<StaySearchResult | null>(null)
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [expanded, setExpanded] = useState<string | null>(null)

  const datesValid = checkOut > checkIn && checkIn >= today

  useEffect(() => {
    if (!p.open || !datesValid) return
    const ctl = new AbortController()
    const timer = setTimeout(async () => {
      setLoading(true)
      setError(null)
      try {
        for (let attempt = 0; attempt <= MAX_POLLS; attempt++) {
          const res = await searchStays({ lat: stop.lat, lon: stop.lon, checkIn, checkOut, adults, currency, name: stop.name, radiusKm: 25 }, ctl.signal)
          setResult(res)
          if (!res.pending || attempt === MAX_POLLS) break
          await new Promise((r) => setTimeout(r, POLL_MS))
          if (ctl.signal.aborted) return
        }
      } catch (e: any) {
        if (e?.name !== 'AbortError') setError(String(e?.message ?? 'Could not load prices'))
      } finally {
        if (!ctl.signal.aborted) setLoading(false)
      }
    }, 350) // debounce date/guest edits
    return () => { clearTimeout(timer); ctl.abort() }
  }, [p.open, stop.lat, stop.lon, stop.name, checkIn, checkOut, adults, currency, datesValid])

  const hotels = useMemo(() => {
    const list = [...(result?.hotels ?? [])]
    if (sort === 'stars') list.sort((a, b) => (b.stars ?? 0) - (a.stars ?? 0) || a.best.totalCents - b.best.totalCents)
    if (sort === 'distance') list.sort((a, b) => a.distanceKm - b.distanceKm)
    return list
  }, [result, sort])

  if (!p.open) return null

  const open = (o: StayOffer) => {
    if (!openExternalUrl(apiUrl(o.url))) setError('Your browser blocked the booking page. Allow pop-ups and try again.')
  }
  const changeCheckIn = (nextIn: string) => {
    const nights = Math.max(1, isoNightsBetween(checkIn, checkOut))
    setCheckIn(nextIn)
    if (checkOut <= nextIn) setCheckOut(addIsoDays(nextIn, nights))
  }
  const changeStop = (idx: number) => {
    const [ci, co] = datesFor(p.stops[idx], today)
    setStopIdx(idx)
    setCheckIn(ci)
    setCheckOut(co)
    setResult(null)
    setExpanded(null)
  }
  const changeCurrency = (c: string) => {
    setCurrency(c)
    try { localStorage.setItem('trypr.stayCurrency', c) } catch { /* ignore */ }
  }

  return createPortal(
    <div className="sheet-backdrop" onMouseDown={(e) => e.target === e.currentTarget && p.onClose()}>
      <div className="sheet" role="dialog" aria-modal="true" aria-label="Compare hotel prices">
        <div className="sheet-title">
          <span>Compare Hotel Prices{stop.name ? ` · ${stop.name}` : ''}</span>
          <button className="icon-btn" title="Close" onClick={p.onClose}><MdClose size={22} /></button>
        </div>

        <div className="sheet-body">
          <SoftCard padding={14} radius={14}>
            {p.stops.length > 1 && (
              <label className="field" style={{ marginBottom: 10 }}>
                <span style={{ fontSize: 12, fontWeight: 700 }}>Stay at</span>
                <select className="select" value={stopIdx} onChange={(e) => changeStop(Number(e.target.value))}>
                  {p.stops.map((s, i) => <option key={i} value={i}>{s.name} · {shortDay(s.checkIn)}–{shortDay(s.checkOut)}</option>)}
                </select>
              </label>
            )}
            <div className="row gap-sm" style={{ flexWrap: 'wrap', alignItems: 'flex-end' }}>
              <label className="field" style={{ flex: '1 1 130px' }}>
                <span style={{ fontSize: 12, fontWeight: 700 }}>Check-in</span>
                <input className="input" type="date" min={today} value={checkIn} onChange={(e) => e.target.value && changeCheckIn(e.target.value)} />
              </label>
              <label className="field" style={{ flex: '1 1 130px' }}>
                <span style={{ fontSize: 12, fontWeight: 700 }}>Check-out</span>
                <input className="input" type="date" min={addIsoDays(checkIn, 1)} value={checkOut} onChange={(e) => e.target.value && setCheckOut(e.target.value)} />
              </label>
              <div className="field">
                <span style={{ fontSize: 12, fontWeight: 700 }}>Guests</span>
                <div className="row gap-sm" style={{ alignItems: 'center' }}>
                  <button className="icon-btn" aria-label="Fewer guests" onClick={() => setAdults((g) => Math.max(1, g - 1))}><MdOutlineRemoveCircleOutline size={24} /></button>
                  <span style={{ fontSize: 18, fontWeight: 800, minWidth: 16, textAlign: 'center' }}>{adults}</span>
                  <button className="icon-btn" aria-label="More guests" onClick={() => setAdults((g) => Math.min(8, g + 1))}><MdAddCircleOutline size={24} /></button>
                </div>
              </div>
              <label className="field">
                <span style={{ fontSize: 12, fontWeight: 700 }}>Currency</span>
                <select className="select" value={currency} onChange={(e) => changeCurrency(e.target.value)}>
                  {CURRENCIES.map((c) => <option key={c}>{c}</option>)}
                </select>
              </label>
            </div>
            {!datesValid && <div style={{ color: 'var(--error)', fontSize: 12, marginTop: 8 }}>Pick a check-in from today onwards and a later check-out.</div>}
          </SoftCard>

          {result && result.configured && result.hotels.length > 0 && (
            <div className="row" style={{ alignItems: 'center', justifyContent: 'space-between', margin: '12px 2px 6px', gap: 8, flexWrap: 'wrap' }}>
              <span className="muted" style={{ fontSize: 12 }}>
                {result.hotels.length} stays · {result.nights} night{result.nights === 1 ? '' : 's'} · prices are for the whole stay
              </span>
              <div className="toggle-group">
                {(['price', 'stars', 'distance'] as const).map((s) => (
                  <button key={s} style={{ minWidth: 64 }} className={cx(sort === s && 'selected')} onClick={() => setSort(s)}>
                    {s === 'price' ? 'Cheapest' : s === 'stars' ? 'Stars' : 'Closest'}
                  </button>
                ))}
              </div>
            </div>
          )}

          {result?.sample && (
            <div style={{ margin: '10px 0', padding: '8px 12px', borderRadius: 10, background: 'rgba(229,163,60,0.18)', fontSize: 12, fontWeight: 700 }}>
              Sample data (development only): these prices and hotels are not real.
            </div>
          )}

          {loading && (
            <div className="row gap-sm muted" style={{ alignItems: 'center', margin: '12px 2px', fontSize: 13 }}>
              <Spinner size="sm" />
              {result?.pending ? `Still checking ${result.providers.filter((x) => x.status === 'pending').map((x) => x.label).join(', ')}…` : 'Comparing prices…'}
            </div>
          )}
          {error && <div style={{ color: 'var(--error)', fontSize: 13, margin: '12px 2px' }}>{error}</div>}

          {result && !loading && datesValid && (!result.configured || hotels.length === 0) && (
            <div style={{ margin: '16px 2px 4px' }}>
              <div className="muted" style={{ fontSize: 14 }}>
                {result.configured
                  ? 'No priced stays found near here for those dates.'
                  : 'Live price listings are coming soon.'}
                {result.searchLink ? ' You can compare prices from 70+ booking sites for these exact dates:' : ' For now, search these exact dates directly:'}
              </div>
              <div className="row gap-sm" style={{ flexWrap: 'wrap', marginTop: 10 }}>
                {result.searchLink ? (
                  <Button variant="solid" icon={<MdOutlineOpenInNew size={16} />} style={{ background: '#00897b' }} onClick={() => open({ url: result.searchLink!.url } as StayOffer)}>
                    Compare prices on {result.searchLink.label}
                  </Button>
                ) : (
                  directSearchLinks(stop.name, checkIn, checkOut, adults).map((l) => (
                    <Button key={l.label} variant="outlined" size="sm" icon={<MdOutlineOpenInNew size={16} />} onClick={() => openExternalUrl(l.url)}>{l.label}</Button>
                  ))
                )}
              </div>
              {result.searchLink && (
                <div className="muted" style={{ fontSize: 11, marginTop: 10, lineHeight: 1.5 }}>
                  Opens {result.searchLink.label} in a new tab. Trypr may earn a commission if you book, at no extra cost to you.
                </div>
              )}
            </div>
          )}

          <div style={{ display: 'flex', flexDirection: 'column', gap: 10, marginTop: 8 }}>
            {hotels.map((h) => (
              <HotelCard
                key={h.id}
                hotel={h}
                nights={result?.nights ?? 1}
                expanded={expanded === h.id}
                onToggle={() => setExpanded(expanded === h.id ? null : h.id)}
                onOpen={open}
                onAdd={p.onAddStop ? () => p.onAddStop!({ name: h.name, address: h.address ?? '', lat: h.lat, lon: h.lon, exact: true }) : undefined}
              />
            ))}
          </div>

          {result?.configured && (
            <div className="muted" style={{ fontSize: 11, margin: '14px 2px 0', lineHeight: 1.5 }}>
              Prices come from booking partners and can change. Some are the lowest recently seen and are re-checked on the partner's site before you book.
              Trypr may earn a commission when you book through these links, at no extra cost to you.
            </div>
          )}
        </div>
      </div>
    </div>,
    document.body,
  )
}

function Perk({ children }: { children: string }) {
  return <span style={{ fontSize: 11, fontWeight: 700, padding: '2px 8px', borderRadius: 999, background: 'rgba(79,157,93,0.14)', color: 'var(--success)' }}>{children}</span>
}

function HotelCard({ hotel: h, nights, expanded, onToggle, onOpen, onAdd }: {
  hotel: StayHotel
  nights: number
  expanded: boolean
  onToggle: () => void
  onOpen: (o: StayOffer) => void
  onAdd?: () => void
}) {
  const [adding, setAdding] = useState(false)
  const b = h.best
  const others = h.offers.length - 1
  return (
    <SoftCard padding={14} radius={14}>
      <div className="row" style={{ justifyContent: 'space-between', alignItems: 'flex-start', gap: 12 }}>
        <div style={{ minWidth: 0 }}>
          <div style={{ fontWeight: 800, fontSize: 15 }}>{h.name}</div>
          <div className="muted" style={{ fontSize: 12, marginTop: 2 }}>
            {h.stars ? `${'★'.repeat(Math.round(h.stars))} · ` : ''}{h.distanceKm < 1 ? 'under 1 km' : `${h.distanceKm.toFixed(1)} km`} away
          </div>
          <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap', marginTop: 8 }}>
            {b.freeCancellation && <Perk>Free cancellation</Perk>}
            {b.breakfast && <Perk>Breakfast included</Perk>}
            {h.savingsPct >= 3 && <Perk>{`Save ${formatMoney(h.savingsCents, b.currency)} vs highest`}</Perk>}
          </div>
        </div>
        <div style={{ textAlign: 'right', flexShrink: 0 }}>
          <div style={{ fontSize: 20, fontWeight: 900 }}>{formatMoney(b.totalCents, b.currency)}</div>
          <div className="muted" style={{ fontSize: 11 }}>{formatMoney(b.perNightCents, b.currency)}/night · {nights} night{nights === 1 ? '' : 's'}</div>
          <div style={{ fontSize: 11, fontWeight: 700, color: 'var(--secondary)', marginTop: 2 }}>
            {b.live ? '' : 'From '}{others > 0 ? 'Cheapest on ' : 'On '}{b.providerLabel}
          </div>
        </div>
      </div>

      <div className="row gap-sm" style={{ marginTop: 12, flexWrap: 'wrap' }}>
        <Button variant="solid" size="sm" onClick={() => onOpen(b)} icon={<MdOutlineOpenInNew size={16} />} style={{ background: '#00897b' }}>View deal</Button>
        {others > 0 && (
          <Button variant="outlined" size="sm" onClick={onToggle} icon={expanded ? <MdExpandLess size={18} /> : <MdExpandMore size={18} />}>
            Compare {h.offers.length} sites
          </Button>
        )}
        {onAdd && (
          <Button variant="text" size="sm" loading={adding} onClick={async () => { setAdding(true); try { await onAdd() } finally { setAdding(false) } }}>
            Add as stop
          </Button>
        )}
      </div>

      {expanded && (
        <div style={{ marginTop: 10, borderTop: '1px solid var(--border)' }}>
          {h.offers.map((o, i) => (
            <div key={o.provider} className="row" style={{ justifyContent: 'space-between', alignItems: 'center', padding: '8px 0', borderBottom: i < h.offers.length - 1 ? '1px solid var(--border)' : 'none' }}>
              <span style={{ fontWeight: i === 0 ? 800 : 600, fontSize: 13 }}>{o.providerLabel}{i === 0 ? ' · lowest' : ''}</span>
              <span className="row gap-sm" style={{ alignItems: 'center' }}>
                <span style={{ fontWeight: 800 }}>{formatMoney(o.totalCents, o.currency)}</span>
                {i > 0 && <span className="muted" style={{ fontSize: 11 }}>+{formatMoney(o.totalCents - b.totalCents, o.currency)}</span>}
                <Button variant="text" size="sm" onClick={() => onOpen(o)}>View</Button>
              </span>
            </div>
          ))}
        </div>
      )}
    </SoftCard>
  )
}
