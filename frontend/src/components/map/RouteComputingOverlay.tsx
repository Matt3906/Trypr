import { useEffect, useRef } from 'react'

interface Props {
  headline: string
  detail: string
  topOffset: number
  start: { x: number; y: number } | null
  target: { x: number; y: number } | null
  curveSeed: number
}

/** Animated "tracing the route" beam + status pill shown while routes are computed. */
export default function RouteComputingOverlay({ headline, detail, topOffset, start, target, curveSeed }: Props) {
  const canvasRef = useRef<HTMLCanvasElement>(null)
  const startRef = useRef(start)
  const targetRef = useRef(target)
  const seedRef = useRef(curveSeed)
  startRef.current = start
  targetRef.current = target
  seedRef.current = curveSeed

  useEffect(() => {
    const canvas = canvasRef.current
    if (!canvas) return
    const ctx = canvas.getContext('2d')
    if (!ctx) return
    let raf = 0
    const t0 = performance.now()

    const draw = (now: number) => {
      const dpr = window.devicePixelRatio || 1
      const w = canvas.clientWidth, h = canvas.clientHeight
      if (canvas.width !== w * dpr || canvas.height !== h * dpr) {
        canvas.width = w * dpr
        canvas.height = h * dpr
      }
      ctx.setTransform(dpr, 0, 0, dpr, 0, 0)
      ctx.clearRect(0, 0, w, h)
      const o = startRef.current, d = targetRef.current
      const progress = ((now - t0) % 1800) / 1800
      if (o && d) {
        const dx = d.x - o.x, dy = d.y - o.y
        const dist = Math.hypot(dx, dy)
        if (dist >= 18) {
          const mid = { x: (o.x + d.x) / 2, y: (o.y + d.y) / 2 }
          const nl = Math.hypot(dx, dy) || 1
          const nu = { x: -dy / nl, y: dx / nl }
          const sign = seedRef.current >= 0.5 ? -1 : 1
          const arc = Math.min(104, Math.max(30, dist * (0.16 + 0.12 * seedRef.current)))
          let cx = mid.x + nu.x * arc * sign
          let cy = mid.y + nu.y * arc * sign
          const maxCy = Math.min(o.y, d.y) - 26
          if (cy > maxCy) cy = maxCy

          const quad = (t: number) => ({
            x: (1 - t) ** 2 * o.x + 2 * (1 - t) * t * cx + t * t * d.x,
            y: (1 - t) ** 2 * o.y + 2 * (1 - t) * t * cy + t * t * d.y,
          })
          const strokeRange = (t0f: number, t1f: number, width: number, style: string | CanvasGradient) => {
            ctx.beginPath()
            const steps = 28
            for (let i = 0; i <= steps; i++) {
              const p = quad(t0f + ((t1f - t0f) * i) / steps)
              i ? ctx.lineTo(p.x, p.y) : ctx.moveTo(p.x, p.y)
            }
            ctx.lineWidth = width
            ctx.lineCap = 'round'
            ctx.strokeStyle = style
            ctx.stroke()
          }
          strokeRange(0, 1, 2.2, 'rgba(255,255,255,.2)')
          const head = 0.14 + 0.82 * progress
          const tail = Math.max(0, head - 0.22)
          strokeRange(tail, head, 9, 'rgba(56,189,248,.27)')
          const g = ctx.createLinearGradient(o.x, o.y, d.x, d.y)
          g.addColorStop(0, 'rgba(56,189,248,0)')
          g.addColorStop(0.5, '#38bdf8')
          g.addColorStop(1, '#2dd4bf')
          strokeRange(tail, head, 4.6, g)

          const hp = quad(head)
          ctx.fillStyle = 'rgba(103,232,249,.8)'
          ctx.beginPath(); ctx.arc(hp.x, hp.y, 6, 0, Math.PI * 2); ctx.fill()
          ctx.strokeStyle = 'rgba(103,232,249,.27)'; ctx.lineWidth = 2
          ctx.beginPath(); ctx.arc(hp.x, hp.y, 12, 0, Math.PI * 2); ctx.stroke()

          const pulse = 0.5 + 0.5 * Math.sin(progress * Math.PI * 2)
          ctx.fillStyle = '#38bdf8'
          ctx.beginPath(); ctx.arc(o.x, o.y, 5, 0, Math.PI * 2); ctx.fill()
          ctx.strokeStyle = `rgba(56,189,248,${0.4 + 0.07 * pulse})`
          ctx.beginPath(); ctx.arc(o.x, o.y, 12 + pulse * 4, 0, Math.PI * 2); ctx.stroke()
          ctx.fillStyle = '#2dd4bf'
          ctx.beginPath(); ctx.arc(d.x, d.y, 6, 0, Math.PI * 2); ctx.fill()
          ctx.strokeStyle = `rgba(45,212,191,${0.4 + 0.3 * pulse})`
          ctx.beginPath(); ctx.arc(d.x, d.y, 14 + pulse * 5, 0, Math.PI * 2); ctx.stroke()
          ctx.lineWidth = 1.5
          ctx.strokeStyle = `rgba(45,212,191,${0.15 + 0.1 * pulse})`
          ctx.beginPath(); ctx.arc(d.x, d.y, 24 + pulse * 8, 0, Math.PI * 2); ctx.stroke()
        }
      }
      raf = requestAnimationFrame(draw)
    }
    raf = requestAnimationFrame(draw)
    return () => cancelAnimationFrame(raf)
  }, [])

  return (
    <div style={{ position: 'absolute', inset: 0, pointerEvents: 'none', zIndex: 3 }}>
      <canvas ref={canvasRef} style={{ position: 'absolute', inset: 0, width: '100%', height: '100%' }} />
      <div style={{ position: 'absolute', top: topOffset, left: 16, right: 16, display: 'flex', justifyContent: 'center' }}>
        <div
          style={{
            maxWidth: 320, display: 'flex', alignItems: 'center', gap: 10, padding: '9px 12px', borderRadius: 999,
            background: 'rgba(22,36,49,.88)', border: '1px solid rgba(103,232,217,.2)', boxShadow: '0 10px 18px rgba(0,0,0,.19)',
          }}
        >
          <span className="route-pulse-dot" />
          <div style={{ minWidth: 0 }}>
            <div className="ellipsis" style={{ color: '#fff', fontWeight: 800, fontSize: 13 }}>{headline}</div>
            <div className="ellipsis" style={{ color: '#d0d9e4', fontSize: 11 }}>{detail}</div>
          </div>
        </div>
      </div>
    </div>
  )
}
