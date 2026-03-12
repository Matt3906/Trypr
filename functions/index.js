/* eslint-disable no-console */

const fs = require('fs');
const path = require('path');

const functions = require('firebase-functions');
const admin = require('firebase-admin');
const { GoogleAuth } = require('google-auth-library');
const Stripe = require('stripe');

function loadDotEnvIfPresent() {
  try {
    const envPath = path.join(__dirname, '.env');
    if (!fs.existsSync(envPath)) return;

    const raw = fs.readFileSync(envPath, 'utf8');
    for (const line of raw.split(/\r?\n/)) {
      const trimmed = line.trim();
      if (!trimmed || trimmed.startsWith('#')) continue;

      const eq = trimmed.indexOf('=');
      if (eq < 1) continue;

      const key = trimmed.slice(0, eq).trim();
      if (!key) continue;
      if (process.env[key] != null) continue; // don't override real env vars

      let value = trimmed.slice(eq + 1).trim();
      if (
        (value.startsWith('"') && value.endsWith('"')) ||
        (value.startsWith("'") && value.endsWith("'"))
      ) {
        value = value.slice(1, -1);
      }

      process.env[key] = value;
    }
  } catch (e) {
    console.warn('[dotenv] Failed to load functions/.env:', e);
  }
}

loadDotEnvIfPresent();

admin.initializeApp();

const ORS_ALLOWED_PROFILES = new Set([
  'rail',
  'driving-car',
  'foot-walking',
  'cycling',
  'cycling-regular',
  'foot-hiking',
]);
const OVERPASS_ENDPOINTS = [
  'https://maps.mail.ru/osm/tools/overpass/api/interpreter',
  'https://overpass-api.de/api/interpreter',
  'https://lz4.overpass-api.de/api/interpreter',
  'https://overpass.kumi.systems/api/interpreter',
  'https://overpass.private.coffee/api/interpreter',
];
const OVERPASS_CACHE_TTL_MS = 20 * 60 * 1000;
const OVERPASS_CACHE_MAX_ENTRIES = 48;
const overpassResponseCache = new Map();

function getCachedOverpassEntry(query, { allowStale = false } = {}) {
  const key = String(query || '').trim();
  if (!key) return null;

  const cached = overpassResponseCache.get(key);
  if (!cached) return null;

  const ageMs = Date.now() - cached.cachedAt;
  if (!allowStale && ageMs > OVERPASS_CACHE_TTL_MS) {
    overpassResponseCache.delete(key);
    return null;
  }

  return cached;
}

function cacheOverpassResponse(query, text) {
  const key = String(query || '').trim();
  if (!key || !text) return;

  overpassResponseCache.set(key, {
    cachedAt: Date.now(),
    text,
  });

  while (overpassResponseCache.size > OVERPASS_CACHE_MAX_ENTRIES) {
    const oldestKey = overpassResponseCache.keys().next().value;
    if (oldestKey == null) break;
    overpassResponseCache.delete(oldestKey);
  }
}

function setRouteProxyCors(res, originHeader) {
  const origin = String(originHeader || '*').trim() || '*';
  res.set('Access-Control-Allow-Origin', origin);
  res.set('Vary', 'Origin');
  res.set('Access-Control-Allow-Methods', 'POST, OPTIONS');
  res.set('Access-Control-Allow-Headers', 'Content-Type');
}

function parseRouteBody(req) {
  if (req.body && typeof req.body === 'object') return req.body;
  const raw = req.rawBody ? req.rawBody.toString('utf8') : '';
  if (!raw) return {};
  try {
    return JSON.parse(raw);
  } catch (_) {
    return {};
  }
}

function normalizeRouteCoordinates(raw) {
  if (!Array.isArray(raw)) return [];
  const out = [];
  for (const pair of raw) {
    if (!Array.isArray(pair) || pair.length < 2) continue;
    const lon = Number(pair[0]);
    const lat = Number(pair[1]);
    if (!Number.isFinite(lat) || !Number.isFinite(lon)) continue;
    out.push([lon, lat]);
  }
  return out;
}

async function fetchWithTimeout(url, options, timeoutMs = 12000) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    return await fetch(url, {
      ...options,
      signal: controller.signal,
    });
  } finally {
    clearTimeout(timer);
  }
}

function normalizeOrsRouteResponse(profile, data) {
  const features = Array.isArray(data?.features) ? data.features : [];
  if (features.length < 1) {
    return {
      ok: false,
      status: 502,
      body: {
        error: 'ORS_GEOMETRY_MISSING',
        provider: 'ors',
        profile,
      },
    };
  }

  const feature = features[0] || {};
  const geometry = feature.geometry || {};
  const coordinates = Array.isArray(geometry.coordinates) ? geometry.coordinates : [];
  if (coordinates.length < 2) {
    return {
      ok: false,
      status: 502,
      body: {
        error: 'ORS_GEOMETRY_INVALID',
        provider: 'ors',
        profile,
      },
    };
  }

  const path = [];
  for (const pair of coordinates) {
    if (!Array.isArray(pair) || pair.length < 2) continue;
    const lon = Number(pair[0]);
    const lat = Number(pair[1]);
    if (!Number.isFinite(lat) || !Number.isFinite(lon)) continue;
    path.push([lat, lon]);
  }
  if (path.length < 2) {
    return {
      ok: false,
      status: 502,
      body: {
        error: 'ORS_PATH_INVALID',
        provider: 'ors',
        profile,
      },
    };
  }

  const props = feature.properties || {};
  const summary = props.summary || {};
  const distanceMeters = Number(summary.distance) || 0;
  const durationSeconds = Number(summary.duration) || 0;
  const instructions = [];
  const segments = Array.isArray(props.segments) ? props.segments : [];
  for (const segment of segments) {
    const steps = Array.isArray(segment?.steps) ? segment.steps : [];
    for (const step of steps) {
      const instruction = String(step?.instruction || '').trim();
      if (instruction) instructions.push(instruction);
    }
  }

  return {
    ok: true,
    status: 200,
    body: {
      provider: 'ors',
      profile,
      path,
      distanceMeters,
      durationSeconds,
      instructions,
    },
  };
}

async function routeViaOpenRouteService(profile, coordinates) {
  const normalizedProfile = String(profile || '').trim().toLowerCase();
  if (!normalizedProfile || !ORS_ALLOWED_PROFILES.has(normalizedProfile)) {
    return {
      ok: false,
      status: 400,
      body: {
        error: 'UNSUPPORTED_ORS_PROFILE',
        provider: 'ors',
        profile: normalizedProfile,
      },
    };
  }

  const key = String(process.env.OPENROUTESERVICE_API_KEY || '').trim();
  if (!key) {
    return {
      ok: false,
      status: 500,
      body: {
        error: 'ORS_KEY_MISSING',
        provider: 'ors',
        profile: normalizedProfile,
      },
    };
  }

  const url = `https://api.openrouteservice.org/v2/directions/${normalizedProfile}/geojson`;
  try {
    const resp = await fetchWithTimeout(
      url,
      {
        method: 'POST',
        headers: {
          Authorization: key,
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({ coordinates }),
      },
      15000
    );
    const text = await resp.text();
    console.log(
      '[routeProxy] upstream provider=ors profile=%s status=%d',
      normalizedProfile,
      resp.status
    );

    if (!resp.ok) {
      return {
        ok: false,
        status: resp.status,
        body: {
          error: 'ORS_UPSTREAM_ERROR',
          provider: 'ors',
          profile: normalizedProfile,
          upstreamStatus: resp.status,
          upstreamBodyPreview: text.slice(0, 400),
        },
      };
    }

    let data = {};
    try {
      data = JSON.parse(text);
    } catch (_) {
      return {
        ok: false,
        status: 502,
        body: {
          error: 'ORS_INVALID_JSON',
          provider: 'ors',
          profile: normalizedProfile,
        },
      };
    }
    return normalizeOrsRouteResponse(normalizedProfile, data);
  } catch (e) {
    return {
      ok: false,
      status: 502,
      body: {
        error: 'ORS_REQUEST_FAILED',
        provider: 'ors',
        profile: normalizedProfile,
        message: e?.message || String(e),
      },
    };
  }
}

async function routeViaGraphHopper(profile, coordinates) {
  const normalizedProfile = String(profile || '').trim().toLowerCase() || 'hike';
  const key = String(process.env.GRAPHHOPPER_API_KEY || '').trim();
  if (!key) {
    return {
      ok: false,
      status: 500,
      body: {
        error: 'GRAPHHOPPER_KEY_MISSING',
        provider: 'graphhopper',
        profile: normalizedProfile,
      },
    };
  }

  if (!Array.isArray(coordinates) || coordinates.length < 2) {
    return {
      ok: false,
      status: 400,
      body: {
        error: 'COORDINATES_INVALID',
        provider: 'graphhopper',
        profile: normalizedProfile,
      },
    };
  }

  const qp = new URLSearchParams();
  qp.set('profile', normalizedProfile);
  qp.set('points_encoded', 'false');
  qp.set('key', key);
  for (const pair of coordinates) {
    const lon = Number(pair[0]);
    const lat = Number(pair[1]);
    if (!Number.isFinite(lat) || !Number.isFinite(lon)) continue;
    qp.append('point', `${lat},${lon}`);
  }
  const url = `https://graphhopper.com/api/1/route?${qp.toString()}`;
  try {
    const resp = await fetchWithTimeout(url, { method: 'GET' }, 15000);
    const text = await resp.text();
    console.log(
      '[routeProxy] upstream provider=graphhopper profile=%s status=%d',
      normalizedProfile,
      resp.status
    );
    if (!resp.ok) {
      return {
        ok: false,
        status: resp.status,
        body: {
          error: 'GRAPHHOPPER_UPSTREAM_ERROR',
          provider: 'graphhopper',
          profile: normalizedProfile,
          upstreamStatus: resp.status,
          upstreamBodyPreview: text.slice(0, 400),
        },
      };
    }

    let data = {};
    try {
      data = JSON.parse(text);
    } catch (_) {
      return {
        ok: false,
        status: 502,
        body: {
          error: 'GRAPHHOPPER_INVALID_JSON',
          provider: 'graphhopper',
          profile: normalizedProfile,
        },
      };
    }

    const paths = Array.isArray(data?.paths) ? data.paths : [];
    if (paths.length < 1) {
      return {
        ok: false,
        status: 502,
        body: {
          error: 'GRAPHHOPPER_PATH_MISSING',
          provider: 'graphhopper',
          profile: normalizedProfile,
        },
      };
    }
    const first = paths[0] || {};
    const points = first.points || {};
    const coordinatesRaw = Array.isArray(points.coordinates) ? points.coordinates : [];
    const path = [];
    for (const pair of coordinatesRaw) {
      if (!Array.isArray(pair) || pair.length < 2) continue;
      const lon = Number(pair[0]);
      const lat = Number(pair[1]);
      if (!Number.isFinite(lat) || !Number.isFinite(lon)) continue;
      path.push([lat, lon]);
    }
    if (path.length < 2) {
      return {
        ok: false,
        status: 502,
        body: {
          error: 'GRAPHHOPPER_PATH_INVALID',
          provider: 'graphhopper',
          profile: normalizedProfile,
        },
      };
    }

    return {
      ok: true,
      status: 200,
      body: {
        provider: 'graphhopper',
        profile: normalizedProfile,
        path,
        distanceMeters: Number(first.distance) || 0,
        durationSeconds: (Number(first.time) || 0) / 1000,
        instructions: [],
      },
    };
  } catch (e) {
    return {
      ok: false,
      status: 502,
      body: {
        error: 'GRAPHHOPPER_REQUEST_FAILED',
        provider: 'graphhopper',
        profile: normalizedProfile,
        message: e?.message || String(e),
      },
    };
  }
}

exports.routeProxy = functions.https.onRequest(async (req, res) => {
  setRouteProxyCors(res, req.headers.origin);

  if (req.method === 'OPTIONS') {
    res.status(204).send('');
    return;
  }

  if (req.method !== 'POST') {
    res.status(405).json({ error: 'METHOD_NOT_ALLOWED' });
    return;
  }

  const body = parseRouteBody(req);
  const provider = String(body?.provider || 'ors').trim().toLowerCase();
  const profile = String(body?.profile || '').trim().toLowerCase();
  const coordinates = normalizeRouteCoordinates(body?.coordinates);

  if (coordinates.length < 2) {
    res.status(400).json({
      error: 'COORDINATES_INVALID',
      provider,
      profile,
    });
    return;
  }

  console.log(
    '[routeProxy] request provider=%s profile=%s points=%d',
    provider,
    profile,
    coordinates.length
  );

  let result;
  if (provider === 'ors') {
    result = await routeViaOpenRouteService(profile, coordinates);
  } else if (provider === 'graphhopper') {
    result = await routeViaGraphHopper(profile, coordinates);
  } else {
    res.status(400).json({
      error: 'UNSUPPORTED_PROVIDER',
      provider,
      profile,
    });
    return;
  }

  res.status(result.status).json(result.body);
});

exports.overpassProxy = functions.https.onRequest(async (req, res) => {
  setRouteProxyCors(res, req.headers.origin);

  if (req.method === 'OPTIONS') {
    res.status(204).send('');
    return;
  }

  if (req.method !== 'POST') {
    res.status(405).json({ error: 'METHOD_NOT_ALLOWED' });
    return;
  }

  const body = parseRouteBody(req);
  const query = String(body?.query || '').trim();
  if (!query) {
    res.status(400).json({ error: 'QUERY_REQUIRED' });
    return;
  }

  const freshCached = getCachedOverpassEntry(query);
  if (freshCached) {
    res.set('X-Trypr-Overpass-Cache', 'HIT');
    res.status(200).type('application/json').send(freshCached.text);
    return;
  }

  let lastError = null;
  for (const endpoint of OVERPASS_ENDPOINTS) {
    try {
      const resp = await fetchWithTimeout(
        endpoint,
        {
          method: 'POST',
          headers: {
            'Content-Type': 'application/x-www-form-urlencoded',
          },
          body: `data=${encodeURIComponent(query)}`,
        },
        14000
      );

      if (!resp.ok) {
        lastError = {
          endpoint,
          status: resp.status,
          body: (await resp.text()).slice(0, 400),
        };
        console.warn(
          '[overpassProxy] upstream_failed endpoint=%s status=%d',
          endpoint,
          resp.status
        );
        continue;
      }

      const text = await resp.text();
      try {
        JSON.parse(text);
        cacheOverpassResponse(query, text);
        console.log(
          '[overpassProxy] upstream_ok endpoint=%s bytes=%d',
          endpoint,
          Buffer.byteLength(text, 'utf8')
        );
        res.set('X-Trypr-Overpass-Cache', 'MISS');
        res.status(200).type('application/json').send(text);
        return;
      } catch (_) {
        lastError = {
          endpoint,
          status: 502,
          body: text.slice(0, 400),
        };
      }
    } catch (e) {
      lastError = {
        endpoint,
        status: 502,
        body: e?.message || String(e),
      };
      console.warn('[overpassProxy] request_failed endpoint=%s err=%s', endpoint, lastError.body);
    }
  }

  const staleCached = getCachedOverpassEntry(query, { allowStale: true });
  if (staleCached) {
    console.warn(
      '[overpassProxy] serving_stale_cache bytes=%d',
      Buffer.byteLength(staleCached.text, 'utf8')
    );
    res.set('X-Trypr-Overpass-Cache', 'STALE');
    res.status(200).type('application/json').send(staleCached.text);
    return;
  }

  res.status(502).json({
    error: 'OVERPASS_UPSTREAM_FAILED',
    lastError,
  });
});

function normalizeRoles(value) {
  if (Array.isArray(value)) return value.map((r) => String(r).toLowerCase());
  if (typeof value === 'string') return [value.toLowerCase()];
  return [];
}

/**
 * Premium access control.
 *
 * Logic:
 * - If user.role === 'admin' (or includes 'admin') -> allow
 * - If user.subscription === 'premium' -> allow
 * - else deny
 */
function canAccessPremiumFeatures(user) {
  const roles = normalizeRoles(user?.role ?? user?.roles);
  if (roles.includes('admin')) return true;

  const subscription = String(user?.subscription ?? '').toLowerCase();
  if (subscription === 'premium') return true;

  // Back-compat for existing data fields.
  const status = String(user?.subscriptionStatus ?? '').toLowerCase();
  if (status === 'premium') return true;

  return false;
}

async function getEntitlements(uid) {
  // Secure source of truth for premium entitlements.
  // Do not trust /users/{uid} for premium state because self-updates are allowed.
  const [entSnap, adminSnap] = await Promise.all([
    admin.firestore().doc(`userEntitlements/${uid}`).get(),
    admin.firestore().doc(`admins/${uid}`).get(),
  ]);

  const ent = entSnap.exists ? entSnap.data() : {};
  const isAdmin = adminSnap.exists;

  const subscription = String(ent?.subscription || '').toLowerCase();
  const subscriptionStatus = String(ent?.subscriptionStatus || '').toLowerCase();

  return {
    ...ent,
    subscription,
    subscriptionStatus,
    role: isAdmin ? ['admin', ...normalizeRoles(ent?.role ?? ent?.roles)] : normalizeRoles(ent?.role ?? ent?.roles),
  };
}

const STRIPE_PLAN_CONFIG = {
  monthly: {
    interval: 'month',
    amount: 400,
    displayPrice: '$4/month',
    envKey: 'STRIPE_PRICE_MONTHLY',
  },
  yearly: {
    interval: 'year',
    amount: 3600,
    displayPrice: '$36/year',
    envKey: 'STRIPE_PRICE_YEARLY',
  },
};

let stripeClient = null;

function getStripeSecretKey() {
  return (
    process.env.STRIPE_SECRET_KEY ||
    functions.config?.()?.stripe?.secret_key ||
    ''
  ).trim();
}

function getStripeWebhookSecret() {
  return (
    process.env.STRIPE_WEBHOOK_SECRET ||
    functions.config?.()?.stripe?.webhook_secret ||
    ''
  ).trim();
}

function getStripeClient() {
  if (stripeClient) return stripeClient;
  const secret = getStripeSecretKey();
  if (!secret) return null;
  stripeClient = new Stripe(secret, { apiVersion: '2024-06-20' });
  return stripeClient;
}

function normalizeStripePlan(value) {
  const plan = String(value ?? '').trim().toLowerCase();
  if (plan === 'monthly' || plan === 'yearly') return plan;
  return null;
}

function getStripePriceIdForPlan(plan) {
  const normalized = normalizeStripePlan(plan);
  if (!normalized) return '';
  const envKey = STRIPE_PLAN_CONFIG[normalized].envKey;
  return String(process.env[envKey] ?? '').trim();
}

function stripeSuccessPath() {
  const raw = String(process.env.STRIPE_SUCCESS_PATH || '/premium').trim();
  if (!raw) return '/premium';
  return raw.startsWith('/') ? raw : `/${raw}`;
}

function stripeCancelPath() {
  const raw = String(process.env.STRIPE_CANCEL_PATH || '/premium').trim();
  if (!raw) return '/premium';
  return raw.startsWith('/') ? raw : `/${raw}`;
}

function stripePortalReturnPath() {
  const raw = String(process.env.STRIPE_PORTAL_RETURN_PATH || '/premium').trim();
  if (!raw) return '/premium';
  return raw.startsWith('/') ? raw : `/${raw}`;
}

function normalizeOriginCandidate(raw) {
  const v = String(raw ?? '').trim();
  if (!v) return '';
  try {
    const url = new URL(v);
    if (!url.protocol.startsWith('http')) return '';
    return `${url.protocol}//${url.host}`;
  } catch (_) {
    return '';
  }
}

function getAllowedReturnOrigins() {
  const explicit = String(process.env.STRIPE_ALLOWED_ORIGINS || '').trim();
  const fromEnv = explicit
    ? explicit.split(',').map((v) => normalizeOriginCandidate(v)).filter(Boolean)
    : [];
  if (fromEnv.length > 0) return Array.from(new Set(fromEnv));
  return [
    'https://trypr.co',
    'https://www.trypr.co',
    'http://127.0.0.1:5500',
    'http://localhost:5500',
    'http://localhost:3000',
    'http://127.0.0.1:3000',
  ];
}

function resolveReturnOrigin(candidate, contextAuth) {
  const requested = normalizeOriginCandidate(candidate);
  const allowed = getAllowedReturnOrigins();
  if (requested && allowed.includes(requested)) return requested;
  if (requested && contextAuth && contextAuth.token && contextAuth.token.firebase && contextAuth.token.firebase.sign_in_provider) {
    // Ignore unknown origins; authenticated callers still get safe default below.
  }
  return allowed[0] || 'https://trypr.co';
}

function toPremiumStatus(subscriptionStatus) {
  const s = String(subscriptionStatus ?? '').toLowerCase();
  return s === 'active' || s === 'trialing' || s === 'past_due';
}

async function setPremiumStateForUid(uid, {
  active,
  subscriptionStatus,
  plan,
  source = 'stripe',
  stripeCustomerId = null,
  stripeSubscriptionId = null,
  stripePriceId = null,
  currentPeriodEnd = null,
}) {
  if (!uid) return;
  const now = admin.firestore.FieldValue.serverTimestamp();
  const statusLabel = String(subscriptionStatus ?? (active ? 'active' : 'inactive')).toLowerCase();
  const subscriptionValue = active ? 'premium' : 'free';
  const subscriptionType = active ? 'Premium' : 'Free';

  const entitlementPatch = {
    subscription: subscriptionValue,
    subscriptionStatus: active ? 'premium' : statusLabel,
    subscriptionType,
    premiumSource: source,
    premiumPlan: plan || null,
    stripeCustomerId: stripeCustomerId || null,
    stripeSubscriptionId: stripeSubscriptionId || null,
    stripePriceId: stripePriceId || null,
    updatedAt: now,
    ...(active
      ? { premiumEnabledAt: now }
      : { premiumDisabledAt: now }),
  };

  const userPatch = {
    subscription: subscriptionValue,
    subscriptionType,
    subscriptionStatus: active ? 'premium' : statusLabel,
    premiumSource: source,
    premiumPlan: plan || null,
    updatedAt: now,
    ...(active
      ? { premiumEnabledAt: now }
      : { premiumDisabledAt: now }),
  };

  if (currentPeriodEnd && Number.isFinite(currentPeriodEnd)) {
    const endsAt = admin.firestore.Timestamp.fromDate(
      new Date(Number(currentPeriodEnd) * 1000)
    );
    entitlementPatch.currentPeriodEnd = endsAt;
    userPatch.currentPeriodEnd = endsAt;
  }

  await Promise.all([
    admin.firestore().doc(`userEntitlements/${uid}`).set(entitlementPatch, { merge: true }),
    admin.firestore().doc(`users/${uid}`).set(userPatch, { merge: true }),
  ]);
}

async function getUidFromStripeCustomer(customerId) {
  if (!customerId) return '';
  try {
    const query = await admin
      .firestore()
      .collection('userEntitlements')
      .where('stripeCustomerId', '==', customerId)
      .limit(1)
      .get();
    if (!query.empty) return query.docs[0].id;
  } catch (_) {}
  return '';
}

function inferPlanFromPriceId(priceId) {
  const normalizedPriceId = String(priceId ?? '').trim();
  if (!normalizedPriceId) return null;
  for (const [plan, cfg] of Object.entries(STRIPE_PLAN_CONFIG)) {
    const planPriceId = String(process.env[cfg.envKey] ?? '').trim();
    if (planPriceId && normalizedPriceId === planPriceId) return plan;
  }
  return null;
}

function inferPlanFromStripePrice(price) {
  const interval = String(price?.recurring?.interval ?? '').trim().toLowerCase();
  if (interval === 'month') return 'monthly';
  if (interval === 'year') return 'yearly';
  const priceId = String(price?.id ?? '').trim();
  return inferPlanFromPriceId(priceId);
}

function buildCheckoutLineItem(plan, priceId) {
  if (priceId) {
    return { price: priceId, quantity: 1 };
  }

  const cfg = STRIPE_PLAN_CONFIG[plan];
  return {
    price_data: {
      currency: 'usd',
      unit_amount: cfg.amount,
      recurring: { interval: cfg.interval },
      product_data: {
        name: 'Trypr Premium',
        description: 'Unlock AI itinerary and route planning features.',
      },
    },
    quantity: 1,
  };
}

exports.createStripeCheckoutSession = functions.https.onCall(async (data, context) => {
  if (!context.auth) {
    throw new functions.https.HttpsError('unauthenticated', 'Sign in required');
  }

  const stripe = getStripeClient();
  if (!stripe) {
    throw new functions.https.HttpsError(
      'failed-precondition',
      'Stripe is not configured. Set STRIPE_SECRET_KEY.'
    );
  }

  const uid = context.auth.uid;
  const plan = normalizeStripePlan(data?.plan);
  if (!plan) {
    throw new functions.https.HttpsError(
      'invalid-argument',
      'Invalid plan. Use "monthly" or "yearly".'
    );
  }

  const returnOrigin = resolveReturnOrigin(data?.returnOrigin, context.auth);
  const successUrl = `${returnOrigin}${stripeSuccessPath()}?checkout=success&plan=${plan}&session_id={CHECKOUT_SESSION_ID}`;
  const cancelUrl = `${returnOrigin}${stripeCancelPath()}?checkout=cancelled&plan=${plan}`;

  const entRef = admin.firestore().doc(`userEntitlements/${uid}`);
  const userRef = admin.firestore().doc(`users/${uid}`);
  const [entSnap, userSnap] = await Promise.all([entRef.get(), userRef.get()]);
  const entData = entSnap.exists ? entSnap.data() : {};
  const userData = userSnap.exists ? userSnap.data() : {};

  let customerId = String(
    entData?.stripeCustomerId || userData?.stripeCustomerId || ''
  ).trim();

  if (customerId) {
    try {
      const customer = await stripe.customers.retrieve(customerId);
      if (customer && customer.deleted) {
        customerId = '';
      }
    } catch (_) {
      customerId = '';
    }
  }

  const email = String(context.auth.token?.email ?? userData?.email ?? '').trim();
  const name = String(context.auth.token?.name ?? userData?.displayName ?? '').trim();

  if (!customerId) {
    const created = await stripe.customers.create({
      email: email || undefined,
      name: name || undefined,
      metadata: {
        firebaseUID: uid,
      },
    });
    customerId = created.id;
  }

  const lineItem = buildCheckoutLineItem(plan, getStripePriceIdForPlan(plan));
  const session = await stripe.checkout.sessions.create({
    mode: 'subscription',
    customer: customerId,
    line_items: [lineItem],
    allow_promotion_codes: true,
    billing_address_collection: 'auto',
    success_url: successUrl,
    cancel_url: cancelUrl,
    client_reference_id: uid,
    metadata: {
      firebaseUID: uid,
      plan,
    },
    subscription_data: {
      metadata: {
        firebaseUID: uid,
        plan,
      },
    },
  });

  await Promise.all([
    entRef.set(
      {
        stripeCustomerId: customerId,
        premiumPlanPending: plan,
        premiumCheckoutSessionId: session.id,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      },
      { merge: true }
    ),
    userRef.set(
      {
        stripeCustomerId: customerId,
        premiumPlanPending: plan,
        premiumCheckoutSessionId: session.id,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      },
      { merge: true }
    ),
  ]);

  if (!session.url) {
    throw new functions.https.HttpsError(
      'internal',
      'Stripe checkout URL missing from session response.'
    );
  }

  return {
    url: session.url,
    sessionId: session.id,
    plan,
    price: STRIPE_PLAN_CONFIG[plan].displayPrice,
  };
});

exports.createStripeBillingPortal = functions.https.onCall(async (data, context) => {
  if (!context.auth) {
    throw new functions.https.HttpsError('unauthenticated', 'Sign in required');
  }

  const stripe = getStripeClient();
  if (!stripe) {
    throw new functions.https.HttpsError(
      'failed-precondition',
      'Stripe is not configured. Set STRIPE_SECRET_KEY.'
    );
  }

  const uid = context.auth.uid;
  const returnOrigin = resolveReturnOrigin(data?.returnOrigin, context.auth);
  const returnUrl = `${returnOrigin}${stripePortalReturnPath()}`;
  const [entSnap, userSnap] = await Promise.all([
    admin.firestore().doc(`userEntitlements/${uid}`).get(),
    admin.firestore().doc(`users/${uid}`).get(),
  ]);
  const entData = entSnap.exists ? entSnap.data() : {};
  const userData = userSnap.exists ? userSnap.data() : {};
  const customerId = String(
    entData?.stripeCustomerId || userData?.stripeCustomerId || ''
  ).trim();

  if (!customerId) {
    throw new functions.https.HttpsError(
      'failed-precondition',
      'No Stripe customer found for this account.'
    );
  }

  const session = await stripe.billingPortal.sessions.create({
    customer: customerId,
    return_url: returnUrl,
  });
  return { url: session.url };
});

exports.stripeWebhook = functions.https.onRequest(async (req, res) => {
  if (req.method !== 'POST') {
    res.status(405).send('Method Not Allowed');
    return;
  }

  const stripe = getStripeClient();
  const webhookSecret = getStripeWebhookSecret();
  if (!stripe || !webhookSecret) {
    res.status(500).send('Stripe webhook is not configured.');
    return;
  }

  const signatureHeader = req.headers['stripe-signature'];
  const signature = Array.isArray(signatureHeader)
    ? signatureHeader[0]
    : signatureHeader;
  if (!signature) {
    res.status(400).send('Missing Stripe signature.');
    return;
  }

  let event;
  try {
    event = stripe.webhooks.constructEvent(req.rawBody, signature, webhookSecret);
  } catch (e) {
    console.error('[stripeWebhook] Signature verification failed:', e?.message || e);
    res.status(400).send('Webhook signature verification failed.');
    return;
  }

  try {
    switch (event.type) {
      case 'checkout.session.completed': {
        const session = event.data.object;
        if (session.mode !== 'subscription') break;

        const customerId = String(session.customer ?? '').trim();
        const subscriptionId = String(session.subscription ?? '').trim();
        let uid = String(
          session?.metadata?.firebaseUID || session.client_reference_id || ''
        ).trim();
        if (!uid && customerId) {
          uid = await getUidFromStripeCustomer(customerId);
        }
        if (!uid) {
          console.warn('[stripeWebhook] checkout.session.completed missing uid', session.id);
          break;
        }

        let plan = normalizeStripePlan(session?.metadata?.plan);
        let subscriptionStatus = 'active';
        let currentPeriodEnd = null;
        let stripePriceId = '';

        if (subscriptionId) {
          const sub = await stripe.subscriptions.retrieve(subscriptionId, {
            expand: ['items.data.price'],
          });
          subscriptionStatus = String(sub?.status ?? 'active').toLowerCase();
          currentPeriodEnd = Number(sub?.current_period_end || 0) || null;
          const price = sub?.items?.data?.[0]?.price;
          stripePriceId = String(price?.id ?? '').trim();
          plan = plan || inferPlanFromStripePrice(price);
        }

        await setPremiumStateForUid(uid, {
          active: toPremiumStatus(subscriptionStatus),
          subscriptionStatus,
          plan: plan || 'monthly',
          source: 'stripe',
          stripeCustomerId: customerId || null,
          stripeSubscriptionId: subscriptionId || null,
          stripePriceId: stripePriceId || null,
          currentPeriodEnd,
        });
        break;
      }
      case 'customer.subscription.created':
      case 'customer.subscription.updated':
      case 'customer.subscription.deleted': {
        const subscription = event.data.object;
        const customerId = String(subscription.customer ?? '').trim();
        const subscriptionId = String(subscription.id ?? '').trim();
        const subscriptionStatus = String(subscription.status ?? '').toLowerCase();
        const currentPeriodEnd = Number(subscription.current_period_end || 0) || null;
        const price = subscription?.items?.data?.[0]?.price;
        const stripePriceId = String(price?.id ?? '').trim();

        let uid = String(subscription?.metadata?.firebaseUID || '').trim();
        if (!uid && customerId) {
          uid = await getUidFromStripeCustomer(customerId);
        }
        if (!uid) {
          console.warn(
            '[stripeWebhook] customer.subscription.* missing uid',
            subscriptionId
          );
          break;
        }

        const plan =
          normalizeStripePlan(subscription?.metadata?.plan) ||
          inferPlanFromStripePrice(price) ||
          'monthly';

        await setPremiumStateForUid(uid, {
          active: toPremiumStatus(subscriptionStatus),
          subscriptionStatus,
          plan,
          source: 'stripe',
          stripeCustomerId: customerId || null,
          stripeSubscriptionId: subscriptionId || null,
          stripePriceId: stripePriceId || null,
          currentPeriodEnd,
        });
        break;
      }
      default:
        break;
    }

    res.status(200).json({ received: true });
  } catch (e) {
    console.error('[stripeWebhook] handler failed:', e);
    res.status(500).send('Webhook handler failed.');
  }
});

function getVertexProject() {
  return (
    process.env.VERTEX_PROJECT ||
    functions.config?.()?.vertex?.project ||
    process.env.GCLOUD_PROJECT ||
    process.env.GCP_PROJECT ||
    admin.app()?.options?.projectId
  );
}

function getVertexLocation() {
  return process.env.VERTEX_LOCATION || functions.config?.()?.vertex?.location || 'us-central1';
}

function getVertexModel() {
  // Examples: gemini-2.0-flash-001, gemini-1.5-flash, gemini-1.5-pro
  return (
    process.env.VERTEX_MODEL || functions.config?.()?.vertex?.model || 'gemini-2.0-flash-001'
  );
}

function getVertexModelCandidates() {
  const explicit = process.env.VERTEX_MODELS || functions.config?.()?.vertex?.models;
  if (typeof explicit === 'string' && explicit.trim()) {
    const parsed = explicit
      .split(',')
      .map((v) => v.trim())
      .filter(Boolean);
    if (parsed.length > 0) return Array.from(new Set(parsed));
  }

  const configured = String(getVertexModel() || '').trim();
  const preferred = ['gemini-2.0-flash-001', 'gemini-1.5-flash'];
  const out = [];
  const push = (model) => {
    const m = String(model || '').trim();
    if (!m) return;
    if (!out.includes(m)) out.push(m);
  };

  // If configured to legacy 1.5 model, try modern default first to avoid
  // repeated NOT_FOUND/access errors on projects without 1.5 access.
  if (configured && configured !== 'gemini-1.5-flash') push(configured);
  for (const model of preferred) push(model);
  if (configured === 'gemini-1.5-flash') push(configured);

  return out;
}

const unsupportedVertexModels = new Set();

function looksRegionLabel(value) {
  const lower = String(value ?? '').trim().toLowerCase();
  if (!lower) return false;

  const exact = new Set([
    'golden horseshoe',
    'greater toronto area',
    'gta',
    'ontario',
    'canada',
    'united states',
    'usa',
    'north america',
  ]);
  if (exact.has(lower)) return true;

  // Handle labels like "Golden Horseshoe, Ontario" or "Region of Peel".
  const regionTokens = [
    ' region',
    ' county',
    ' district',
    ' province',
    ' state',
    ' territory',
    ' area',
    ' metro',
    ' greater ',
  ];
  for (const token of regionTokens) {
    if (lower.includes(token)) return true;
  }

  const countryOrProvince = ['canada', 'united states', 'usa', 'ontario', 'quebec', 'alberta'];
  for (const token of countryOrProvince) {
    if (lower === token || lower.endsWith(`, ${token}`) || lower.includes(` ${token},`)) {
      return true;
    }
  }

  return false;
}

function looksPoiLabel(value) {
  const lower = String(value ?? '').trim().toLowerCase();
  if (!lower) return false;
  const poiTokens = [
    'church',
    'cathedral',
    'mosque',
    'temple',
    'museum',
    'gallery',
    'park',
    'hotel',
    'resort',
    'restaurant',
    'cafe',
    'mall',
    'plaza',
    'school',
    'university',
    'college',
    'station',
    'airport',
    'hospital',
    'clinic',
    'arena',
    'stadium',
    'library',
    'theatre',
    'theater',
  ];
  return poiTokens.some((token) => lower.includes(token));
}

function toCityLikeLabel(value) {
  const raw = String(value ?? '').trim();
  if (!raw) return 'Nearby City';

  const parts = raw
    .split(',')
    .map((p) => p.trim())
    .filter(Boolean);

  function looksStreet(segment) {
    const s = segment.toLowerCase();
    if (/\d/.test(s)) return true;
    const roadTokens = [
      ' street',
      ' st',
      ' road',
      ' rd',
      ' avenue',
      ' ave',
      ' boulevard',
      ' blvd',
      ' drive',
      ' dr',
      ' highway',
      ' hwy',
      ' lane',
      ' ln',
    ];
    return roadTokens.some((token) => s.includes(token));
  }

  for (const part of parts) {
    if (part.length < 2) continue;
    if (looksRegionLabel(part)) continue;
    if (looksPoiLabel(part)) continue;
    if (looksStreet(part)) continue;
    return clampString(part, 120);
  }

  if (!looksRegionLabel(raw) && !looksPoiLabel(raw)) return clampString(raw, 120);
  return 'Nearby City';
}

function fallbackBudgetMultiplier(preferences) {
  const budgetTier = String(preferences?.budgetTier ?? 'moderate').toLowerCase();
  if (budgetTier === 'budget') return 0.75;
  if (budgetTier === 'luxury') return 1.5;
  return 1.0;
}

function fallbackRating(seed, i) {
  const v = 3.8 + (((seed + i * 17) % 12) / 10.0);
  return Math.max(3.8, Math.min(4.9, v));
}

function fallbackItineraryCategory(preferences) {
  const type = String(preferences?.activityType ?? 'exploring').toLowerCase();
  if (type === 'adventure') return 'Adventure';
  if (type === 'fooddrink' || type === 'food_drink' || type === 'food') return 'Restaurant';
  if (type === 'culturemuseum' || type === 'culture' || type === 'museum') return 'Museum';
  if (type === 'relaxation') return 'Free Time';
  if (type === 'sightseeing' || type === 'attractions') return 'Sightseeing';
  if (type === 'nightlife' || type === 'towns') return 'Exploring';
  return 'Exploring';
}

function normalizeMaxTravelMinutes(preferences) {
  const raw = Number(
    preferences?.maxTravelMinutes ?? preferences?.travelMinutes ?? 30
  );
  if (!Number.isFinite(raw)) return 30;
  return Math.max(10, Math.min(60, Math.round(raw)));
}

function normalizeStayType(preferences) {
  const raw = String(preferences?.stayType ?? preferences?.accommodationType ?? 'hotel')
    .trim()
    .toLowerCase();
  if (raw === 'camping' || raw === 'campground' || raw === 'camp') return 'camping';
  if (raw === 'hostel') return 'hostel';
  return 'hotel';
}

function estimateLocalRadiusKm(maxTravelMinutes) {
  // Approximate local driving envelope (mixed urban/suburban pace).
  const km = Number(maxTravelMinutes) * 0.75;
  return Math.max(6, Math.min(40, Math.round(km)));
}

function buildServerFallbackSuggestions({ module, destinationName, preferences }) {
  const city = toCityLikeLabel(destinationName);
  const seed = city
    .split('')
    .reduce((sum, ch) => (sum + ch.charCodeAt(0)) % 100000, 0);
  const multiplier = fallbackBudgetMultiplier(preferences);

  if (module === 'accommodations') {
    const stayType = normalizeStayType(preferences);
    let names;
    let basePrices;
    if (stayType === 'camping') {
      names = [
        `${city} Campground`,
        `${city} RV & Tent Site`,
        `${city} Nature Campsite`,
      ];
      basePrices = [45, 60, 75];
    } else if (stayType === 'hostel') {
      names = [
        `${city} Central Hostel`,
        `${city} Backpacker House`,
        `${city} Social Hostel`,
      ];
      basePrices = [50, 72, 95];
    } else {
      names = [
        `${city} Central Hotel`,
        `${city} Riverside Suites`,
        `${city} Boutique Stay`,
      ];
      basePrices = [120, 165, 210];
    }
    return names.map((name, i) => ({
      name,
      address: `${i + 1} Main St, ${city}`,
      price: Math.round(basePrices[i] * multiplier),
      rating: fallbackRating(seed, i),
      stayType,
      source: 'server_fallback',
    }));
  }

  const category = fallbackItineraryCategory(preferences);
  const maxTravelMinutes = normalizeMaxTravelMinutes(preferences);
  const activityNames = [
    'City highlights walk',
    'Scenic viewpoint stop',
    'Local food experience',
    'Historic district exploration',
    'Cultural center visit',
    'Neighborhood market stroll',
    'Sunset photo session',
    'Signature local attraction',
  ];
  const basePrices = [0, 12, 28, 15, 20, 10, 0, 25];
  return activityNames.map((activity, i) => ({
    name: `${city} ${activity}`,
    address: `${10 + i} Center Ave, ${city}`,
    estimatedPrice: Math.round(basePrices[i] * multiplier),
    rating: fallbackRating(seed, i),
    category,
    maxTravelMinutes,
    source: 'server_fallback',
  }));
}

function clampString(value, maxLen) {
  const s = String(value ?? '');
  if (s.length <= maxLen) return s;
  return s.slice(0, maxLen);
}

function buildPrompt({
  module,
  destinationName,
  lat,
  lon,
  startDate,
  endDate,
  preferences,
}) {
  // Keep prompts extremely small to minimize input tokens.
  // The model is constrained via `systemInstruction` + `responseMimeType`.
  const base = `location=${clampString(destinationName, 200)}; lat=${Number(lat).toFixed(6)}; lon=${Number(lon).toFixed(6)}; start=${clampString(
    startDate,
    32
  )}; end=${clampString(endDate, 32)}`;

  const prefs =
    preferences && typeof preferences === 'object'
      ? `; preferences=${JSON.stringify(preferences)}`
      : '';

  if (module === 'accommodations') {
    const stayType = normalizeStayType(preferences);
    const maxTravelMinutes = normalizeMaxTravelMinutes(preferences);
    const maxRadiusKm = estimateLocalRadiusKm(maxTravelMinutes);
    const from = clampString(preferences?.routeFrom ?? preferences?.from ?? '', 120);
    const to = clampString(preferences?.routeTo ?? preferences?.to ?? '', 120);
    const routeIntent = String(preferences?.routeIntent ?? '').trim().toLowerCase();
    const routeScope =
      routeIntent === 'between_stops' && from && to
        ? `; route_intent=between_stops; from=${from}; to=${to}`
        : '';
    const localScope = `; stay_type=${stayType}; max_travel_minutes=${maxTravelMinutes}; max_radius_km=${maxRadiusKm}`;
    return base + localScope + routeScope + prefs;
  }

  if (module === 'itinerary') {
    const maxTravelMinutes = normalizeMaxTravelMinutes(preferences);
    const maxRadiusKm = estimateLocalRadiusKm(maxTravelMinutes);
    const localScope = `; strict_local=true; max_travel_minutes=${maxTravelMinutes}; max_radius_km=${maxRadiusKm}`;
    return base + localScope + prefs;
  }

  return null;
}

const SYSTEM_INSTRUCTION_ACCOMMODATIONS =
  'You are a travel assistant API. Your ONLY job is to return a JSON array of 3 accommodation options based on the provided location and dates. Return ONLY valid JSON with keys: name, address, price_estimate (number only), rating (number 1-5), stayType. Respect stay_type exactly (hotel, hostel, camping). If route_intent=between_stops, keep options along the route between from and to and realistically within max_travel_minutes and max_radius_km of the provided coordinates. Do not include markdown formatting or conversational text.';

const SYSTEM_INSTRUCTION_ITINERARY =
  'You are a travel assistant API. Return ONLY valid JSON. Your ONLY job is to return a JSON array of 8 activity options based on the provided location and dates. Keys: name, address, estimatedPrice (number only), rating (number 1-5), category. Keep every suggestion realistically within max_travel_minutes and max_radius_km of the provided coordinates; do not suggest far county/region-wide options. No markdown or conversational text.';

function normalizeJsonText(text) {
  const raw = String(text ?? '').trim();
  if (!raw) return '';

  // Safety: remove accidental markdown code fences without retrying the model.
  if (raw.startsWith('```')) {
    const withoutFirstFence = raw.replace(/^```[a-zA-Z]*\s*/u, '');
    return withoutFirstFence.replace(/\s*```\s*$/u, '').trim();
  }
  return raw;
}

function parseStrictJson(text, { contextForLog }) {
  const normalized = normalizeJsonText(text);
  try {
    return JSON.parse(normalized);
  } catch (e) {
    // Do not auto-retry (cost control). Log enough detail to debug.
    console.error('[aiSuggest] Invalid JSON from model:', {
      context: contextForLog,
      preview: normalized.slice(0, 2000),
    });
    throw new functions.https.HttpsError('internal', 'INVALID_AI_JSON');
  }
}

async function callVertexAiJson({
  prompt,
  systemInstruction,
  maxOutputTokens = 500,
}) {
  const project = getVertexProject();
  const location = getVertexLocation();
  const models = getVertexModelCandidates();

  if (!project) {
    throw new functions.https.HttpsError(
      'failed-precondition',
      'Missing Vertex AI project. Set env var VERTEX_PROJECT.'
    );
  }

  // Uses Application Default Credentials (Cloud Functions runtime service account)
  // IMPORTANT: grant roles/aiplatform.user to the function's service account.
  const auth = new GoogleAuth({
    scopes: ['https://www.googleapis.com/auth/cloud-platform'],
  });
  const client = await auth.getClient();
  const token = await client.getAccessToken();
  const accessToken = token && token.token ? token.token : token;

  if (!accessToken) {
    throw new functions.https.HttpsError('internal', 'Failed to obtain Google access token');
  }

  let lastError = null;
  for (const model of models) {
    if (unsupportedVertexModels.has(model)) continue;
    const url = `https://${location}-aiplatform.googleapis.com/v1/projects/${project}/locations/${location}/publishers/google/models/${model}:generateContent`;

    const res = await fetch(url, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Authorization: `Bearer ${accessToken}`,
      },
      body: JSON.stringify({
        systemInstruction: {
          parts: [{ text: systemInstruction }],
        },
        contents: [
          {
            role: 'user',
            parts: [{ text: prompt }],
          },
        ],
        generationConfig: {
          // Strict cost controls + deterministic output.
          temperature: 0.3,
          maxOutputTokens: Math.max(
            128,
            Math.min(2048, Number(maxOutputTokens) || 500)
          ),
          responseMimeType: 'application/json',
        },
      }),
    });

    if (!res.ok) {
      const text = await res.text();
      lastError = { status: res.status, body: text, model };
      console.error('Vertex AI error', res.status, model, text);
      // Retry with the next model for likely model/version issues.
      if (res.status === 400 || res.status === 404) {
        unsupportedVertexModels.add(model);
        continue;
      }
      throw new functions.https.HttpsError(
        'internal',
        `AI_PROVIDER_ERROR:${res.status}:${model}`
      );
    }

    const data = await res.json();
    const content = data?.candidates?.[0]?.content;
    const parts = Array.isArray(content?.parts) ? content.parts : [];
    const textOut = parts.map((p) => p.text).filter(Boolean).join('');

    if (!textOut) {
      console.error('Vertex AI empty response', model, JSON.stringify(data));
      lastError = { status: 200, body: 'EMPTY_TEXT_RESPONSE', model };
      continue;
    }

    return parseStrictJson(textOut, {
      contextForLog: { model, location, project },
    });
  }

  if (lastError) {
    throw new functions.https.HttpsError(
      'internal',
      `AI_PROVIDER_ERROR:${lastError.status}:${lastError.model}`
    );
  }
  throw new functions.https.HttpsError('internal', 'AI_PROVIDER_ERROR:UNKNOWN');
}

exports.aiSuggest = functions.https.onCall(async (data, context) => {
  if (!context.auth) {
    throw new functions.https.HttpsError('unauthenticated', 'Sign in required');
  }

  const uid = context.auth.uid;
  const entitlements = await getEntitlements(uid);
  // Claims are server-assigned and safe to use; Firestore entitlements are also server-controlled.
  const effectiveUser = {
    ...(context.auth.token || {}),
    ...(entitlements || {}),
  };
  if (!canAccessPremiumFeatures(effectiveUser)) {
    throw new functions.https.HttpsError(
      'permission-denied',
      'PREMIUM_REQUIRED'
    );
  }

  const module = String(data?.module ?? '').toLowerCase();
  if (module !== 'accommodations' && module !== 'itinerary') {
    throw new functions.https.HttpsError('invalid-argument', 'Invalid module');
  }

  const destinationName = clampString(data?.destinationName, 200);
  const startDate = clampString(data?.startDate, 32);
  const endDate = clampString(data?.endDate, 32);

  // Structured UI-only controls (no free text). Safe to pass through to prompt.
  const preferences =
    data?.preferences && typeof data.preferences === 'object'
      ? data.preferences
      : null;

  const lat = Number(data?.lat);
  const lon = Number(data?.lon ?? data?.lng);
  const hasCoords = Number.isFinite(lat) && Number.isFinite(lon);

  if (!startDate || !endDate) {
    throw new functions.https.HttpsError('failed-precondition', 'Trip dates required');
  }
  if (!hasCoords) {
    throw new functions.https.HttpsError('failed-precondition', 'Waypoint coordinates required');
  }

  const locationLabel = toCityLikeLabel(destinationName);
  const prompt = buildPrompt({
    module,
    destinationName: locationLabel,
    lat,
    lon,
    startDate,
    endDate,
    preferences,
  });

  if (!prompt) {
    throw new functions.https.HttpsError('invalid-argument', 'Unsupported module');
  }

  const systemInstruction =
    module === 'accommodations'
      ? SYSTEM_INSTRUCTION_ACCOMMODATIONS
      : SYSTEM_INSTRUCTION_ITINERARY;
  const maxOutputTokens = module === 'itinerary' ? 1200 : 400;

  let json;
  try {
    json = await callVertexAiJson({
      prompt,
      systemInstruction,
      maxOutputTokens,
    });
  } catch (e) {
    console.error('[aiSuggest] Provider failed, returning server fallback', {
      message: e?.message || String(e),
      code: e?.code || null,
      module,
      destinationName: locationLabel,
    });
    json = {
      suggestions: buildServerFallbackSuggestions({
        module,
        destinationName: locationLabel,
        preferences,
      }),
    };
  }

  // Minimal validation/sanitization
  const rawArray = Array.isArray(json) ? json : Array.isArray(json?.suggestions) ? json.suggestions : [];
  const normalized = rawArray
    .slice(0, module === 'accommodations' ? 3 : 12)
    .map((s) => {
      if (module === 'accommodations') {
        const priceEstimate = Number(s?.price_estimate ?? s?.priceEstimate ?? s?.price ?? 0);
        const rating = Number(s?.rating ?? 0);
        const stayType = normalizeStayType({ stayType: s?.stayType ?? preferences?.stayType });
        return {
          name: clampString(s?.name, 200),
          address: clampString(s?.address, 300),
          // Keep client contract stable (existing UI expects `price`).
          price: Number.isFinite(priceEstimate) ? priceEstimate : 0,
          rating: Number.isFinite(rating) ? Math.max(0, Math.min(5, rating)) : 0,
          stayType,
        };
      }

      // itinerary
      const estimatedPrice = Number(s?.estimatedPrice ?? s?.price ?? 0);
      const rating = Number(s?.rating ?? 0);
      return {
        name: clampString(s?.name, 200),
        address: clampString(s?.address, 300),
        estimatedPrice: Number.isFinite(estimatedPrice) ? estimatedPrice : 0,
        rating: Number.isFinite(rating) ? Math.max(0, Math.min(5, rating)) : 0,
        category: clampString(s?.category ?? 'Exploring', 32),
      };
    });

  return {
    module,
    suggestions: normalized,
  };
});

// Export for unit tests or local reuse (optional)
exports._canAccessPremiumFeatures = canAccessPremiumFeatures;
