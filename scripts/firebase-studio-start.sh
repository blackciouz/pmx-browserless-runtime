#!/usr/bin/env sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$ROOT"

# shellcheck disable=SC1091
. "./scripts/firebase-studio-utils.sh"

ENV_FILE=".env.firebase-studio"

if [ ! -f "$ENV_FILE" ]; then
  TOKEN_VALUE="$(node -e "console.log(require('crypto').randomBytes(32).toString('hex'))")"
  cat > "$ENV_FILE" <<EOF
BROWSERLESS_TOKEN=${TOKEN_VALUE}
TOKEN=${TOKEN_VALUE}
PMX_BROWSERLESS_MODE=next-api
PORT=3000
CONCURRENT=1
QUEUED=20
TIMEOUT=300000
DEFAULT_TIMEOUT=300000
EOF
fi

set -a
# shellcheck disable=SC1090
. "./$ENV_FILE"
set +a

export TOKEN="${BROWSERLESS_TOKEN:-${TOKEN:-change-me}}"
export BROWSERLESS_TOKEN="$TOKEN"
export PMX_BROWSERLESS_MODE="next-api"
export PORT="${PORT:-3000}"
export CONCURRENT="${CONCURRENT:-1}"
export QUEUED="${QUEUED:-20}"
export TIMEOUT="${TIMEOUT:-300000}"
export DEFAULT_TIMEOUT="${DEFAULT_TIMEOUT:-${TIMEOUT}}"

echo "PMX Browserless Firebase Studio runtime"
echo "TOKEN=${BROWSERLESS_TOKEN}"
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
