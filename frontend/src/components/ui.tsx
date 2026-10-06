import { useEffect, useRef, useState, type CSSProperties, type MouseEventHandler, type ReactNode } from 'react'
import { MdCheck, MdChevronRight, MdLocationOn } from 'react-icons/md'

export const cx = (...c: (string | false | null | undefined)[]) => c.filter(Boolean).join(' ')

export function Spinner({ size, white }: { size?: 'sm'; white?: boolean }) {
  return <span className={cx('spinner', size, white && 'white')} role="progressbar" aria-label="Loading" />
}

export function CenteredSpinner({ pad = 40 }: { pad?: number }) {
  return (
    <div className="center" style={{ padding: pad }}>
      <Spinner />
    </div>
  )
}

interface CardProps {
  children: ReactNode
  elevated?: boolean
  padding?: number | string
  onClick?: MouseEventHandler
  radius?: number
  color?: string
  className?: string
  style?: CSSProperties
}
export function SoftCard({ children, elevated, padding, onClick, radius, color, className, style }: CardProps) {
  return (
    <div
      className={cx('soft-card', elevated && 'elevated', onClick && 'clickable', className)}
      onClick={onClick}
      style={{ padding, borderRadius: radius, background: color, ...style }}
    >
      {children}
    </div>
  )
}

interface ButtonProps {
  children?: ReactNode
  onClick?: MouseEventHandler<HTMLButtonElement>
  variant?: 'primary' | 'solid' | 'outlined' | 'text' | 'danger' | 'neutral'
  size?: 'sm'
  block?: boolean
  disabled?: boolean
  loading?: boolean
  icon?: ReactNode
  type?: 'button' | 'submit'
  className?: string
  style?: CSSProperties
  title?: string
}
export function Button({ children, onClick, variant = 'primary', size, block, disabled, loading, icon, type = 'button', className, style, title }: ButtonProps) {
  return (
    <button
      type={type}
      title={title}
      className={cx('btn', `btn-${variant}`, size && `btn-${size}`, block && 'btn-block', className)}
      onClick={onClick}
      disabled={disabled || loading}
      style={style}
    >
      {loading ? <Spinner size="sm" white={variant === 'primary' || variant === 'solid' || variant === 'danger'} /> : icon}
      {children}
    </button>
  )
}
export const PrimaryButton = Button

export function IconButton({ children, onClick, title, style, className }: { children: ReactNode; onClick?: MouseEventHandler; title?: string; style?: CSSProperties; className?: string }) {
  return (
    <button type="button" className={cx('icon-btn', className)} onClick={onClick} title={title} aria-label={title} style={style}>
      {children}
    </button>
  )
}

export function LocationPill({ label, icon = <MdLocationOn size={14} />, color = 'var(--primary)', onClick }: { label: string; icon?: ReactNode; color?: string; onClick?: () => void }) {
  return (
    <span
      className="pill"
      style={{ color, background: `color-mix(in srgb, ${color} 10%, transparent)`, cursor: onClick ? 'pointer' : undefined }}
      onClick={onClick}
    >
      {icon}
      {label}
    </span>
  )
}

export function SectionHeader({ title, onSeeAll, seeAllText = 'See all' }: { title: string; onSeeAll?: () => void; seeAllText?: string }) {
  return (
    <div className="row between">
      <h3 className="t-head-s ellipsis">{title}</h3>
      {onSeeAll && (
        <button type="button" className="btn-text btn" style={{ padding: '4px 8px', fontSize: 14 }} onClick={onSeeAll}>
          {seeAllText}
          <MdChevronRight size={18} />
        </button>
      )}
    </div>
  )
}

export function AvatarWithRing({ imageUrl, initials, size = 44, ringColor = 'var(--primary)', onClick }: { imageUrl?: string | null; initials: string; size?: number; ringColor?: string; onClick?: () => void }) {
  const [broken, setBroken] = useState(false)
  return (
    <div
      onClick={onClick}
      style={{
        width: size + 4, height: size + 4, borderRadius: '50%', padding: 2, flexShrink: 0,
        background: `linear-gradient(135deg, ${ringColor}, color-mix(in srgb, ${ringColor} 60%, transparent))`,
        cursor: onClick ? 'pointer' : undefined,
      }}
    >
      <div style={{ background: '#fff', borderRadius: '50%', padding: 2, width: '100%', height: '100%' }}>
        <div style={{ borderRadius: '50%', overflow: 'hidden', width: '100%', height: '100%', background: 'var(--surface-variant)', display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
          {imageUrl && !broken ? (
            <img src={imageUrl} alt="" onError={() => setBroken(true)} style={{ width: '100%', height: '100%', objectFit: 'cover' }} />
          ) : (
            <span style={{ fontSize: size * 0.4, fontWeight: 600, color: 'var(--text-2)' }}>{initials ? initials[0].toUpperCase() : '?'}</span>
          )}
        </div>
      </div>
    </div>
  )
}
export const AvatarRing = AvatarWithRing

export function Field({ label, children, hint }: { label?: string; children: ReactNode; hint?: string }) {
  return (
    <div className="field">
      {label && <label>{label}</label>}
      {children}
      {hint && <span className="t-body-s">{hint}</span>}
    </div>
  )
}

export function TextInput({ icon, ...props }: React.InputHTMLAttributes<HTMLInputElement> & { icon?: ReactNode }) {
  if (!icon) return <input {...props} className={cx('input', props.className)} />
  return (
    <div className="input-wrap">
      <span className="input-icon">{icon}</span>
      <input {...props} className={cx('input', props.className)} />
    </div>
  )
}

/** Popup menu anchored to a trigger. */
export function Menu({ trigger, children, align = 'right' }: { trigger: ReactNode; children: (close: () => void) => ReactNode; align?: 'left' | 'right' }) {
  const [open, setOpen] = useState(false)
  const ref = useRef<HTMLDivElement>(null)
  useEffect(() => {
    if (!open) return
    const onDoc = (e: MouseEvent) => {
      if (!ref.current?.contains(e.target as Node)) setOpen(false)
    }
    document.addEventListener('mousedown', onDoc)
    return () => document.removeEventListener('mousedown', onDoc)
  }, [open])
  return (
    <div className="menu-anchor" ref={ref}>
      <div onClick={() => setOpen((o) => !o)}>{trigger}</div>
      {open && (
        <div className="menu" style={align === 'left' ? { left: 0, right: 'auto' } : undefined}>
          {children(() => setOpen(false))}
        </div>
      )}
    </div>
  )
}
export const MenuItem = ({ children, onClick, color }: { children: ReactNode; onClick?: () => void; color?: string }) => (
  <button type="button" className="menu-item" onClick={onClick} style={{ color }}>
    {children}
  </button>
)
export const MenuDivider = () => <div className="menu-divider" />

export function CheckRow({ children }: { children: ReactNode }) {
  return (
    <div className="row gap-sm" style={{ alignItems: 'flex-start' }}>
      <MdCheck size={18} color="var(--secondary)" style={{ marginTop: 2, flexShrink: 0 }} />
      <span style={{ fontWeight: 500 }}>{children}</span>
    </div>
  )
}

export function EmptyState({ icon, title, message, action }: { icon?: ReactNode; title: string; message?: string; action?: ReactNode }) {
  return (
    <div className="col center gap-sm" style={{ padding: 40, textAlign: 'center' }}>
      {icon && <div style={{ color: 'var(--text-3)' }}>{icon}</div>}
      <div className="t-title-l">{title}</div>
      {message && <div className="muted">{message}</div>}
      {action}
    </div>
  )
}
