import { useEffect, useMemo, useState, type ReactElement } from 'react'
import { MdAirportShuttle, MdDirectionsCar, MdFlight, MdHotel, MdLocalActivity, MdLuggage, MdOutlineOpenInNew, MdPedalBike, MdReceiptLong, MdSimCard } from 'react-icons/md'
import { useNavigate } from 'react-router-dom'
import PageShell from '@/components/PageShell'
import PartnerWidgets from '@/components/PartnerWidgets'
import { widgetsFor } from '@/lib/widgets'
import { Button, CenteredSpinner, SoftCard } from '@/components/ui'
import { loadPartners, partnerUrl, type Partner } from '@/services/partners'
import { openExternalUrl } from '@/services/openExternalUrl'

const SECTIONS: Record<string, { icon: ReactElement; intro: string }> = {
  flights: { icon: <MdFlight size={22} />, intro: 'Search flights across airlines.' },
  car: { icon: <MdDirectionsCar size={22} />, intro: 'Rent a car for the road, or to reach the trailhead.' },
  activities: { icon: <MdLocalActivity size={22} />, intro: 'Tours, tickets and attractions at your stops.' },
  transfer: { icon: <MdAirportShuttle size={22} />, intro: 'Prebooked rides between the airport and where you are staying.' },
  esim: { icon: <MdSimCard size={22} />, intro: 'Mobile data abroad without roaming charges.' },
  luggage: { icon: <MdLuggage size={22} />, intro: 'Drop your bags and explore hands-free.' },
  bike: { icon: <MdPedalBike size={22} />, intro: 'Bikes, scooters and motorcycles.' },
  claims: { icon: <MdReceiptLong size={22} />, intro: 'Get compensation if a flight is delayed or cancelled.' },
}
const ORDER = ['flights', 'car', 'activities', 'transfer', 'esim', 'luggage', 'bike', 'claims']

/** Everything you might book for a trip, in one place. Each button opens the partner's own site (booking happens there). */
export default function BookScreen() {
  const navigate = useNavigate()
  const [partners, setPartners] = useState<Partner[] | null>(null)
  const [error, setError] = useState(false)
  const [attempt, setAttempt] = useState(0)

  useEffect(() => {
    let alive = true
    loadPartners().then((p) => alive && setPartners(p)).catch(() => alive && setError(true))
    return () => { alive = false }
  }, [attempt])

  const sections = useMemo(() => {
    const byCategory = new Map<string, Partner[]>()
    for (const p of partners ?? []) byCategory.set(p.category, [...(byCategory.get(p.category) ?? []), p])
    return ORDER.filter((c) => byCategory.has(c)).map((c) => ({ category: c, title: byCategory.get(c)![0].categoryTitle, partners: byCategory.get(c)! }))
  }, [partners])

  const jump = (category: string) => document.getElementById(`book-${category}`)?.scrollIntoView({ behavior: 'smooth', block: 'start' })

  return (
    <PageShell>
      <div className="container col gap-md" style={{ paddingBottom: 40 }}>
        <div>
          <h2 className="t-title-l" style={{ fontWeight: 800, fontSize: 24 }}>Book your trip</h2>
          <p className="muted" style={{ marginTop: 4 }}>Flights, cars, tours, eSIMs and more from travel companies we trust. Each opens that company's own site, where you see live prices and book.</p>
        </div>

        <SoftCard padding={16} radius={16} className="clickable" onClick={() => navigate('/my-trips')}>
          <div className="row gap-sm" style={{ alignItems: 'center' }}>
            <MdHotel size={26} color="#00897b" />
            <div className="grow">
              <div style={{ fontWeight: 800 }}>Hotels</div>
              <div className="muted" style={{ fontSize: 13 }}>Open a saved trip to find hotels for each of your stops, or use the Flights and hotels search below.</div>
            </div>
            <Button variant="outlined" size="sm">My trips</Button>
          </div>
        </SoftCard>

        {!partners && !error && <CenteredSpinner pad={40} />}
        {error && (
          <div className="col gap-sm" style={{ alignItems: 'flex-start' }}>
            <div className="muted">Couldn't load booking options right now.</div>
            <Button variant="outlined" size="sm" onClick={() => { setError(false); setAttempt((a) => a + 1) }}>Try again</Button>
          </div>
        )}

        {sections.length > 0 && (
          <div className="chip-row" role="navigation" aria-label="Booking categories">
            {sections.map((s) => <button key={s.category} className="chip teal" onClick={() => jump(s.category)}>{s.title}</button>)}
          </div>
        )}

        {sections.map((s) => (
          <section key={s.category} id={`book-${s.category}`} style={{ scrollMarginTop: 80 }}>
            <div className="row gap-sm" style={{ alignItems: 'center', color: '#00897b' }}>
              {SECTIONS[s.category]?.icon}
              <h3 style={{ fontSize: 18, fontWeight: 800, color: 'var(--text)' }}>{s.title}</h3>
            </div>
            <div className="muted" style={{ fontSize: 13, margin: '2px 0 10px' }}>{SECTIONS[s.category]?.intro}</div>
            {widgetsFor(s.category).length > 0 && (
              <div style={{ marginBottom: 12 }}><PartnerWidgets widgets={widgetsFor(s.category)} /></div>
            )}
            {widgetsFor(s.category).length > 0 && <div className="muted" style={{ fontSize: 12, fontWeight: 700, marginBottom: 6 }}>Or open a booking site</div>}
            <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fill, minmax(230px, 1fr))', gap: 10 }}>
              {s.partners.map((p) => (
                <SoftCard key={p.id} padding={14} radius={14} className="clickable" onClick={() => openExternalUrl(partnerUrl(p.id, 'book-page'))}>
                  <div className="row" style={{ justifyContent: 'space-between', alignItems: 'center', gap: 8 }}>
                    <span style={{ fontWeight: 800 }}>{p.label}</span>
                    <MdOutlineOpenInNew size={16} color="#00897b" />
                  </div>
                  <div className="muted" style={{ fontSize: 12, marginTop: 4, lineHeight: 1.45 }}>{p.blurb}</div>
                </SoftCard>
              ))}
            </div>
          </section>
        ))}

        {sections.length > 0 && (
          <div className="muted" style={{ fontSize: 11, lineHeight: 1.5 }}>
            Prices are not compared on Trypr. Each link opens the company's own site in a new tab. Trypr may earn a commission if you book, at no extra cost to you.
          </div>
        )}
      </div>
    </PageShell>
  )
}
