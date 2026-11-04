import { useEffect, useMemo, useState } from 'react'
import { useNavigate } from 'react-router-dom'
import { MdExpandLess, MdExpandMore, MdOutlineOpenInNew, MdTravelExplore } from 'react-icons/md'
import { Button } from './ui'
import PartnerWidgets from './PartnerWidgets'
import { widgetsFor } from '@/lib/widgets'
import { essentialsGroups, type EssentialsContext } from '@/lib/tripEssentials'
import { loadPartners, partnerUrl, type Partner } from '@/services/partners'
import { openExternalUrl } from '@/services/openExternalUrl'

/** Partner deals that fit this trip (flights, car rental, eSIM, tours...). Renders nothing if there is nothing relevant. */
export default function TripEssentialsCard({ ctx, placement }: { ctx: EssentialsContext; placement: string }) {
  const [partners, setPartners] = useState<Partner[]>([])
  const navigate = useNavigate()
  const [open, setOpen] = useState(false)
  const [showMore, setShowMore] = useState<Set<string>>(new Set())
  const [searching, setSearching] = useState<Set<string>>(new Set())

  useEffect(() => {
    let alive = true
    loadPartners().then((p) => alive && setPartners(p)).catch(() => { /* optional feature: stay hidden if the API is unreachable */ })
    return () => { alive = false }
  }, [])

  const groups = useMemo(() => essentialsGroups(partners, ctx), [partners, ctx])
  if (!groups.length) return null
  const toggleMore = (category: string) => setShowMore((cur) => {
    const next = new Set(cur)
    if (!next.delete(category)) next.add(category)
    return next
  })
  const toggleSearch = (category: string) => setSearching((cur) => {
    const next = new Set(cur)
    if (!next.delete(category)) next.add(category)
    return next
  })
  const partnerButton = (p: Partner) => (
    <Button key={p.id} variant="outlined" size="sm" title={p.blurb} icon={<MdOutlineOpenInNew size={14} />} onClick={() => openExternalUrl(partnerUrl(p.id, placement))}>
      {p.label}
    </Button>
  )

  return (
    <div style={{ marginTop: 8, borderRadius: 16, border: '1px solid var(--glass-border)', background: 'var(--glass-bg-strong)', boxShadow: 'var(--glass-hi)' }}>
      <button
        onClick={() => setOpen((o) => !o)}
        aria-expanded={open}
        style={{ width: '100%', display: 'flex', alignItems: 'center', gap: 10, padding: '10px 12px', border: 'none', background: 'transparent', cursor: 'pointer', textAlign: 'left', color: 'inherit' }}
      >
        <MdTravelExplore size={22} color="#00897b" />
        <span style={{ flex: 1, minWidth: 0 }}>
          <span style={{ display: 'block', fontWeight: 800, fontSize: 13 }}>Trip essentials</span>
          <span className="ellipsis muted" style={{ display: 'block', fontSize: 11 }}>{groups.map((g) => g.title).join(' · ')}</span>
        </span>
        {open ? <MdExpandLess size={22} /> : <MdExpandMore size={22} />}
      </button>

      {open && (
        <div style={{ padding: '0 12px 12px' }}>
          {groups.map((g) => (
            <div key={g.category} style={{ marginTop: 10 }}>
              <div style={{ fontSize: 12, fontWeight: 800, marginBottom: 6 }}>{g.title}</div>
              {widgetsFor(g.category, ctx.regions).length > 0 && (
                <div style={{ marginBottom: 8 }}>
                  <Button variant="solid" size="sm" onClick={() => toggleSearch(g.category)}>
                    {searching.has(g.category) ? 'Hide search' : 'Search here'}
                  </Button>
                  {searching.has(g.category) && (
                    <div style={{ marginTop: 8 }}><PartnerWidgets widgets={widgetsFor(g.category, ctx.regions)} /></div>
                  )}
                </div>
              )}
              <div className="row gap-sm" style={{ flexWrap: 'wrap', alignItems: 'center' }}>
                {g.partners.map(partnerButton)}
                {g.more.length > 0 && (
                  <Button variant="text" size="sm" onClick={() => toggleMore(g.category)}>
                    {showMore.has(g.category) ? 'Fewer options' : `More options (${g.more.length})`}
                  </Button>
                )}
              </div>
              {showMore.has(g.category) && <div className="row gap-sm" style={{ flexWrap: 'wrap', marginTop: 8 }}>{g.more.map(partnerButton)}</div>}
              <div className="muted" style={{ fontSize: 11, marginTop: 4 }}>
                {(showMore.has(g.category) ? [...g.partners, ...g.more] : g.partners).map((p) => `${p.label}: ${p.blurb}`).join(' · ')}
              </div>
            </div>
          ))}
          <Button variant="text" size="sm" style={{ marginTop: 8 }} onClick={() => navigate('/book')}>See everything you can book →</Button>
          <div className="muted" style={{ fontSize: 11, marginTop: 4, lineHeight: 1.5 }}>
            Each button opens that company's own site in a new tab; prices are not compared here. Trypr may earn a commission if you book, at no extra cost to you.
          </div>
        </div>
      )}
    </div>
  )
}
