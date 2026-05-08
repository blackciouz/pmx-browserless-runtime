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
export PMX_NEXT_SERVER_MODE="${PMX_NEXT_SERVER_MODE:-dev}"

echo "Starting PMX Browserless runtime on port ${PORT} with CONCURRENT=${CONCURRENT}, QUEUED=${QUEUED}, mode=${PMX_BROWSERLESS_MODE}, next=${PMX_NEXT_SERVER_MODE}"

pmx_next_api_deps_ready() {
  [ -f node_modules/next/dist/bin/next ] \
    && [ -f node_modules/next/dist/server/require-hook.js ] \
    && [ -f node_modules/react/package.json ] \
    && [ -f node_modules/react-dom/package.json ] \
    && [ -d node_modules/playwright ]
}

pmx_install_next_api_deps() {
  echo "Installing/repairing Next API runtime dependencies..."
  npm install --no-audit --no-fund

  if pmx_next_api_deps_ready; then
    return 0
  fi

  echo "Detected incomplete node_modules. Reinstalling damaged runtime packages..."
  rm -rf node_modules/next node_modules/react node_modules/react-dom node_modules/playwright
  npm install --no-audit --no-fund

  if ! pmx_next_api_deps_ready; then
    echo "Next API runtime dependencies are still incomplete after reinstall."
    echo "Delete node_modules manually and rerun: sh scripts/firebase-studio-start.sh"
    exit 1
  fi
}

if [ "${PMX_BROWSERLESS_MODE}" = "next-api" ]; then
  if ! pmx_next_api_deps_ready; then
    pmx_install_next_api_deps
  fi
  if [ -z "${PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH:-}" ] || [ ! -x "${PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH:-}" ]; then
    for candidate in chromium chromium-browser google-chrome chrome; do
      if command -v "$candidate" >/dev/null 2>&1; then
        export PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH="$(command -v "$candidate")"
        break
      fi
    done
  fi
  if [ "${PMX_BROWSERLESS_FIREBASE_STUDIO:-}" = "1" ] && { [ -z "${PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH:-}" ] || [ ! -x "${PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH:-}" ]; }; then
    echo "Firebase Studio requires system Chromium from .idx/dev.nix."
    echo "Run scripts/firebase-studio-bootstrap.sh from the workspace root, then hard rebuild/restart Firebase Studio."
    exit 20
  fi
  if [ -z "${PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH:-}" ]; then
    echo "Ensuring Playwright Chromium is installed for Next API runtime..."
    npx playwright install --with-deps chromium >/tmp/pmx-playwright-install.log 2>&1 \
      || npx playwright install chromium >>/tmp/pmx-playwright-install.log 2>&1 \
      || true
  fi
  exec npm run next-api
fi

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
  npm install --no-audit --no-fund
fi

if [ -z "${PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH:-}" ]; then
  npx playwright install --with-deps chromium >/tmp/pmx-playwright-install.log 2>&1 \
    || npx playwright install chromium >>/tmp/pmx-playwright-install.log 2>&1 \
    || true
fi

exec node pmx-browserless-lite.cjs
