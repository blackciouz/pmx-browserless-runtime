#!/usr/bin/env sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$ROOT"

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
echo "LOCAL_PRESSURE=http://localhost:${PORT}/pressure?token=${BROWSERLESS_TOKEN}"
echo "LOCAL_CAPACITY=http://localhost:${PORT}/capacity?token=${BROWSERLESS_TOKEN}"
echo "LOCAL_FUNCTION=http://localhost:${PORT}/chromium/function?token=${BROWSERLESS_TOKEN}&timeout=30000"
if [ -n "${WEB_HOST:-}" ]; then
  echo "PUBLIC_PRESSURE=https://${PORT}-${WEB_HOST}/pressure?token=${BROWSERLESS_TOKEN}"
fi

exec sh scripts/start-browserless.sh
