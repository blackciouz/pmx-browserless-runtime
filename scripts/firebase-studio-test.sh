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

TOKEN="${PMX_TEST_TOKEN:-${BROWSERLESS_TOKEN:-${TOKEN:-change-me}}}"
PORT="${PORT:-3000}"
BASE="http://localhost:${PORT}"
TMP_DIR="${TMPDIR:-/tmp}"
PRESSURE_FILE="${TMP_DIR}/pmx-firebase-pressure.json"
CAPACITY_FILE="${TMP_DIR}/pmx-firebase-capacity.json"
FUNCTION_FILE="${TMP_DIR}/pmx-firebase-function.json"
FORM_FILE="${TMP_DIR}/pmx-firebase-form-canary.json"
FORM_PAYLOAD_FILE="${TMP_DIR}/pmx-firebase-form-canary-payload.json"
LOCAL_PRESSURE="$(pmx_local_pressure_url)"

pmx_fetch_json() {
  label="$1"
  url="$2"
  output_file="$3"
  shift 3

  rm -f "$output_file"
  if ! curl -fsS "$@" -o "$output_file" "$url"; then
    echo
    echo "RESULTAT: KO - ${label} ne repond pas sur ${BASE}."
    echo "CAUSE: le process Next/Browserless n'est pas lance, il s'est arrete, ou le port ${PORT} n'est pas encore pret."
    echo "FIX: garde le premier terminal ouvert avec:"
    echo "sh scripts/firebase-studio-start.sh 2>&1 | tee /tmp/pmx-browserless-live.log"
    exit 2
  fi

  if [ ! -s "$output_file" ]; then
    echo
    echo "RESULTAT: KO - ${label} a retourne une reponse vide."
    echo "CAUSE: mauvais process sur le port ${PORT}, runtime pas pret, ou proxy Firebase incomplet."
    exit 2
  fi

  cat "$output_file"
}

echo "Testing PMX Browserless runtime on ${BASE}"
echo
echo "PRESSURE"
pmx_fetch_json "PRESSURE" "${BASE}/pressure?token=${TOKEN}" "$PRESSURE_FILE"
echo
echo
echo "CAPACITY"
pmx_fetch_json "CAPACITY" "${BASE}/capacity?token=${TOKEN}" "$CAPACITY_FILE"
echo
echo
echo "FUNCTION"
pmx_fetch_json "FUNCTION" "${BASE}/chromium/function?token=${TOKEN}&timeout=30000" "$FUNCTION_FILE" \
  -X POST \
  -H "Content-Type: application/json" \
  --data '{"code":"async ({ page }) => { await page.setUserAgent(\"PMX-Firebase-Test/1.0\"); await page.setViewport({ width: 1280, height: 720, deviceScaleFactor: 1 }); await page.evaluateOnNewDocument(() => { window.__pmxInit = true; }); await page.setRequestInterception(true); page.on(\"request\", req => req.continue()); await page.goto(\"https://example.com\", { waitUntil: \"networkidle2\" }); return { title: await page.title(), url: page.url(), ua: await page.evaluate(() => navigator.userAgent), init: await page.evaluate(() => window.__pmxInit === true), multi: await page.evaluate((a, b, c) => a + b + c, 2, 3, 4) }; }","context":{}}'
echo
echo
if [ "${PMX_FIREBASE_STRICT_FORM_TESTS:-1}" = "1" ]; then
  cat > "$FORM_PAYLOAD_FILE" <<'JSON'
{"code":"async ({ page }) => { await page.setViewport({ width: 1600, height: 1000, deviceScaleFactor: 1 }); await page.goto(\"https://form-filler-test.lovable.app/test-searchable-combobox\", { waitUntil: \"domcontentloaded\", timeout: 45000 }); await page.waitForSelector(\"button[role=\\\"combobox\\\"]\", { timeout: 15000 }); await page.click(\"button[role=\\\"combobox\\\"]\", { timeout: 10000 }); await page.waitForTimeout(750); const result = await page.evaluate(() => ({ canary: \"searchable-combobox\", expanded: document.querySelector('button[role=\"combobox\"]')?.getAttribute('aria-expanded'), options: Array.from(document.querySelectorAll('[role=\"option\"], [cmdk-item], [data-radix-collection-item]')).map(el => (el.textContent || '').trim()).filter(Boolean).slice(0, 12) })); if (!result.options.length) throw new Error('combobox canary did not expose options'); return result; }","context":{}}
JSON
  echo "FORM CANARY"
  pmx_fetch_json "FORM_CANARY" "${BASE}/chromium/function?token=${TOKEN}&timeout=90000" "$FORM_FILE" \
    -X POST \
    -H "Content-Type: application/json" \
    --data @"$FORM_PAYLOAD_FILE"
  echo
  echo
fi
echo
echo
echo "========================================"
if ! pmx_print_capacity_summary "$CAPACITY_FILE"; then
  echo
  echo "RESULTAT: KO - /capacity a repondu, mais pas avec le JSON PMX attendu."
  echo "CAUSE: mauvais process sur le port ${PORT}, proxy Firebase incomplet, ou runtime pas encore pret."
  echo "FIX: arrete le terminal serveur, relance:"
  echo "sh scripts/firebase-studio-start.sh"
  exit 2
fi
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

if grep -q 'Example Domain' "$FUNCTION_FILE" && grep -q 'PMX-Firebase-Test' "$FUNCTION_FILE" && grep -q '"init":true' "$FUNCTION_FILE" && grep -q '"multi":9' "$FUNCTION_FILE"; then
  if [ "${PMX_FIREBASE_STRICT_FORM_TESTS:-1}" = "1" ]; then
    if grep -q '"canary":"searchable-combobox"' "$FORM_FILE" && grep -q '"options":\[' "$FORM_FILE"; then
      echo
      echo "RESULTAT: OK - Runtime compatible PMX, canary formulaire inclus."
    else
      echo
      echo "RESULTAT: KO - Runtime basic OK, mais le canary formulaire Firebase a echoue."
      echo "CAUSE: Chromium Firebase ne peut pas ouvrir un combobox/popover requis sans crash ou timeout."
      echo "FIX: relance avec les derniers scripts; si ca persiste, ne pas ajouter ce serveur comme provider principal pour les formulaires complexes."
      exit 1
    fi
  else
    echo
    echo "RESULTAT: OK - Runtime compatible PMX basic. Strict form tests disabled."
  fi
else
  echo
  echo "RESULTAT: KO - FUNCTION did not pass the PMX compatibility checks. Do not add this server to PMX yet."
  if grep -q 'libglib-2.0.so.0' "$FUNCTION_FILE" || grep -q 'shared libraries' "$FUNCTION_FILE"; then
    echo
    echo "CAUSE PROBABLE: Firebase Studio did not load the root .idx/dev.nix."
    echo "FIX: run from workspace root:"
    echo "sh pmx-browserless-runtime/scripts/firebase-studio-bootstrap.sh"
    echo "Then rebuild/hard restart Firebase Studio once, restart the server, and retest."
  fi
  exit 1
fi
