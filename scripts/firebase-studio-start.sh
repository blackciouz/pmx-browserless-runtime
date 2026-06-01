#!/usr/bin/env sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$ROOT"

# shellcheck disable=SC1091
. "./scripts/firebase-studio-utils.sh"

ENV_FILE=".env.firebase-studio"
PMX_FIREBASE_DEFAULT_CONCURRENT="${PMX_FIREBASE_DEFAULT_CONCURRENT:-2}"
PMX_FIREBASE_DEFAULT_MODE="${PMX_FIREBASE_DEFAULT_MODE:-lite}"

pmx_random_token() {
  node -e "console.log(require('crypto').randomBytes(32).toString('hex'))"
}

pmx_start_token_value() {
  if [ -n "${PMX_TOKEN:-}" ]; then
    printf '%s' "$PMX_TOKEN"
  else
    pmx_random_token
  fi
}

pmx_env_has_token() {
  grep -Eq "^(BROWSERLESS_TOKEN|TOKEN)=.+" "$ENV_FILE"
}

pmx_set_env_value() {
  key="$1"
  value="$2"
  TMP_ENV="${ENV_FILE}.tmp"
  if grep -q "^${key}=" "$ENV_FILE"; then
    sed "s#^${key}=.*#${key}=${value}#" "$ENV_FILE" > "$TMP_ENV"
  else
    cp "$ENV_FILE" "$TMP_ENV"
    printf '%s=%s\n' "$key" "$value" >> "$TMP_ENV"
  fi
  mv "$TMP_ENV" "$ENV_FILE"
}

if [ ! -f "$ENV_FILE" ]; then
  TOKEN_VALUE="$(pmx_start_token_value)"
  cat > "$ENV_FILE" <<EOF
BROWSERLESS_TOKEN=${TOKEN_VALUE}
TOKEN=${TOKEN_VALUE}
PMX_BROWSERLESS_MODE=${PMX_FIREBASE_DEFAULT_MODE}
PMX_NEXT_SERVER_MODE=dev
PMX_NEXT_FORCE_BUILD=0
PMX_NEXT_BUILD_FALLBACK_DEV=1
PMX_REUSE_BROWSER=0
PORT=3000
CONCURRENT=${PMX_FIREBASE_DEFAULT_CONCURRENT}
QUEUED=20
TIMEOUT=300000
DEFAULT_TIMEOUT=300000
EOF
else
  if [ "${PMX_FIREBASE_FORCE_TOKEN_UPDATE:-0}" = "1" ] && [ -n "${PMX_TOKEN:-}" ]; then
    pmx_set_env_value "BROWSERLESS_TOKEN" "$PMX_TOKEN"
    pmx_set_env_value "TOKEN" "$PMX_TOKEN"
    echo "TOKEN_UPDATE=forced from PMX_TOKEN"
  elif ! pmx_env_has_token; then
    TOKEN_VALUE="$(pmx_start_token_value)"
    pmx_set_env_value "BROWSERLESS_TOKEN" "$TOKEN_VALUE"
    pmx_set_env_value "TOKEN" "$TOKEN_VALUE"
    echo "TOKEN_UPDATE=initialized missing token"
  elif [ -n "${PMX_TOKEN:-}" ]; then
    echo "TOKEN_UPDATE=preserved existing .env.firebase-studio token; set PMX_FIREBASE_FORCE_TOKEN_UPDATE=1 to replace it"
  fi
fi

if grep -Eq "^PMX_BROWSERLESS_MODE=next-api$" "$ENV_FILE" && [ "${PMX_FIREBASE_KEEP_NEXT_API:-0}" != "1" ]; then
  TMP_ENV="${ENV_FILE}.tmp"
  sed -E "s/^PMX_BROWSERLESS_MODE=next-api$/PMX_BROWSERLESS_MODE=${PMX_FIREBASE_DEFAULT_MODE}/" "$ENV_FILE" > "$TMP_ENV"
  mv "$TMP_ENV" "$ENV_FILE"
fi

if grep -Eq "^CONCURRENT=(1|10)$" "$ENV_FILE"; then
  TMP_ENV="${ENV_FILE}.tmp"
  sed -E "s/^CONCURRENT=(1|10)$/CONCURRENT=${PMX_FIREBASE_DEFAULT_CONCURRENT}/" "$ENV_FILE" > "$TMP_ENV"
  mv "$TMP_ENV" "$ENV_FILE"
fi

if grep -Eq "^PMX_NEXT_SERVER_MODE=start$|^PMX_NEXT_FORCE_BUILD=1$" "$ENV_FILE"; then
  TMP_ENV="${ENV_FILE}.tmp"
  sed -E \
    -e "s/^PMX_NEXT_SERVER_MODE=start$/PMX_NEXT_SERVER_MODE=dev/" \
    -e "s/^PMX_NEXT_FORCE_BUILD=1$/PMX_NEXT_FORCE_BUILD=0/" \
    "$ENV_FILE" > "$TMP_ENV"
  if ! grep -q "^PMX_NEXT_BUILD_FALLBACK_DEV=" "$TMP_ENV"; then
    printf '%s\n' "PMX_NEXT_BUILD_FALLBACK_DEV=1" >> "$TMP_ENV"
  fi
  mv "$TMP_ENV" "$ENV_FILE"
fi

set -a
# shellcheck disable=SC1090
. "./$ENV_FILE"
set +a

export TOKEN="${BROWSERLESS_TOKEN:-${TOKEN:-change-me}}"
export BROWSERLESS_TOKEN="$TOKEN"
export PMX_BROWSERLESS_MODE="${PMX_BROWSERLESS_MODE:-${PMX_FIREBASE_DEFAULT_MODE}}"
export PMX_NEXT_SERVER_MODE="${PMX_NEXT_SERVER_MODE:-dev}"
export PMX_NEXT_FORCE_BUILD="${PMX_NEXT_FORCE_BUILD:-0}"
export PMX_NEXT_BUILD_FALLBACK_DEV="${PMX_NEXT_BUILD_FALLBACK_DEV:-1}"
export PMX_REUSE_BROWSER="${PMX_REUSE_BROWSER:-0}"
export PORT="${PORT:-3000}"
export CONCURRENT="${CONCURRENT:-${PMX_FIREBASE_DEFAULT_CONCURRENT}}"
export QUEUED="${QUEUED:-20}"
export TIMEOUT="${TIMEOUT:-300000}"
export DEFAULT_TIMEOUT="${DEFAULT_TIMEOUT:-${TIMEOUT}}"
export PMX_FIREBASE_HEADFUL_XVFB="${PMX_FIREBASE_HEADFUL_XVFB:-1}"
export PMX_BROWSERLESS_FIREBASE_STUDIO=1

if [ -z "${PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH:-}" ] || [ ! -x "${PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH:-}" ]; then
  for candidate in chromium chromium-browser google-chrome chrome; do
    if command -v "$candidate" >/dev/null 2>&1; then
      export PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH="$(command -v "$candidate")"
      break
    fi
  done
fi

if [ -z "${PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH:-}" ] || [ ! -x "${PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH:-}" ]; then
  WORKSPACE_ROOT="$(CDPATH= cd -- "$ROOT/.." && pwd)"
  if [ -f "$ROOT/.idx/dev.nix" ]; then
    mkdir -p "$WORKSPACE_ROOT/.idx"
    cp "$ROOT/.idx/dev.nix" "$WORKSPACE_ROOT/.idx/dev.nix"
  fi
  echo "FIREBASE_SETUP_INCOMPLETE=1"
  echo "System Chromium is not available in this Firebase Studio shell."
  echo "I installed .idx/dev.nix at: $WORKSPACE_ROOT/.idx/dev.nix"
  echo "Hard rebuild/restart Firebase Studio, then run:"
  echo "cd $(basename "$ROOT") && sh scripts/firebase-studio-start.sh"
  exit 20
fi

echo "PMX Browserless Firebase Studio runtime"
echo "TOKEN=${BROWSERLESS_TOKEN}"
echo "CHROMIUM=${PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH}"
echo "RUNTIME_MODE=${PMX_BROWSERLESS_MODE}"
echo "NEXT_MODE=${PMX_NEXT_SERVER_MODE}"
echo "FIREBASE_XVFB=${PMX_FIREBASE_HEADFUL_XVFB}"
LOCAL_PRESSURE="$(pmx_local_pressure_url)"
echo "LOCAL_PRESSURE=${LOCAL_PRESSURE}"
echo "LOCAL_CAPACITY=http://localhost:${PORT}/capacity?token=${BROWSERLESS_TOKEN}"
echo "LOCAL_FUNCTION=http://localhost:${PORT}/chromium/function?token=${BROWSERLESS_TOKEN}&timeout=30000"
if PUBLIC_PRESSURE="$(pmx_public_pressure_url)"; then
  echo "PUBLIC_PRESSURE=${PUBLIC_PRESSURE}"
  if pmx_copy_to_clipboard "$PUBLIC_PRESSURE"; then
    echo "CLIPBOARD=PUBLIC_PRESSURE copied"
  else
    echo "CLIPBOARD=copy unavailable; copy PUBLIC_PRESSURE manually"
  fi
else
  if pmx_copy_to_clipboard "$LOCAL_PRESSURE"; then
    echo "CLIPBOARD=LOCAL_PRESSURE copied"
  else
    echo "CLIPBOARD=copy unavailable; copy LOCAL_PRESSURE manually"
  fi
fi

exec sh scripts/start-browserless.sh
