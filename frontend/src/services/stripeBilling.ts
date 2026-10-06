import { httpsCallable } from 'firebase/functions'
import { functions } from '@/firebase'

export class StripeBillingError extends Error {}

function friendlyMessage(e: { code?: string; message?: string }): string {
  const code = (e.code ?? '').replace('functions/', '')
  const message = (e.message ?? '').trim()
  if (code === 'unauthenticated') return 'Please sign in first.'
  if (code === 'failed-precondition' && message) return message
  if (code === 'invalid-argument' && message) return message
  if (code === 'permission-denied') return 'You do not have permission to start billing for this account.'
  if (message) return message
  return 'Billing request failed. Please try again.'
}

async function callForUrl(name: string, payload: Record<string, any>, emptyMsg: string): Promise<string> {
  try {
    const res = await httpsCallable<Record<string, any>, { url?: string }>(functions, name)(payload)
    const url = String(res.data?.url ?? '').trim()
    if (!url) throw new StripeBillingError(emptyMsg)
    return url
  } catch (e: any) {
    if (e instanceof StripeBillingError) throw e
    throw new StripeBillingError(friendlyMessage(e))
  }
}

export async function createCheckoutUrl(plan: string, returnOrigin?: string): Promise<string> {
  const normalized = plan.trim().toLowerCase()
  if (normalized !== 'monthly' && normalized !== 'yearly') {
    throw new StripeBillingError('Invalid plan. Use monthly or yearly.')
  }
  const payload: Record<string, any> = { plan: normalized }
  if (returnOrigin?.trim()) payload.returnOrigin = returnOrigin.trim()
  return callForUrl('createStripeCheckoutSession', payload, 'Checkout URL was not returned.')
}

export async function createBillingPortalUrl(returnOrigin?: string): Promise<string> {
  const payload: Record<string, any> = {}
  if (returnOrigin?.trim()) payload.returnOrigin = returnOrigin.trim()
  return callForUrl('createStripeBillingPortal', payload, 'Billing portal URL was not returned.')
}
