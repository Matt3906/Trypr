/* eslint-disable no-console */

const fs = require('fs');
const path = require('path');

const functions = require('firebase-functions');
const admin = require('firebase-admin');
const { GoogleAuth } = require('google-auth-library');

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
  // This avoids trusting /users/{uid} (which is currently client-writable in rules).
  const [entSnap, adminSnap] = await Promise.all([
    admin.firestore().doc(`userEntitlements/${uid}`).get(),
    admin.firestore().doc(`admins/${uid}`).get(),
  ]);

  const ent = entSnap.exists ? entSnap.data() : {};
  const isAdmin = adminSnap.exists;

  return {
    ...ent,
    role: isAdmin ? ['admin', ...normalizeRoles(ent?.role ?? ent?.roles)] : normalizeRoles(ent?.role ?? ent?.roles),
  };
}

function getVertexProject() {
  return process.env.VERTEX_PROJECT || functions.config?.()?.vertex?.project;
}

function getVertexLocation() {
  return process.env.VERTEX_LOCATION || functions.config?.()?.vertex?.location || 'us-central1';
}

function getVertexModel() {
  // Examples: gemini-1.5-flash, gemini-1.5-pro
  return process.env.VERTEX_MODEL || functions.config?.()?.vertex?.model || 'gemini-1.5-flash';
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
    return base + prefs;
  }

  if (module === 'itinerary') {
    return base + prefs;
  }

  return null;
}

const SYSTEM_INSTRUCTION_ACCOMMODATIONS =
  'You are a travel assistant API. Your ONLY job is to return a JSON array of 3 accommodation options based on the provided location and dates. Return ONLY valid JSON with keys: name, address, price_estimate (number only), rating (number 1-5). Do not include markdown formatting or conversational text.';

const SYSTEM_INSTRUCTION_ITINERARY =
  'You are a travel assistant API. Return ONLY valid JSON. Your ONLY job is to return a JSON array of 8 activity options based on the provided location and dates. Keys: name, address, estimatedPrice (number only), rating (number 1-5), category. No markdown or conversational text.';

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

async function callVertexAiJson({ prompt, systemInstruction }) {
  const project = getVertexProject();
  const location = getVertexLocation();
  const model = getVertexModel();

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
        maxOutputTokens: 500,
        responseMimeType: 'application/json',
      },
    }),
  });

  if (!res.ok) {
    const text = await res.text();
    console.error('Vertex AI error', res.status, text);
    throw new functions.https.HttpsError('internal', `AI_PROVIDER_ERROR:${res.status}`);
  }

  const data = await res.json();
  const content = data?.candidates?.[0]?.content;
  const parts = Array.isArray(content?.parts) ? content.parts : [];
  const textOut = parts.map((p) => p.text).filter(Boolean).join('');

  if (!textOut) {
    console.error('Vertex AI empty response', JSON.stringify(data));
    throw new functions.https.HttpsError('internal', 'Empty AI response');
  }

  return parseStrictJson(textOut, {
    contextForLog: { model, location },
  });
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

  const prompt = buildPrompt({
    module,
    destinationName,
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

  const json = await callVertexAiJson({ prompt, systemInstruction });

  // Minimal validation/sanitization
  const rawArray = Array.isArray(json) ? json : Array.isArray(json?.suggestions) ? json.suggestions : [];
  const normalized = rawArray
    .slice(0, module === 'accommodations' ? 3 : 12)
    .map((s) => {
      if (module === 'accommodations') {
        const priceEstimate = Number(s?.price_estimate ?? s?.priceEstimate ?? s?.price ?? 0);
        const rating = Number(s?.rating ?? 0);
        return {
          name: clampString(s?.name, 200),
          address: clampString(s?.address, 300),
          // Keep client contract stable (existing UI expects `price`).
          price: Number.isFinite(priceEstimate) ? priceEstimate : 0,
          rating: Number.isFinite(rating) ? Math.max(0, Math.min(5, rating)) : 0,
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
