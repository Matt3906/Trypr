#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EARTH_DIR="$ROOT_DIR/Earth"
TOURNAMENT_BUILDER_DIR="${TOURNAMENT_BUILDER_DIR:-$(cd "$ROOT_DIR/.." && pwd)/Tournament Builder}"
TOURNAMENT_DEPLOY_DIR="$ROOT_DIR/build/web/tournamentPlanner"
TOURNAMENT_PUBLIC_MIRROR_DIR="$ROOT_DIR/public/tournamentPlanner"
TOURNAMENT_SYNC_PUBLIC_MIRROR="${TOURNAMENT_SYNC_PUBLIC_MIRROR:-0}"
ALLOW_BUILD_ARTIFACT_KEY_FALLBACK="${ALLOW_BUILD_ARTIFACT_KEY_FALLBACK:-0}"
FIREBASE_OPTIONS_FILE="$ROOT_DIR/lib/firebase_options.dart"
ENV_FILES=(
  "$ROOT_DIR/.env.local"
  "$ROOT_DIR/.env"
  "$ROOT_DIR/tool/.env.local"
  "$ROOT_DIR/tool/.env"
  "$ROOT_DIR/functions/.env"
)

escape_sed_replacement() {
  printf '%s' "$1" | sed -e 's/[\\/&#]/\\&/g'
}

extract_meta_value_from_html() {
  local html_file="$1"
  local meta_name="$2"
  if [[ ! -f "$html_file" ]]; then
    return 0
  fi
  sed -n "s/.*<meta name=\"$meta_name\" content=\"\\([^\"]*\\)\".*/\\1/p" "$html_file" | head -n 1
}

extract_env_value_from_file() {
  local key="$1"
  local env_file="$2"
  if [[ ! -f "$env_file" ]]; then
    return 0
  fi
  sed -n -E \
    "s/^[[:space:]]*(export[[:space:]]+)?${key}[[:space:]]*=[[:space:]]*['\"]?([^'\"[:space:]#]+)['\"]?.*/\\2/p" \
    "$env_file" | head -n 1
}

extract_from_env_files() {
  local key="$1"
  local env_file
  local value
  for env_file in "${ENV_FILES[@]}"; do
    value="$(extract_env_value_from_file "$key" "$env_file")"
    if [[ -n "$value" ]]; then
      echo "$value|$env_file"
      return 0
    fi
  done
  echo "|"
}

extract_firebase_option_from_file() {
  local option_name="$1"
  local options_file="$2"
  if [[ ! -f "$options_file" ]]; then
    return 0
  fi
  sed -n -E "s/^[[:space:]]*${option_name}:[[:space:]]*'([^']+)'.*/\\1/p" "$options_file" | head -n 1
}

resolve_tournament_value() {
  local env_key="$1"
  local firebase_option="$2"
  local default_value="${3:-}"
  local value="${!env_key:-}"

  if [[ -n "$value" ]]; then
    echo "$value|environment"
    return 0
  fi

  if [[ -n "$firebase_option" ]]; then
    value="$(extract_firebase_option_from_file "$firebase_option" "$FIREBASE_OPTIONS_FILE")"
    if [[ -n "$value" ]]; then
      echo "$value|$FIREBASE_OPTIONS_FILE:$firebase_option"
      return 0
    fi
  fi

  if [[ -n "$default_value" ]]; then
    echo "$default_value|default"
    return 0
  fi

  echo "|"
}

print_missing_maps_key_error() {
  cat >&2 <<'EOF'
ERROR: GOOGLE_MAPS_API_KEY is not set.

For production web builds, set the key explicitly before running this script:
  export GOOGLE_MAPS_API_KEY="YOUR_PRODUCTION_BROWSER_KEY"
  export GOOGLE_MAPS_MAP_ID="YOUR_MAP_ID"   # optional
  bash tool/flutter_build_web.sh

Build aborted to avoid shipping an unintended fallback API key.
EOF
}

print_missing_tournament_config_error() {
  cat >&2 <<EOF
ERROR: Missing required Firebase config for Tournament Builder web build.

Required values:
  TRYPR_FIREBASE_API_KEY
  TRYPR_FIREBASE_APP_ID
  TRYPR_FIREBASE_MESSAGING_SENDER_ID
  TRYPR_FIREBASE_PROJECT_ID

Provide them as environment variables or keep web values in:
  $FIREBASE_OPTIONS_FILE
EOF
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

  local company_id company_id_source
  local api_key api_key_source
  local app_id app_id_source
  local messaging_sender_id messaging_sender_id_source
  local project_id project_id_source
  local auth_domain auth_domain_source
  local storage_bucket storage_bucket_source
  local measurement_id measurement_id_source

  IFS='|' read -r company_id company_id_source < <(
    resolve_tournament_value "TRYPR_COMPANY_ID" "" "trypr"
  )
  IFS='|' read -r api_key api_key_source < <(
    resolve_tournament_value "TRYPR_FIREBASE_API_KEY" "apiKey"
  )
  IFS='|' read -r app_id app_id_source < <(
    resolve_tournament_value "TRYPR_FIREBASE_APP_ID" "appId"
  )
  IFS='|' read -r messaging_sender_id messaging_sender_id_source < <(
    resolve_tournament_value "TRYPR_FIREBASE_MESSAGING_SENDER_ID" "messagingSenderId"
  )
  IFS='|' read -r project_id project_id_source < <(
    resolve_tournament_value "TRYPR_FIREBASE_PROJECT_ID" "projectId"
  )
  IFS='|' read -r auth_domain auth_domain_source < <(
    resolve_tournament_value "TRYPR_FIREBASE_AUTH_DOMAIN" "authDomain"
  )
  IFS='|' read -r storage_bucket storage_bucket_source < <(
    resolve_tournament_value "TRYPR_FIREBASE_STORAGE_BUCKET" "storageBucket"
  )
  IFS='|' read -r measurement_id measurement_id_source < <(
    resolve_tournament_value "TRYPR_FIREBASE_MEASUREMENT_ID" "measurementId"
  )

  if [[ -z "$api_key" || -z "$app_id" || -z "$messaging_sender_id" || -z "$project_id" ]]; then
    print_missing_tournament_config_error
    return 1
  fi

  echo "Building Tournament Builder web app..."
  echo "  Base href: /tournamentPlanner/"
  echo "  TRYPR_COMPANY_ID source=$company_id_source value=$company_id"
  echo "  TRYPR_FIREBASE_PROJECT_ID source=$project_id_source value=$project_id"
  echo "  TRYPR_FIREBASE_API_KEY source=$api_key_source length=${#api_key}"

  pushd "$TOURNAMENT_BUILDER_DIR" >/dev/null
  flutter pub get
  flutter build web --release \
    --base-href /tournamentPlanner/ \
    --dart-define=TRYPR_COMPANY_ID="$company_id" \
    --dart-define=TRYPR_FIREBASE_API_KEY="$api_key" \
    --dart-define=TRYPR_FIREBASE_APP_ID="$app_id" \
    --dart-define=TRYPR_FIREBASE_MESSAGING_SENDER_ID="$messaging_sender_id" \
    --dart-define=TRYPR_FIREBASE_PROJECT_ID="$project_id" \
    --dart-define=TRYPR_FIREBASE_AUTH_DOMAIN="$auth_domain" \
    --dart-define=TRYPR_FIREBASE_STORAGE_BUCKET="$storage_bucket" \
    --dart-define=TRYPR_FIREBASE_MEASUREMENT_ID="$measurement_id"
  popd >/dev/null

  mkdir -p "$TOURNAMENT_DEPLOY_DIR"
  rsync -a --delete "$TOURNAMENT_BUILDER_DIR/build/web/" "$TOURNAMENT_DEPLOY_DIR/"
  echo "Tournament Builder synced -> build/web/tournamentPlanner"

  if [[ "$TOURNAMENT_SYNC_PUBLIC_MIRROR" == "1" || -d "$ROOT_DIR/public" ]]; then
    mkdir -p "$TOURNAMENT_PUBLIC_MIRROR_DIR"
    rsync -a --delete "$TOURNAMENT_BUILDER_DIR/build/web/" "$TOURNAMENT_PUBLIC_MIRROR_DIR/"
    echo "Tournament Builder mirrored -> public/tournamentPlanner"
  fi
}

# ─── Build Earth (3D Globe) React app first ───
if [[ -f "$EARTH_DIR/package.json" ]]; then
  echo "Building Earth 3D globe app..."
  pushd "$EARTH_DIR" >/dev/null
  if [[ ! -d "node_modules" ]]; then
    echo "  Installing Earth dependencies..."
    npm install
  fi
  npm run build
  popd >/dev/null
  echo "Earth 3D globe built -> web/earth/"
else
  echo "Earth folder not found, skipping globe build."
fi

# ─── Build Flutter web ───
GOOGLE_MAPS_API_KEY_VALUE="${GOOGLE_MAPS_API_KEY:-}"
GOOGLE_MAPS_MAP_ID_VALUE="${GOOGLE_MAPS_MAP_ID:-}"
RECAPTCHA_SITE_KEY_VALUE="${RECAPTCHA_SITE_KEY:-}"
OPENROUTESERVICE_API_KEY_VALUE="${OPENROUTESERVICE_API_KEY:-}"
GRAPHHOPPER_API_KEY_VALUE="${GRAPHHOPPER_API_KEY:-}"
STRICT_ROUTING_VALUE="${STRICT_ROUTING:-}"
ROUTING_PROXY_URL_VALUE="${ROUTING_PROXY_URL:-}"
CAMPSITE_INFO_MARKER_ID_VALUE="${CAMPSITE_INFO_MARKER_ID:-}"
GOOGLE_MAPS_API_KEY_SOURCE="environment"
GOOGLE_MAPS_MAP_ID_SOURCE="environment"
RECAPTCHA_SITE_KEY_SOURCE="environment"
OPENROUTESERVICE_API_KEY_SOURCE="environment"
GRAPHHOPPER_API_KEY_SOURCE="environment"

if [[ -z "$GOOGLE_MAPS_API_KEY_VALUE" ]]; then
  IFS='|' read -r GOOGLE_MAPS_API_KEY_VALUE GOOGLE_MAPS_API_KEY_SOURCE < <(
    extract_from_env_files "GOOGLE_MAPS_API_KEY"
  )
fi

if [[ -z "$GOOGLE_MAPS_MAP_ID_VALUE" ]]; then
  IFS='|' read -r GOOGLE_MAPS_MAP_ID_VALUE GOOGLE_MAPS_MAP_ID_SOURCE < <(
    extract_from_env_files "GOOGLE_MAPS_MAP_ID"
  )
fi

if [[ -z "$RECAPTCHA_SITE_KEY_VALUE" ]]; then
  IFS='|' read -r RECAPTCHA_SITE_KEY_VALUE RECAPTCHA_SITE_KEY_SOURCE < <(
    extract_from_env_files "RECAPTCHA_SITE_KEY"
  )
fi

if [[ -z "$OPENROUTESERVICE_API_KEY_VALUE" ]]; then
  IFS='|' read -r OPENROUTESERVICE_API_KEY_VALUE OPENROUTESERVICE_API_KEY_SOURCE < <(
    extract_from_env_files "OPENROUTESERVICE_API_KEY"
  )
fi

if [[ -z "$GRAPHHOPPER_API_KEY_VALUE" ]]; then
  IFS='|' read -r GRAPHHOPPER_API_KEY_VALUE GRAPHHOPPER_API_KEY_SOURCE < <(
    extract_from_env_files "GRAPHHOPPER_API_KEY"
  )
fi

if [[ -z "$GOOGLE_MAPS_API_KEY_VALUE" ]]; then
  GOOGLE_MAPS_API_KEY_VALUE="$(
    extract_meta_value_from_html "$ROOT_DIR/web/index.html" "google-maps-api-key"
  )"
  if [[ -n "$GOOGLE_MAPS_API_KEY_VALUE" ]]; then
    GOOGLE_MAPS_API_KEY_SOURCE="web/index.html"
  fi
fi

if [[ -z "$GOOGLE_MAPS_MAP_ID_VALUE" ]]; then
  GOOGLE_MAPS_MAP_ID_VALUE="$(
    extract_meta_value_from_html "$ROOT_DIR/web/index.html" "google-maps-map-id"
  )"
  if [[ -n "$GOOGLE_MAPS_MAP_ID_VALUE" ]]; then
    GOOGLE_MAPS_MAP_ID_SOURCE="web/index.html"
  fi
fi

if [[ -z "$OPENROUTESERVICE_API_KEY_VALUE" ]]; then
  OPENROUTESERVICE_API_KEY_VALUE="$(
    extract_meta_value_from_html "$ROOT_DIR/web/index.html" "openrouteservice-api-key"
  )"
  if [[ -n "$OPENROUTESERVICE_API_KEY_VALUE" ]]; then
    OPENROUTESERVICE_API_KEY_SOURCE="web/index.html"
  fi
fi

if [[ -z "$GRAPHHOPPER_API_KEY_VALUE" ]]; then
  GRAPHHOPPER_API_KEY_VALUE="$(
    extract_meta_value_from_html "$ROOT_DIR/web/index.html" "graphhopper-api-key"
  )"
  if [[ -n "$GRAPHHOPPER_API_KEY_VALUE" ]]; then
    GRAPHHOPPER_API_KEY_SOURCE="web/index.html"
  fi
fi

if [[ -z "$GOOGLE_MAPS_API_KEY_VALUE" ]]; then
  PREVIOUS_BUILD_MAPS_KEY="$(
    extract_meta_value_from_html "$ROOT_DIR/build/web/index.html" "google-maps-api-key"
  )"
  if [[ -n "${PREVIOUS_BUILD_MAPS_KEY:-}" ]]; then
    if [[ "$ALLOW_BUILD_ARTIFACT_KEY_FALLBACK" == "1" ]]; then
      GOOGLE_MAPS_API_KEY_VALUE="$PREVIOUS_BUILD_MAPS_KEY"
      GOOGLE_MAPS_API_KEY_SOURCE="build/web/index.html"
      echo "WARNING: Reusing GOOGLE_MAPS_API_KEY from previous build output (ALLOW_BUILD_ARTIFACT_KEY_FALLBACK=1)." >&2
    else
      cat >&2 <<EOF
ERROR: GOOGLE_MAPS_API_KEY is missing from explicit sources.

Found a previous key in build/web/index.html, but fallback reuse is disabled to avoid deploying stale credentials.
Set one of the following and rebuild:
  1) export GOOGLE_MAPS_API_KEY="YOUR_BROWSER_KEY"
  2) set <meta name="google-maps-api-key" ...> in web/index.html

If you intentionally want to reuse the prior build artifact key, run with:
  ALLOW_BUILD_ARTIFACT_KEY_FALLBACK=1 bash tool/flutter_build_web.sh
EOF
      exit 1
    fi
  fi
fi

if [[ -z "$GOOGLE_MAPS_MAP_ID_VALUE" ]]; then
  PREVIOUS_BUILD_MAP_ID="$(
    extract_meta_value_from_html "$ROOT_DIR/build/web/index.html" "google-maps-map-id"
  )"
  if [[ -n "${PREVIOUS_BUILD_MAP_ID:-}" ]]; then
    if [[ "$ALLOW_BUILD_ARTIFACT_KEY_FALLBACK" == "1" ]]; then
      GOOGLE_MAPS_MAP_ID_VALUE="$PREVIOUS_BUILD_MAP_ID"
      GOOGLE_MAPS_MAP_ID_SOURCE="build/web/index.html"
      echo "WARNING: Reusing GOOGLE_MAPS_MAP_ID from previous build output (ALLOW_BUILD_ARTIFACT_KEY_FALLBACK=1)." >&2
    else
      echo "GOOGLE_MAPS_MAP_ID found in build/web/index.html, but fallback reuse is disabled. Set GOOGLE_MAPS_MAP_ID explicitly to use it." >&2
    fi
  fi
fi

if [[ -z "$GOOGLE_MAPS_API_KEY_VALUE" ]]; then
  print_missing_maps_key_error
  exit 1
fi

echo "GOOGLE_MAPS_API_KEY found (source=$GOOGLE_MAPS_API_KEY_SOURCE, length=${#GOOGLE_MAPS_API_KEY_VALUE})"

if [[ ! "$GOOGLE_MAPS_API_KEY_VALUE" =~ ^AIza[A-Za-z0-9_-]{20,}$ ]]; then
  echo "WARNING: GOOGLE_MAPS_API_KEY format looks unusual. Check that you set the intended browser key." >&2
fi

if [[ -n "$GOOGLE_MAPS_MAP_ID_VALUE" ]]; then
  echo "GOOGLE_MAPS_MAP_ID found (source=$GOOGLE_MAPS_MAP_ID_SOURCE, length=${#GOOGLE_MAPS_MAP_ID_VALUE})"
else
  echo "GOOGLE_MAPS_MAP_ID not set; proceeding without vector map ID."
fi

if [[ -n "$RECAPTCHA_SITE_KEY_VALUE" ]]; then
  echo "RECAPTCHA_SITE_KEY found (source=$RECAPTCHA_SITE_KEY_SOURCE, length=${#RECAPTCHA_SITE_KEY_VALUE})"
else
  echo "RECAPTCHA_SITE_KEY not set; App Check activation will be skipped on web."
fi

if [[ -n "$OPENROUTESERVICE_API_KEY_VALUE" ]]; then
  echo "OPENROUTESERVICE_API_KEY found (source=$OPENROUTESERVICE_API_KEY_SOURCE, length=${#OPENROUTESERVICE_API_KEY_VALUE})"
else
  echo "OPENROUTESERVICE_API_KEY not set; train/walk/bike/hiking will use fallback routing."
fi

if [[ -n "$GRAPHHOPPER_API_KEY_VALUE" ]]; then
  echo "GRAPHHOPPER_API_KEY found (source=$GRAPHHOPPER_API_KEY_SOURCE, length=${#GRAPHHOPPER_API_KEY_VALUE})"
else
  echo "GRAPHHOPPER_API_KEY not set; hiking GraphHopper fallback will be unavailable."
fi

EXTRA_DART_DEFINES=()
if [[ -n "$STRICT_ROUTING_VALUE" ]]; then
  echo "STRICT_ROUTING set to '$STRICT_ROUTING_VALUE'"
  EXTRA_DART_DEFINES+=("--dart-define=STRICT_ROUTING=$STRICT_ROUTING_VALUE")
fi
if [[ -n "$ROUTING_PROXY_URL_VALUE" ]]; then
  echo "ROUTING_PROXY_URL set to '$ROUTING_PROXY_URL_VALUE'"
  EXTRA_DART_DEFINES+=("--dart-define=ROUTING_PROXY_URL=$ROUTING_PROXY_URL_VALUE")
fi
if [[ -n "$CAMPSITE_INFO_MARKER_ID_VALUE" ]]; then
  echo "CAMPSITE_INFO_MARKER_ID set to '$CAMPSITE_INFO_MARKER_ID_VALUE'"
  EXTRA_DART_DEFINES+=("--dart-define=CAMPSITE_INFO_MARKER_ID=$CAMPSITE_INFO_MARKER_ID_VALUE")
fi

flutter build web \
  --dart-define=GOOGLE_MAPS_API_KEY="$GOOGLE_MAPS_API_KEY_VALUE" \
  --dart-define=GOOGLE_MAPS_MAP_ID="$GOOGLE_MAPS_MAP_ID_VALUE" \
  --dart-define=RECAPTCHA_SITE_KEY="$RECAPTCHA_SITE_KEY_VALUE" \
  --dart-define=OPENROUTESERVICE_API_KEY="$OPENROUTESERVICE_API_KEY_VALUE" \
  --dart-define=GRAPHHOPPER_API_KEY="$GRAPHHOPPER_API_KEY_VALUE" \
  ${EXTRA_DART_DEFINES[@]+"${EXTRA_DART_DEFINES[@]}"}

# Inject web keys into built index.html (build/web is in .gitignore, so this is safe)
INDEX_PATH="$ROOT_DIR/build/web/index.html"
if [[ -f "$INDEX_PATH" ]]; then
  echo "Injecting web key meta tags into build/web/index.html..."
  MAPS_KEY_ESCAPED="$(escape_sed_replacement "$GOOGLE_MAPS_API_KEY_VALUE")"
  MAP_ID_ESCAPED="$(escape_sed_replacement "$GOOGLE_MAPS_MAP_ID_VALUE")"
  ORS_KEY_ESCAPED="$(escape_sed_replacement "$OPENROUTESERVICE_API_KEY_VALUE")"
  GRAPHHOPPER_KEY_ESCAPED="$(escape_sed_replacement "$GRAPHHOPPER_API_KEY_VALUE")"
  # macOS sed requires a backup suffix for -i
  sed -i.bak "s#<meta name=\"google-maps-api-key\" content=\"[^\"]*\"#<meta name=\"google-maps-api-key\" content=\"$MAPS_KEY_ESCAPED\"#g" "$INDEX_PATH" || true
  sed -i.bak "s#<meta name=\"google-maps-map-id\" content=\"[^\"]*\"#<meta name=\"google-maps-map-id\" content=\"$MAP_ID_ESCAPED\"#g" "$INDEX_PATH" || true
  sed -i.bak "s#<meta name=\"openrouteservice-api-key\" content=\"[^\"]*\"#<meta name=\"openrouteservice-api-key\" content=\"$ORS_KEY_ESCAPED\"#g" "$INDEX_PATH" || true
  sed -i.bak "s#<meta name=\"graphhopper-api-key\" content=\"[^\"]*\"#<meta name=\"graphhopper-api-key\" content=\"$GRAPHHOPPER_KEY_ESCAPED\"#g" "$INDEX_PATH" || true
  rm -f "$INDEX_PATH.bak" || true
  echo "Web key meta tags injected."
fi

# Inject the Google Maps key into the dedicated 3D iframe page as a fallback
# when no query-string key is provided.
MAP_HTML_PATH="$ROOT_DIR/build/web/map.html"
if [[ -f "$MAP_HTML_PATH" ]]; then
  echo "Injecting Google Maps key meta tag into build/web/map.html..."
  MAPS_KEY_ESCAPED="${MAPS_KEY_ESCAPED:-$(escape_sed_replacement "$GOOGLE_MAPS_API_KEY_VALUE")}"
  sed -i.bak "s#<meta name=\"google-maps-api-key\" content=\"[^\"]*\"#<meta name=\"google-maps-api-key\" content=\"$MAPS_KEY_ESCAPED\"#g" "$MAP_HTML_PATH" || true
  rm -f "$MAP_HTML_PATH.bak" || true
  echo "map.html key meta tag injected."
fi

# Copy .htaccess into build output (flutter build web doesn't copy dotfiles)
HTACCESS_SRC="$ROOT_DIR/web/.htaccess"
HTACCESS_DST="$ROOT_DIR/build/web/.htaccess"
if [[ -f "$HTACCESS_SRC" ]]; then
  cp "$HTACCESS_SRC" "$HTACCESS_DST"
  echo ".htaccess copied to build/web/"
fi

build_tournament_planner_web

echo "Web build complete:"
echo "  build/web"
echo "  GOOGLE_MAPS_API_KEY length=${#GOOGLE_MAPS_API_KEY_VALUE}"
echo "  GOOGLE_MAPS_MAP_ID length=${#GOOGLE_MAPS_MAP_ID_VALUE}"
echo "  RECAPTCHA_SITE_KEY length=${#RECAPTCHA_SITE_KEY_VALUE}"
echo "  OPENROUTESERVICE_API_KEY length=${#OPENROUTESERVICE_API_KEY_VALUE}"
echo "  GRAPHHOPPER_API_KEY length=${#GRAPHHOPPER_API_KEY_VALUE}"
echo "  STRICT_ROUTING=$STRICT_ROUTING_VALUE"
echo "  ROUTING_PROXY_URL=$ROUTING_PROXY_URL_VALUE"
echo "  CAMPSITE_INFO_MARKER_ID=$CAMPSITE_INFO_MARKER_ID_VALUE"
echo "  TOURNAMENT_PLANNER_DIR=$TOURNAMENT_DEPLOY_DIR"
