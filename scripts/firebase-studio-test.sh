#!/usr/bin/env sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$ROOT"

# shellcheck disable=SC1091
. "./scripts/firebase-studio-utils.sh"

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
TMP_DIR="${TMPDIR:-/tmp}"
PRESSURE_FILE="${TMP_DIR}/pmx-firebase-pressure.json"
CAPACITY_FILE="${TMP_DIR}/pmx-firebase-capacity.json"
FUNCTION_FILE="${TMP_DIR}/pmx-firebase-function.json"
LOCAL_PRESSURE="$(pmx_local_pressure_url)"

echo "Testing PMX Browserless runtime on ${BASE}"
echo
echo "PRESSURE"
if ! curl -fsS "${BASE}/pressure?token=${TOKEN}" | tee "$PRESSURE_FILE"; then
  echo
  echo "RESULTAT: KO - aucun serveur ne repond sur ${BASE}."
  echo "CAUSE: le process Next/Browserless n'est pas lance ou il s'est arrete."
  echo "FIX: garde le premier terminal ouvert avec:"
  echo "sh scripts/firebase-studio-start.sh 2>&1 | tee /tmp/pmx-browserless-live.log"
  exit 2
fi
echo
echo
echo "CAPACITY"
if ! curl -fsS "${BASE}/capacity?token=${TOKEN}" | tee "$CAPACITY_FILE"; then
  echo
  echo "RESULTAT: KO - /capacity ne repond pas."
  exit 2
fi
echo
echo
echo "FUNCTION"
if ! curl -fsS -X POST "${BASE}/chromium/function?token=${TOKEN}&timeout=30000" \
  -H "Content-Type: application/json" \
  --data '{"code":"async ({ page }) => { await page.goto(\"https://example.com\", { waitUntil: \"domcontentloaded\" }); return { title: await page.title(), url: page.url() }; }","context":{}}' \
  | tee "$FUNCTION_FILE"; then
  echo
  echo "RESULTAT: KO - /chromium/function ne repond pas correctement."
  exit 2
fi
echo
echo
echo "========================================"
pmx_print_capacity_summary "$CAPACITY_FILE"
echo
echo "URL PMX LOCALE"
echo "$LOCAL_PRESSURE"
if PUBLIC_PRESSURE="$(pmx_public_pressure_url)"; then
  echo
  echo "URL PMX PUBLIQUE DETECTEE"
  echo "$PUBLIC_PRESSURE"
  COPY_TARGET="$PUBLIC_PRESSURE"
else
  COPY_TARGET="$LOCAL_PRESSURE"
fi

if pmx_copy_to_clipboard "$COPY_TARGET"; then
  echo
  echo "CLIPBOARD: URL pressure copied"
else
  echo
  echo "CLIPBOARD: unavailable here; copy the URL above manually"
fi

if grep -q 'Example Domain' "$FUNCTION_FILE"; then
  echo
  echo "RESULTAT: OK - Runtime compatible PMX."
else
  echo
  echo "RESULTAT: KO - FUNCTION did not return Example Domain. Do not add this server to PMX yet."
  if grep -q 'libglib-2.0.so.0' "$FUNCTION_FILE" || grep -q 'shared libraries' "$FUNCTION_FILE"; then
    echo
    echo "CAUSE PROBABLE: Firebase Studio did not load the root .idx/dev.nix."
    echo "FIX: run from workspace root:"
    echo "sh pmx-browserless-runtime/scripts/firebase-studio-bootstrap.sh"
    echo "Then rebuild/hard restart Firebase Studio once, restart the server, and retest."
  fi
  exit 1
fi
