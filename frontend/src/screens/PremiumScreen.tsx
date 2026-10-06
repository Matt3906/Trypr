import { useEffect, useState } from 'react'
import { doc, Timestamp } from 'firebase/firestore'
import { format } from 'date-fns'
import { MdBolt, MdLogin, MdSettings } from 'react-icons/md'
import { useNavigate, useSearchParams } from 'react-router-dom'
import { db } from '@/firebase'
import PageShell from '@/components/PageShell'
import { Button, CheckRow, SoftCard } from '@/components/ui'
import { useAuth } from '@/context/Auth'
import { useFeedback } from '@/context/Feedback'
import { useDocument } from '@/hooks/useFirestore'
import { openExternalUrl } from '@/services/openExternalUrl'
import { createBillingPortalUrl, createCheckoutUrl, StripeBillingError } from '@/services/stripeBilling'
import { isPremiumFromData } from '@/services/premiumAccess'

type Plan = 'monthly' | 'yearly'

function PlanCard({ plan, selected, title, price, detail, badge, onSelect }: { plan: Plan; selected: boolean; title: string; price: string; detail: string; badge?: string; onSelect: (p: Plan) => void }) {
  return (
    <div
      onClick={() => onSelect(plan)}
      style={{
        borderRadius: 'var(--r-lg)', padding: 12, cursor: 'pointer', transition: 'all .18s',
        border: `${selected ? 2.2 : 1.2}px solid ${selected ? 'var(--primary)' : '#d6e2ee'}`,
        background: selected ? '#eff7ff' : 'rgba(255,255,255,.9)',
      }}
    >
      <div className="row">
        <span className="t-title-l bold">{title}</span>
        <span className="grow" />
        {badge && <span style={{ background: 'rgba(0,137,123,.14)', color: 'var(--secondary)', fontSize: 11, fontWeight: 700, padding: '4px 8px', borderRadius: 999 }}>{badge}</span>}
      </div>
      <div style={{ fontSize: 30, fontWeight: 800, letterSpacing: -0.6, marginTop: 8 }}>{price}</div>
      <div className="muted semibold" style={{ marginTop: 2 }}>{detail}</div>
    </div>
  )
}

const FEATURES = [
  'AI activity suggestions for each stop',
  'AI accommodation and route ideas',
  'Faster itinerary planning for complex trips',
  'Premium-only feature releases',
]

export default function PremiumScreen() {
  const { user } = useAuth()
  const { toast } = useFeedback()
  const navigate = useNavigate()
  const [params] = useSearchParams()
  const [plan, setPlan] = useState<Plan>('yearly')
  const [checkoutBusy, setCheckoutBusy] = useState(false)
  const [portalBusy, setPortalBusy] = useState(false)

  const ent = useDocument(user ? doc(db, 'userEntitlements', user.uid) : null, [user?.uid])
  const data = ent.data?.data() ?? {}
  const premium = isPremiumFromData(data)
  const status = String(data.subscriptionStatus ?? '').toLowerCase()
  const currentPlan = String(data.premiumPlan ?? '').toLowerCase()
  const periodEnd = data.currentPeriodEnd instanceof Timestamp ? format(data.currentPeriodEnd.toDate(), 'MMM d, yyyy') : ''

  useEffect(() => {
    const s = params.get('checkout')?.trim().toLowerCase()
    if (s === 'success') toast('Payment received. Premium will activate in a moment.')
    else if (s === 'cancelled') toast('Checkout cancelled.')
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  const run = async (fn: () => Promise<string>, setBusy: (b: boolean) => void, failPrefix: string) => {
    setBusy(true)
    try {
      const url = await fn()
      if (!openExternalUrl(url, { sameTab: true })) toast(`Open this URL manually: ${url}`)
    } catch (e: any) {
      toast(e instanceof StripeBillingError ? e.message : `${failPrefix}: ${e?.message ?? e}`)
    } finally {
      setBusy(false)
    }
  }

  const priceLabel = plan === 'yearly' ? '$36/year' : '$4/month'

  return (
    <PageShell bodyStyle={{ background: 'linear-gradient(#eff7ff, var(--bg))' }}>
      <div className="container col gap-md" style={{ maxWidth: 980, paddingBottom: 36 }}>
        <div style={{ borderRadius: 'var(--r-xl)', background: 'linear-gradient(135deg,#1c77c3,#30a8d8,#2cb59a)', boxShadow: 'var(--shadow-elevated)', padding: 20, color: '#fff' }}>
          <div style={{ fontSize: 30, fontWeight: 800, letterSpacing: -0.6 }}>Trypr Premium</div>
          <div style={{ fontWeight: 500, fontSize: 16, marginTop: 8 }}>AI planning that saves hours on every trip.</div>
        </div>

        {!user ? (
          <SoftCard elevated padding={20}>
            <h3 className="t-title-l bold">Sign in to continue</h3>
            <p className="muted" style={{ margin: '8px 0 16px' }}>You need an account to subscribe and manage billing.</p>
            <Button icon={<MdLogin size={18} />} onClick={() => navigate('/sign-in')}>Sign in</Button>
          </SoftCard>
        ) : (
          <>
            <SoftCard elevated padding={16}>
              <div className="row wrap between" style={{ gap: 16 }}>
                {[
                  ['Status', premium ? 'Active' : status || 'Free', premium ? 'var(--success)' : 'var(--text-2)'],
                  ['Current Plan', currentPlan === 'yearly' ? '$36/year' : currentPlan === 'monthly' ? '$4/month' : 'Not set', 'var(--primary-dark)'],
                  ['Renewal', periodEnd || '—', 'var(--text)'],
                ].map(([l, v, c]) => (
                  <div key={l}>
                    <div className="muted semibold" style={{ fontSize: 13 }}>{l}</div>
                    <div className="bold" style={{ color: c, fontSize: 16, marginTop: 4 }}>{v}</div>
                  </div>
                ))}
              </div>
            </SoftCard>

            <SoftCard elevated padding={16}>
              <h3 className="t-head-s bold">Choose billing cycle</h3>
              <p className="muted" style={{ margin: '8px 0 12px' }}>Monthly: $4/month • Yearly: $36/year (save 25%)</p>
              <div className="plan-grid">
                <PlanCard plan="monthly" selected={plan === 'monthly'} title="Monthly" price="$4" detail="per month" onSelect={setPlan} />
                <PlanCard plan="yearly" selected={plan === 'yearly'} title="Yearly" price="$36" detail="per year" badge="Best value" onSelect={setPlan} />
              </div>
            </SoftCard>

            <SoftCard elevated padding={16}>
              <div className="col gap-sm">
                <Button icon={<MdBolt size={18} />} loading={checkoutBusy} onClick={() => run(() => createCheckoutUrl(plan, window.location.origin), setCheckoutBusy, 'Checkout failed')}>
                  {premium ? 'Switch to' : 'Start'} {priceLabel}
                </Button>
                <Button variant="outlined" icon={<MdSettings size={18} />} loading={portalBusy} onClick={() => run(() => createBillingPortalUrl(window.location.origin), setPortalBusy, 'Unable to open billing portal')}>
                  Manage billing in Stripe
                </Button>
              </div>
            </SoftCard>
          </>
        )}

        <SoftCard padding={16}>
          <h3 className="t-head-s bold" style={{ marginBottom: 8 }}>What you get</h3>
          <div className="col gap-sm">{FEATURES.map((f) => <CheckRow key={f}>{f}</CheckRow>)}</div>
        </SoftCard>
      </div>
    </PageShell>
  )
}
