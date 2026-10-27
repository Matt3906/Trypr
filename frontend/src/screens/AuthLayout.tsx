import type { ReactNode } from 'react'
import PageShell from '@/components/PageShell'

/** Card centred over a darkened photo; shared by sign-in and create-account. */
export default function AuthLayout({ bg, icon, title, subtitle, children }: { bg: string; icon: ReactNode; title: string; subtitle: string; children: ReactNode }) {
  return (
    <PageShell>
      <div
        className="hero-bg"
        style={{ backgroundImage: `linear-gradient(rgba(0,0,0,.35), rgba(0,0,0,.35)), url(/images/${bg})` }}
      >
        <div style={{ width: '100%', maxWidth: 440, background: 'rgba(255,255,255,0.62)', WebkitBackdropFilter: 'blur(32px) saturate(190%)', backdropFilter: 'blur(32px) saturate(190%)', border: '1px solid rgba(255,255,255,0.8)', borderRadius: 32, boxShadow: 'var(--glass-hi), 0 24px 60px rgba(74, 48, 30,0.22)', padding: 32 }} className="col">
          <div className="center" style={{ width: 56, height: 56, borderRadius: 'var(--r-lg)', background: 'rgba(44, 156, 192,.1)', color: 'var(--primary)' }}>
            {icon}
          </div>
          <h1 className="t-display-s" style={{ marginTop: 20 }}>{title}</h1>
          <p className="muted" style={{ marginTop: 8, marginBottom: 24 }}>{subtitle}</p>
          {children}
        </div>
      </div>
    </PageShell>
  )
}
