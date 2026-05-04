#!/usr/bin/env sh
set -eu

export PORT="${PORT:-3000}"
export TOKEN="${BROWSERLESS_TOKEN:-${TOKEN:-change-me}}"
export BROWSERLESS_TOKEN="${TOKEN}"
export CONCURRENT="${CONCURRENT:-1}"
export QUEUED="${QUEUED:-20}"
export TIMEOUT="${TIMEOUT:-300000}"
export DEFAULT_TIMEOUT="${DEFAULT_TIMEOUT:-${TIMEOUT}}"
export MAX_MEMORY_PERCENT="${MAX_MEMORY_PERCENT:-95}"
export MAX_CPU_PERCENT="${MAX_CPU_PERCENT:-95}"
export PMX_BROWSERLESS_MODE="${PMX_BROWSERLESS_MODE:-auto}"

echo "Starting PMX Browserless runtime on port ${PORT} with CONCURRENT=${CONCURRENT}, QUEUED=${QUEUED}, mode=${PMX_BROWSERLESS_MODE}"

if [ "${PMX_BROWSERLESS_MODE}" != "lite" ] && command -v docker >/dev/null 2>&1; then
  docker rm -f pmx-browserless >/dev/null 2>&1 || true
  exec docker run --rm --name pmx-browserless \
    -p "${PORT}:3000" \
    -e TOKEN="${TOKEN}" \
    -e CONCURRENT="${CONCURRENT}" \
    -e QUEUED="${QUEUED}" \
    -e TIMEOUT="${TIMEOUT}" \
    -e MAX_MEMORY_PERCENT="${MAX_MEMORY_PERCENT}" \
    -e MAX_CPU_PERCENT="${MAX_CPU_PERCENT}" \
    ghcr.io/browserless/chromium:latest
fi

if ! command -v node >/dev/null 2>&1; then
  echo "Docker is unavailable and Node.js is not installed. Cannot start Browserless lite fallback."
  exit 1
fi

if [ ! -d node_modules/playwright ]; then
  echo "Installing Playwright fallback dependencies..."
  npm install --omit=dev --no-audit --no-fund
fi

if [ -z "${PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH:-}" ]; then
  npx playwright install --with-deps chromium >/tmp/pmx-playwright-install.log 2>&1 \
    || npx playwright install chromium >>/tmp/pmx-playwright-install.log 2>&1 \
    || true
fi

exec node pmx-browserless-lite.cjs
