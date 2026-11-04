import { useState } from 'react'
import WidgetEmbed from './WidgetEmbed'
import { Button } from './ui'
import type { Widget } from '@/lib/widgets'

function WidgetCard({ w }: { w: Widget }) {
  return (
    // Partner forms are designed for a light background, so they always sit on white.
    <div style={{ borderRadius: 14, border: '1px solid var(--glass-border)', background: '#fff', padding: 10, overflow: 'hidden' }}>
      <div style={{ fontWeight: 800, fontSize: 14, color: '#1f2933' }}>{w.title}</div>
      <div style={{ fontSize: 12, margin: '2px 0 8px', color: '#5f6b76' }}>{w.blurb}</div>
      <WidgetEmbed html={w.html} title={w.title} minHeight={w.minHeight} />
    </div>
  )
}

/**
 * The search forms for one category: the main one is shown, any others sit behind a single "More search options"
 * button so the page never turns into a wall of forms. Forms load only when this component is rendered.
 */
export default function PartnerWidgets({ widgets }: { widgets: Widget[] }) {
  const [more, setMore] = useState(false)
  if (!widgets.length) return null
  const [main, ...rest] = widgets
  return (
    <div className="col gap-sm">
      <WidgetCard w={main} />
      {rest.length > 0 && (
        <>
          {more && rest.map((w) => <WidgetCard key={w.id} w={w} />)}
          <Button variant="text" size="sm" style={{ alignSelf: 'flex-start' }} onClick={() => setMore((m) => !m)}>
            {more ? 'Fewer search options' : `More search options (${rest.length})`}
          </Button>
        </>
      )}
    </div>
  )
}
