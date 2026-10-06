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
        <div style={{ width: '100%', maxWidth: 440, background: '#fff', borderRadius: 'var(--r-xxl)', boxShadow: 'var(--shadow-elevated)', padding: 32 }} className="col">
          <div className="center" style={{ width: 56, height: 56, borderRadius: 'var(--r-lg)', background: 'rgba(74,173,232,.1)', color: 'var(--primary)' }}>
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

export function OrDivider() {
  return (
    <div className="row" style={{ margin: '20px 0' }}>
      <hr className="divider grow" />
      <span className="t-body-s" style={{ padding: '0 16px' }}>or continue with</span>
      <hr className="divider grow" />
    </div>
  )
}
