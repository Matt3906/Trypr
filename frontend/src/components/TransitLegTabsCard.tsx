import { useEffect, useState } from 'react'
import { MdAltRoute, MdDirectionsBike, MdDirectionsTransit, MdDirectionsWalk, MdTrain } from 'react-icons/md'
import { cx } from './ui'

interface Props {
  originName: string
  destinationName: string
  steps: Record<string, any>[]
  arrivalStopName?: string
  onStepSelected?: (step: Record<string, any>) => void
}

function iconForMode(mode: string, size = 16) {
  switch (mode) {
    case 'walking': case 'walk': return <MdDirectionsWalk size={size} />
    case 'bicycling': case 'bike': case 'biking': return <MdDirectionsBike size={size} />
    case 'transit': case 'train': return <MdTrain size={size} />
    default: return <MdAltRoute size={size} />
  }
}

const parseHex = (hex: string): string | null => {
  const v = hex.trim().replace('#', '')
  return v.length === 6 && /^[0-9a-f]{6}$/i.test(v) ? `#${v}` : null
}

/** Tabbed per-step breakdown of a transit leg; selecting a step focuses it on the map. */
export default function TransitLegTabsCard({ originName, destinationName, steps, arrivalStopName, onStepSelected }: Props) {
  const visible = steps.filter((s) => String(s.tabLabel ?? '').trim() || String(s.headline ?? '').trim()).slice(0, 6)
  const [selected, setSelected] = useState(0)
  useEffect(() => {
    if (selected > visible.length - 1) setSelected(Math.max(0, visible.length - 1))
  }, [visible.length, selected])
  if (!visible.length) return null

  const safe = Math.min(Math.max(selected, 0), visible.length - 1)
  const step = visible[safe]
  const mode = String(step.mode ?? '').trim().toLowerCase()
  const color = parseHex(String(step.lineColor ?? '')) ?? '#0f766e'
  const arrival = (arrivalStopName ?? '').trim() ? `Train leg • arrive at ${arrivalStopName!.trim()}` : 'Train leg'
  const tabLabel = (s: Record<string, any>) => {
    const raw = String(s.tabLabel ?? '').trim()
    if (!raw) return 'Step'
    return raw.length <= 16 ? raw : `${raw.slice(0, 15)}…`
  }
  const detail = String(step.detail ?? '').trim()
  const caption = String(step.caption ?? '').trim()

  return (
    <div style={{ margin: '8px 0', padding: 12, borderRadius: 16, background: 'linear-gradient(135deg,#f1f8f5,#f7fafe)', border: '1px solid rgba(0,137,123,.15)', boxShadow: '0 4px 10px rgba(0,0,0,.07)' }}>
      <div className="row gap-md" style={{ alignItems: 'flex-start' }}>
        <div className="center" style={{ width: 36, height: 36, borderRadius: 12, background: 'rgba(0,137,123,.12)', color: '#00695c', flex: 'none' }}><MdDirectionsTransit size={22} /></div>
        <div className="grow">
          <div style={{ fontWeight: 800, color: '#111827' }}>{originName} to {destinationName}</div>
          <div style={{ fontSize: 12, color: '#4b5563', fontWeight: 600, marginTop: 2 }}>{arrival}</div>
        </div>
        <span style={{ padding: '6px 10px', borderRadius: 999, background: 'rgba(255,255,255,.9)', border: '1px solid rgba(0,0,0,.1)', fontSize: 11, fontWeight: 800, color: '#0f766e', whiteSpace: 'nowrap' }}>{visible.length} tabs</span>
      </div>
      <div className="row wrap" style={{ gap: 8, marginTop: 12 }}>
        {visible.map((s, i) => (
          <button
            key={i}
            type="button"
            className={cx('transit-chip', i === safe && 'selected')}
            onClick={() => { setSelected(i); onStepSelected?.({ ...visible[i] }) }}
          >
            {iconForMode(String(s.mode ?? '').trim().toLowerCase())}
            <span className="ellipsis" style={{ maxWidth: 120 }}>{tabLabel(s)}</span>
          </button>
        ))}
      </div>
      <button type="button" className="transit-pane" onClick={() => onStepSelected?.({ ...step })}>
        <div className="center" style={{ width: 36, height: 36, borderRadius: 11, background: `color-mix(in srgb, ${color} 14%, transparent)`, color, flex: 'none' }}>{iconForMode(mode, 20)}</div>
        <div className="grow" style={{ textAlign: 'left' }}>
          <div style={{ fontWeight: 800, color: '#111827' }}>{String(step.headline ?? '').trim() || 'Transit step'}</div>
          {detail && <div style={{ fontSize: 12, color: '#374151', fontWeight: 600, marginTop: 4 }}>{detail}</div>}
          {caption && <span style={{ display: 'inline-block', marginTop: 6, padding: '4px 8px', borderRadius: 999, background: '#f3f4f6', fontSize: 11, fontWeight: 700, color: '#374151' }}>{caption}</span>}
        </div>
      </button>
    </div>
  )
}
