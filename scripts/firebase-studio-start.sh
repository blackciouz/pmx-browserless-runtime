#!/usr/bin/env sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$ROOT"

# shellcheck disable=SC1091
. "./scripts/firebase-studio-utils.sh"

ENV_FILE=".env.firebase-studio"
PMX_FIREBASE_DEFAULT_CONCURRENT="${PMX_FIREBASE_DEFAULT_CONCURRENT:-10}"

if [ ! -f "$ENV_FILE" ]; then
  TOKEN_VALUE="$(node -e "console.log(require('crypto').randomBytes(32).toString('hex'))")"
  cat > "$ENV_FILE" <<EOF
BROWSERLESS_TOKEN=${TOKEN_VALUE}
TOKEN=${TOKEN_VALUE}
PMX_BROWSERLESS_MODE=next-api
PORT=3000
CONCURRENT=${PMX_FIREBASE_DEFAULT_CONCURRENT}
QUEUED=20
TIMEOUT=300000
DEFAULT_TIMEOUT=300000
EOF
fi

if grep -q "^CONCURRENT=1$" "$ENV_FILE"; then
  TMP_ENV="${ENV_FILE}.tmp"
  sed "s/^CONCURRENT=1$/CONCURRENT=${PMX_FIREBASE_DEFAULT_CONCURRENT}/" "$ENV_FILE" > "$TMP_ENV"
  mv "$TMP_ENV" "$ENV_FILE"
fi

set -a
# shellcheck disable=SC1090
. "./$ENV_FILE"
set +a

export TOKEN="${BROWSERLESS_TOKEN:-${TOKEN:-change-me}}"
export BROWSERLESS_TOKEN="$TOKEN"
export PMX_BROWSERLESS_MODE="next-api"
export PORT="${PORT:-3000}"
export CONCURRENT="${CONCURRENT:-${PMX_FIREBASE_DEFAULT_CONCURRENT}}"
export QUEUED="${QUEUED:-20}"
export TIMEOUT="${TIMEOUT:-300000}"
export DEFAULT_TIMEOUT="${DEFAULT_TIMEOUT:-${TIMEOUT}}"
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
