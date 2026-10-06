import { useEffect, type ReactNode } from 'react'
import { createPortal } from 'react-dom'
import { cx } from './ui'

interface DialogProps {
  open?: boolean
  onClose?: () => void
  title?: ReactNode
  children?: ReactNode
  actions?: ReactNode
  size?: 'normal' | 'wide' | 'full'
  dismissible?: boolean
  contentStyle?: React.CSSProperties
}

export function Dialog({ open = true, onClose, title, children, actions, size = 'normal', dismissible = true, contentStyle }: DialogProps) {
  useEffect(() => {
    if (!open || !dismissible) return
    const onKey = (e: KeyboardEvent) => e.key === 'Escape' && onClose?.()
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  }, [open, dismissible, onClose])

  if (!open) return null
  return createPortal(
    <div
      className="dialog-backdrop"
      onMouseDown={(e) => {
        if (dismissible && e.target === e.currentTarget) onClose?.()
      }}
    >
      <div className={cx('dialog', size === 'wide' && 'wide', size === 'full' && 'full')} role="dialog" aria-modal="true">
        {title && <div className="dialog-title">{title}</div>}
        <div className="dialog-content" style={contentStyle}>{children}</div>
        {actions && <div className="dialog-actions">{actions}</div>}
      </div>
    </div>,
    document.body,
  )
}
