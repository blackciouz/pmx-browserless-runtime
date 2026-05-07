#!/usr/bin/env sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$ROOT"

ENV_FILE=".env.firebase-studio"
if [ ! -f "$ENV_FILE" ]; then
  echo "Missing $ENV_FILE. Start once with: sh scripts/firebase-studio-start.sh" >&2
  exit 1
fi

set -a
# shellcheck disable=SC1090
. "./$ENV_FILE"
set +a

TOKEN="${BROWSERLESS_TOKEN:-${TOKEN:-change-me}}"
PORT="${PORT:-3000}"
BASE="http://localhost:${PORT}"

echo "Testing PMX Browserless runtime on ${BASE}"
echo
echo "PRESSURE"
curl -sS "${BASE}/pressure?token=${TOKEN}"
echo
echo
echo "CAPACITY"
curl -sS "${BASE}/capacity?token=${TOKEN}"
echo
echo
echo "FUNCTION"
curl -sS -X POST "${BASE}/chromium/function?token=${TOKEN}&timeout=30000" \
  -H "Content-Type: application/json" \
  --data '{"code":"async ({ page }) => { await page.goto(\"https://example.com\", { waitUntil: \"domcontentloaded\" }); return { title: await page.title(), url: page.url() }; }","context":{}}'
echo
echo
echo "If all three calls returned JSON and FUNCTION contains Example Domain, the runtime is PMX-compatible."
echo "Public pressure URL format: https://PUBLIC_PREVIEW_HOST/pressure?token=${TOKEN}"
