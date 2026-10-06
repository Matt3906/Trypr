#!/usr/bin/env bash
# Builds the Trypr web app (Vite + React in frontend/) into frontend/dist and, when present,
# the Tournament Builder sub-app into frontend/dist/tournamentPlanner.
#
# Browser keys are read from (first match wins): the environment, frontend/.env.local, frontend/.env,
# .env.local, .env, tool/.env.local, tool/.env, functions/.env. The legacy un-prefixed names
# (GOOGLE_MAPS_API_KEY, ...) are still accepted and mapped to the VITE_* names the app reads.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FRONTEND_DIR="$ROOT_DIR/frontend"
DIST_DIR="$FRONTEND_DIR/dist"
EARTH_DIR="$ROOT_DIR/Earth"
TOURNAMENT_BUILDER_DIR="${TOURNAMENT_BUILDER_DIR:-$(cd "$ROOT_DIR/.." && pwd)/Tournament Builder}"
TOURNAMENT_DEPLOY_DIR="$DIST_DIR/tournamentPlanner"
# The Firebase web config lives in the React app's config module (same `key: 'value'` shape as the
# old firebase_options.dart, so the same extractor works).
FIREBASE_OPTIONS_FILE="$FRONTEND_DIR/src/config.ts"
ENV_FILES=(
  "$FRONTEND_DIR/.env.local"
  "$FRONTEND_DIR/.env"
  "$ROOT_DIR/.env.local"
  "$ROOT_DIR/.env"
  "$ROOT_DIR/tool/.env.local"
  "$ROOT_DIR/tool/.env"
  "$ROOT_DIR/functions/.env"
)

extract_env_value_from_file() {
  local key="$1" env_file="$2"
  [[ -f "$env_file" ]] || return 0
  sed -n -E "s/^[[:space:]]*(export[[:space:]]+)?${key}[[:space:]]*=[[:space:]]*['\"]?([^'\"[:space:]#]+)['\"]?.*/\\2/p" "$env_file" | head -n 1
}

# Echoes "value|source" for the first env file that defines $1.
extract_from_env_files() {
  local key="$1" env_file value
  for env_file in "${ENV_FILES[@]}"; do
    value="$(extract_env_value_from_file "$key" "$env_file")"
    if [[ -n "$value" ]]; then
      echo "$value|$env_file"
      return 0
    fi
  done
  echo "|"
}

# resolve_var VITE_NAME [LEGACY_NAME] -> sets and exports VITE_NAME; prints where it came from.
resolve_var() {
  local vite_name="$1" legacy_name="${2:-}" value="" source=""
  value="${!vite_name:-}"; [[ -n "$value" ]] && source="environment"
  if [[ -z "$value" && -n "$legacy_name" ]]; then value="${!legacy_name:-}"; [[ -n "$value" ]] && source="environment ($legacy_name)"; fi
  if [[ -z "$value" ]]; then IFS='|' read -r value source < <(extract_from_env_files "$vite_name"); fi
  if [[ -z "$value" && -n "$legacy_name" ]]; then IFS='|' read -r value source < <(extract_from_env_files "$legacy_name"); fi
  if [[ -n "$value" ]]; then
    export "$vite_name=$value"
    echo "  $vite_name: set (source=$source, length=${#value})"
  else
    echo "  $vite_name: not set"
  fi
}

extract_firebase_option_from_file() {
  local option_name="$1" options_file="$2"
  [[ -f "$options_file" ]] || return 0
  sed -n -E "s/^[[:space:]]*${option_name}:[[:space:]]*'([^']+)'.*/\\1/p" "$options_file" | head -n 1
}

resolve_tournament_value() {
  local env_key="$1" firebase_option="$2" default_value="${3:-}" value="${!env_key:-}"
  if [[ -n "$value" ]]; then echo "$value|environment"; return 0; fi
  if [[ -n "$firebase_option" ]]; then
    value="$(extract_firebase_option_from_file "$firebase_option" "$FIREBASE_OPTIONS_FILE")"
    if [[ -n "$value" ]]; then echo "$value|$FIREBASE_OPTIONS_FILE:$firebase_option"; return 0; fi
  fi
  if [[ -n "$default_value" ]]; then echo "$default_value|default"; return 0; fi
  echo "|"
}

build_tournament_planner_web() {
  if [[ "${SKIP_TOURNAMENT_PLANNER_BUILD:-0}" == "1" ]]; then
    echo "Tournament Builder build skipped (SKIP_TOURNAMENT_PLANNER_BUILD=1)."
    return 0
  fi
  if [[ ! -d "$TOURNAMENT_BUILDER_DIR" ]]; then
    echo "Tournament Builder folder not found at '$TOURNAMENT_BUILDER_DIR'; skipping subpath build."
    return 0
  fi

  local company_id api_key app_id sender_id project_id auth_domain storage_bucket measurement_id src
  IFS='|' read -r company_id src < <(resolve_tournament_value "TRYPR_COMPANY_ID" "" "trypr")
  IFS='|' read -r api_key src < <(resolve_tournament_value "TRYPR_FIREBASE_API_KEY" "apiKey")
  IFS='|' read -r app_id src < <(resolve_tournament_value "TRYPR_FIREBASE_APP_ID" "appId")
  IFS='|' read -r sender_id src < <(resolve_tournament_value "TRYPR_FIREBASE_MESSAGING_SENDER_ID" "messagingSenderId")
  IFS='|' read -r project_id src < <(resolve_tournament_value "TRYPR_FIREBASE_PROJECT_ID" "projectId")
  IFS='|' read -r auth_domain src < <(resolve_tournament_value "TRYPR_FIREBASE_AUTH_DOMAIN" "authDomain")
  IFS='|' read -r storage_bucket src < <(resolve_tournament_value "TRYPR_FIREBASE_STORAGE_BUCKET" "storageBucket")
  IFS='|' read -r measurement_id src < <(resolve_tournament_value "TRYPR_FIREBASE_MEASUREMENT_ID" "measurementId")

  if [[ -z "$api_key" || -z "$app_id" || -z "$sender_id" || -z "$project_id" ]]; then
    echo "ERROR: missing Firebase config for the Tournament Builder build (set TRYPR_FIREBASE_* or fix $FIREBASE_OPTIONS_FILE)." >&2
    return 1
  fi

  echo "Building Tournament Builder web app (base href /tournamentPlanner/)..."
  pushd "$TOURNAMENT_BUILDER_DIR" >/dev/null
  flutter pub get
  flutter build web --release \
    --base-href /tournamentPlanner/ \
    --dart-define=TRYPR_COMPANY_ID="$company_id" \
    --dart-define=TRYPR_FIREBASE_API_KEY="$api_key" \
    --dart-define=TRYPR_FIREBASE_APP_ID="$app_id" \
    --dart-define=TRYPR_FIREBASE_MESSAGING_SENDER_ID="$sender_id" \
    --dart-define=TRYPR_FIREBASE_PROJECT_ID="$project_id" \
    --dart-define=TRYPR_FIREBASE_AUTH_DOMAIN="$auth_domain" \
    --dart-define=TRYPR_FIREBASE_STORAGE_BUCKET="$storage_bucket" \
    --dart-define=TRYPR_FIREBASE_MEASUREMENT_ID="$measurement_id"
  popd >/dev/null

  mkdir -p "$TOURNAMENT_DEPLOY_DIR"
  rsync -a --delete "$TOURNAMENT_BUILDER_DIR/build/web/" "$TOURNAMENT_DEPLOY_DIR/"
  echo "Tournament Builder synced -> frontend/dist/tournamentPlanner"
}

# ─── Earth (3D globe) React app, if its source folder is present ───
if [[ -f "$EARTH_DIR/package.json" ]]; then
  echo "Building Earth 3D globe app..."
  pushd "$EARTH_DIR" >/dev/null
  [[ -d node_modules ]] || npm install
  npm run build
  popd >/dev/null
  # Earth builds into web/earth/ (legacy location); the React app serves it from public/earth/.
  if [[ -d "$ROOT_DIR/web/earth" ]]; then
    mkdir -p "$FRONTEND_DIR/public/earth"
    rsync -a --delete "$ROOT_DIR/web/earth/" "$FRONTEND_DIR/public/earth/"
    echo "Earth globe synced -> frontend/public/earth"
  fi
else
  echo "Earth folder not found, skipping globe build."
fi

# ─── Resolve browser keys ───
echo "Resolving build-time keys..."
resolve_var VITE_GOOGLE_MAPS_API_KEY GOOGLE_MAPS_API_KEY
resolve_var VITE_GOOGLE_MAPS_MAP_ID GOOGLE_MAPS_MAP_ID
resolve_var VITE_RECAPTCHA_SITE_KEY RECAPTCHA_SITE_KEY
resolve_var VITE_OPENROUTESERVICE_API_KEY OPENROUTESERVICE_API_KEY
resolve_var VITE_GRAPHHOPPER_API_KEY GRAPHHOPPER_API_KEY
resolve_var VITE_STRICT_ROUTING STRICT_ROUTING
resolve_var VITE_ROUTING_PROXY_URL ROUTING_PROXY_URL
resolve_var VITE_OVERPASS_PROXY_URL OVERPASS_PROXY_URL
resolve_var VITE_CAMPSITE_INFO_MARKER_ID CAMPSITE_INFO_MARKER_ID

if [[ -z "${VITE_GOOGLE_MAPS_API_KEY:-}" ]]; then
  cat >&2 <<'EOF'
ERROR: VITE_GOOGLE_MAPS_API_KEY is not set.

Set it in frontend/.env.local (see frontend/.env.example) or export it before building:
  export VITE_GOOGLE_MAPS_API_KEY="YOUR_PRODUCTION_BROWSER_KEY"
  bash tool/build_web.sh

Build aborted to avoid shipping a build without maps.
EOF
  exit 1
fi
if [[ ! "$VITE_GOOGLE_MAPS_API_KEY" =~ ^AIza[A-Za-z0-9_-]{20,}$ ]]; then
  echo "WARNING: the Google Maps key format looks unusual. Check that you set the intended browser key." >&2
fi

# ─── Build the React app ───
echo "Building React app..."
pushd "$FRONTEND_DIR" >/dev/null
[[ -d node_modules ]] || npm ci
npm run build
popd >/dev/null

# The map iframe page reads its key from a meta tag; keep it in sync with the build key.
if [[ -f "$DIST_DIR/map.html" ]]; then
  key_escaped="$(printf '%s' "$VITE_GOOGLE_MAPS_API_KEY" | sed -e 's/[\\/&#]/\\&/g')"
  sed -i.bak "s#<meta name=\"google-maps-api-key\" content=\"[^\"]*\"#<meta name=\"google-maps-api-key\" content=\"$key_escaped\"#g" "$DIST_DIR/map.html" || true
  rm -f "$DIST_DIR/map.html.bak" || true
  echo "map.html key meta tag injected."
fi

build_tournament_planner_web

echo "Web build complete: frontend/dist"
