#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILES=(
  "$ROOT_DIR/.env.local"
  "$ROOT_DIR/.env"
  "$ROOT_DIR/tool/.env.local"
  "$ROOT_DIR/tool/.env"
  "$ROOT_DIR/functions/.env"
)

# Default to release so localhost works in browsers like Brave without the
# Dart Debug Chrome extension. Pass --debug to opt into hot reload mode.
RUN_MODE="${FLUTTER_WEB_RUN_MODE:-release}"
EXTRA_ARGS=()
for arg in "$@"; do
  case "$arg" in
    --debug)
      RUN_MODE="debug"
      ;;
    --profile)
      RUN_MODE="profile"
      ;;
    --release)
      RUN_MODE="release"
      ;;
    *)
      EXTRA_ARGS+=("$arg")
      ;;
  esac
done

is_port_in_use() {
  local port="$1"
  if command -v lsof >/dev/null 2>&1; then
    lsof -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1
    return $?
  fi
  # If lsof is unavailable, assume free and let flutter report bind errors.
  return 1
}

escape_sed_replacement() {
  printf '%s' "$1" | sed -e 's/[\\/&#]/\\&/g'
}

extract_maps_key_from_index_html() {
  extract_meta_value_from_index_html "$ROOT_DIR/web/index.html" "google-maps-api-key"
}

extract_map_id_from_index_html() {
  extract_meta_value_from_index_html "$ROOT_DIR/web/index.html" "google-maps-map-id"
}

extract_meta_value_from_index_html() {
  local index_html="$1"
  local meta_name="$2"
  if [[ ! -f "$index_html" ]]; then
    return 0
  fi
  sed -n "s/.*<meta name=\"$meta_name\" content=\"\\([^\"]*\\)\".*/\\1/p" "$index_html" | head -n 1
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

inject_build_web_meta_tags() {
  if [[ -z "$GOOGLE_MAPS_API_KEY_VALUE" && -z "$OPENROUTESERVICE_API_KEY_VALUE" && -z "$GRAPHHOPPER_API_KEY_VALUE" ]]; then
    return 0
  fi

  local index_path="$ROOT_DIR/build/web/index.html"
  local map_html_path="$ROOT_DIR/build/web/map.html"
  local maps_key_escaped
  local map_id_escaped
  local ors_key_escaped
  local graphhopper_key_escaped
  maps_key_escaped="$(escape_sed_replacement "$GOOGLE_MAPS_API_KEY_VALUE")"
  map_id_escaped="$(escape_sed_replacement "$GOOGLE_MAPS_MAP_ID_VALUE")"
  ors_key_escaped="$(escape_sed_replacement "$OPENROUTESERVICE_API_KEY_VALUE")"
  graphhopper_key_escaped="$(escape_sed_replacement "$GRAPHHOPPER_API_KEY_VALUE")"

  if [[ -f "$index_path" ]]; then
    sed -i.bak "s#<meta name=\"google-maps-api-key\" content=\"[^\"]*\"#<meta name=\"google-maps-api-key\" content=\"$maps_key_escaped\"#g" "$index_path" || true
    sed -i.bak "s#<meta name=\"google-maps-map-id\" content=\"[^\"]*\"#<meta name=\"google-maps-map-id\" content=\"$map_id_escaped\"#g" "$index_path" || true
    sed -i.bak "s#<meta name=\"openrouteservice-api-key\" content=\"[^\"]*\"#<meta name=\"openrouteservice-api-key\" content=\"$ors_key_escaped\"#g" "$index_path" || true
    sed -i.bak "s#<meta name=\"graphhopper-api-key\" content=\"[^\"]*\"#<meta name=\"graphhopper-api-key\" content=\"$graphhopper_key_escaped\"#g" "$index_path" || true
    rm -f "$index_path.bak" || true
  fi

  if [[ -f "$map_html_path" ]]; then
    sed -i.bak "s#<meta name=\"google-maps-api-key\" content=\"[^\"]*\"#<meta name=\"google-maps-api-key\" content=\"$maps_key_escaped\"#g" "$map_html_path" || true
    rm -f "$map_html_path.bak" || true
  fi
}

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
WEB_HOSTNAME="${FLUTTER_WEB_HOSTNAME:-127.0.0.1}"
WEB_PORT="${FLUTTER_WEB_PORT:-5500}"
if is_port_in_use "$WEB_PORT"; then
  for candidate in 5510 5520 5530 5540 5550; do
    if ! is_port_in_use "$candidate"; then
      echo "Port $WEB_PORT is in use; using $candidate instead."
      WEB_PORT="$candidate"
      break
    fi
  done
fi

args=("-d" "web-server" "--web-port=$WEB_PORT" "--web-hostname=$WEB_HOSTNAME")

case "$RUN_MODE" in
  debug)
    echo "Run mode: debug (requires Dart Debug Chrome extension on web-server)."
    ;;
  profile)
    args+=("--profile")
    ;;
  release)
    args+=("--release")
    ;;
  *)
    echo "Unknown run mode '$RUN_MODE'; defaulting to release." >&2
    RUN_MODE="release"
    args+=("--release")
    ;;
esac

if [[ -z "$GOOGLE_MAPS_API_KEY_VALUE" ]]; then
  IFS='|' read -r GOOGLE_MAPS_API_KEY_VALUE GOOGLE_MAPS_API_KEY_SOURCE < <(
    extract_from_env_files "GOOGLE_MAPS_API_KEY"
  )
  if [[ -n "$GOOGLE_MAPS_API_KEY_VALUE" ]]; then
    echo "GOOGLE_MAPS_API_KEY not set; using value from $GOOGLE_MAPS_API_KEY_SOURCE (length=${#GOOGLE_MAPS_API_KEY_VALUE})."
  fi
fi

if [[ -z "$GOOGLE_MAPS_API_KEY_VALUE" ]]; then
  GOOGLE_MAPS_API_KEY_VALUE="$(extract_maps_key_from_index_html)"
  if [[ -n "$GOOGLE_MAPS_API_KEY_VALUE" ]]; then
    GOOGLE_MAPS_API_KEY_SOURCE="web/index.html"
    echo "GOOGLE_MAPS_API_KEY not set; using key from web/index.html (length=${#GOOGLE_MAPS_API_KEY_VALUE})."
  fi
fi

if [[ -z "$GOOGLE_MAPS_API_KEY_VALUE" ]]; then
  GOOGLE_MAPS_API_KEY_VALUE="$(extract_meta_value_from_index_html "$ROOT_DIR/build/web/index.html" "google-maps-api-key")"
  if [[ -n "$GOOGLE_MAPS_API_KEY_VALUE" ]]; then
    GOOGLE_MAPS_API_KEY_SOURCE="build/web/index.html"
    echo "GOOGLE_MAPS_API_KEY not set; using key from build/web/index.html (length=${#GOOGLE_MAPS_API_KEY_VALUE})."
  fi
fi

if [[ -z "$GOOGLE_MAPS_MAP_ID_VALUE" ]]; then
  IFS='|' read -r GOOGLE_MAPS_MAP_ID_VALUE GOOGLE_MAPS_MAP_ID_SOURCE < <(
    extract_from_env_files "GOOGLE_MAPS_MAP_ID"
  )
  if [[ -n "$GOOGLE_MAPS_MAP_ID_VALUE" ]]; then
    echo "GOOGLE_MAPS_MAP_ID not set; using value from $GOOGLE_MAPS_MAP_ID_SOURCE (length=${#GOOGLE_MAPS_MAP_ID_VALUE})."
  fi
fi

if [[ -z "$GOOGLE_MAPS_MAP_ID_VALUE" ]]; then
  GOOGLE_MAPS_MAP_ID_VALUE="$(extract_map_id_from_index_html)"
  if [[ -n "$GOOGLE_MAPS_MAP_ID_VALUE" ]]; then
    GOOGLE_MAPS_MAP_ID_SOURCE="web/index.html"
    echo "GOOGLE_MAPS_MAP_ID not set; using map ID from web/index.html (length=${#GOOGLE_MAPS_MAP_ID_VALUE})."
  fi
fi

if [[ -z "$GOOGLE_MAPS_MAP_ID_VALUE" ]]; then
  GOOGLE_MAPS_MAP_ID_VALUE="$(extract_meta_value_from_index_html "$ROOT_DIR/build/web/index.html" "google-maps-map-id")"
  if [[ -n "$GOOGLE_MAPS_MAP_ID_VALUE" ]]; then
    GOOGLE_MAPS_MAP_ID_SOURCE="build/web/index.html"
    echo "GOOGLE_MAPS_MAP_ID not set; using map ID from build/web/index.html (length=${#GOOGLE_MAPS_MAP_ID_VALUE})."
  fi
fi

if [[ -z "$RECAPTCHA_SITE_KEY_VALUE" ]]; then
  IFS='|' read -r RECAPTCHA_SITE_KEY_VALUE RECAPTCHA_SITE_KEY_SOURCE < <(
    extract_from_env_files "RECAPTCHA_SITE_KEY"
  )
  if [[ -n "$RECAPTCHA_SITE_KEY_VALUE" ]]; then
    echo "RECAPTCHA_SITE_KEY not set; using value from $RECAPTCHA_SITE_KEY_SOURCE (length=${#RECAPTCHA_SITE_KEY_VALUE})."
  fi
fi

if [[ -z "$OPENROUTESERVICE_API_KEY_VALUE" ]]; then
  IFS='|' read -r OPENROUTESERVICE_API_KEY_VALUE OPENROUTESERVICE_API_KEY_SOURCE < <(
    extract_from_env_files "OPENROUTESERVICE_API_KEY"
  )
  if [[ -n "$OPENROUTESERVICE_API_KEY_VALUE" ]]; then
    echo "OPENROUTESERVICE_API_KEY not set; using value from $OPENROUTESERVICE_API_KEY_SOURCE (length=${#OPENROUTESERVICE_API_KEY_VALUE})."
  fi
fi

if [[ -z "$OPENROUTESERVICE_API_KEY_VALUE" ]]; then
  OPENROUTESERVICE_API_KEY_VALUE="$(extract_meta_value_from_index_html "$ROOT_DIR/web/index.html" "openrouteservice-api-key")"
  if [[ -n "$OPENROUTESERVICE_API_KEY_VALUE" ]]; then
    OPENROUTESERVICE_API_KEY_SOURCE="web/index.html"
    echo "OPENROUTESERVICE_API_KEY not set; using key from web/index.html (length=${#OPENROUTESERVICE_API_KEY_VALUE})."
  fi
fi

if [[ -z "$OPENROUTESERVICE_API_KEY_VALUE" ]]; then
  OPENROUTESERVICE_API_KEY_VALUE="$(extract_meta_value_from_index_html "$ROOT_DIR/build/web/index.html" "openrouteservice-api-key")"
  if [[ -n "$OPENROUTESERVICE_API_KEY_VALUE" ]]; then
    OPENROUTESERVICE_API_KEY_SOURCE="build/web/index.html"
    echo "OPENROUTESERVICE_API_KEY not set; using key from build/web/index.html (length=${#OPENROUTESERVICE_API_KEY_VALUE})."
  fi
fi

if [[ -z "$GRAPHHOPPER_API_KEY_VALUE" ]]; then
  IFS='|' read -r GRAPHHOPPER_API_KEY_VALUE GRAPHHOPPER_API_KEY_SOURCE < <(
    extract_from_env_files "GRAPHHOPPER_API_KEY"
  )
  if [[ -n "$GRAPHHOPPER_API_KEY_VALUE" ]]; then
    echo "GRAPHHOPPER_API_KEY not set; using value from $GRAPHHOPPER_API_KEY_SOURCE (length=${#GRAPHHOPPER_API_KEY_VALUE})."
  fi
fi

if [[ -z "$GRAPHHOPPER_API_KEY_VALUE" ]]; then
  GRAPHHOPPER_API_KEY_VALUE="$(extract_meta_value_from_index_html "$ROOT_DIR/web/index.html" "graphhopper-api-key")"
  if [[ -n "$GRAPHHOPPER_API_KEY_VALUE" ]]; then
    GRAPHHOPPER_API_KEY_SOURCE="web/index.html"
    echo "GRAPHHOPPER_API_KEY not set; using key from web/index.html (length=${#GRAPHHOPPER_API_KEY_VALUE})."
  fi
fi

if [[ -z "$GRAPHHOPPER_API_KEY_VALUE" ]]; then
  GRAPHHOPPER_API_KEY_VALUE="$(extract_meta_value_from_index_html "$ROOT_DIR/build/web/index.html" "graphhopper-api-key")"
  if [[ -n "$GRAPHHOPPER_API_KEY_VALUE" ]]; then
    GRAPHHOPPER_API_KEY_SOURCE="build/web/index.html"
    echo "GRAPHHOPPER_API_KEY not set; using key from build/web/index.html (length=${#GRAPHHOPPER_API_KEY_VALUE})."
  fi
fi

if [[ -z "$GOOGLE_MAPS_API_KEY_VALUE" ]]; then
  echo "GOOGLE_MAPS_API_KEY not set. Maps will show 'not configured'." >&2
else
  echo "GOOGLE_MAPS_API_KEY found (source=$GOOGLE_MAPS_API_KEY_SOURCE, length=${#GOOGLE_MAPS_API_KEY_VALUE})"
  args+=("--dart-define=GOOGLE_MAPS_API_KEY=$GOOGLE_MAPS_API_KEY_VALUE")

  if [[ -n "$GOOGLE_MAPS_MAP_ID_VALUE" ]]; then
    echo "GOOGLE_MAPS_MAP_ID found (source=$GOOGLE_MAPS_MAP_ID_SOURCE, length=${#GOOGLE_MAPS_MAP_ID_VALUE})"
    args+=("--dart-define=GOOGLE_MAPS_MAP_ID=$GOOGLE_MAPS_MAP_ID_VALUE")
  fi

  if [[ -n "$RECAPTCHA_SITE_KEY_VALUE" ]]; then
    echo "RECAPTCHA_SITE_KEY found (source=$RECAPTCHA_SITE_KEY_SOURCE, length=${#RECAPTCHA_SITE_KEY_VALUE})"
    args+=("--dart-define=RECAPTCHA_SITE_KEY=$RECAPTCHA_SITE_KEY_VALUE")
  fi
fi

if [[ -n "$OPENROUTESERVICE_API_KEY_VALUE" ]]; then
  echo "OPENROUTESERVICE_API_KEY found (source=$OPENROUTESERVICE_API_KEY_SOURCE, length=${#OPENROUTESERVICE_API_KEY_VALUE})"
  args+=("--dart-define=OPENROUTESERVICE_API_KEY=$OPENROUTESERVICE_API_KEY_VALUE")
else
  echo "OPENROUTESERVICE_API_KEY not set; train/walk/bike/hiking will use fallback routing."
fi

if [[ -n "$GRAPHHOPPER_API_KEY_VALUE" ]]; then
  echo "GRAPHHOPPER_API_KEY found (source=$GRAPHHOPPER_API_KEY_SOURCE, length=${#GRAPHHOPPER_API_KEY_VALUE})"
  args+=("--dart-define=GRAPHHOPPER_API_KEY=$GRAPHHOPPER_API_KEY_VALUE")
else
  echo "GRAPHHOPPER_API_KEY not set; hiking GraphHopper fallback will be unavailable."
fi

if [[ -n "$STRICT_ROUTING_VALUE" ]]; then
  echo "STRICT_ROUTING set to '$STRICT_ROUTING_VALUE'"
  args+=("--dart-define=STRICT_ROUTING=$STRICT_ROUTING_VALUE")
fi

if [[ -n "$ROUTING_PROXY_URL_VALUE" ]]; then
  echo "ROUTING_PROXY_URL set to '$ROUTING_PROXY_URL_VALUE'"
  args+=("--dart-define=ROUTING_PROXY_URL=$ROUTING_PROXY_URL_VALUE")
fi

if [[ -n "$CAMPSITE_INFO_MARKER_ID_VALUE" ]]; then
  echo "CAMPSITE_INFO_MARKER_ID set to '$CAMPSITE_INFO_MARKER_ID_VALUE'"
  args+=("--dart-define=CAMPSITE_INFO_MARKER_ID=$CAMPSITE_INFO_MARKER_ID_VALUE")
fi

echo "Starting Flutter Web ($RUN_MODE) on http://$WEB_HOSTNAME:$WEB_PORT"
RUN_EXIT_CODE=0
if ((${#EXTRA_ARGS[@]} > 0)); then
  flutter run "${args[@]}" "${EXTRA_ARGS[@]}" || RUN_EXIT_CODE=$?
else
  flutter run "${args[@]}" || RUN_EXIT_CODE=$?
fi

inject_build_web_meta_tags
exit "$RUN_EXIT_CODE"
