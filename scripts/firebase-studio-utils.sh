#!/usr/bin/env sh

pmx_public_pressure_url() {
  port="${PORT:-3000}"
  token="${BROWSERLESS_TOKEN:-${TOKEN:-change-me}}"
  if [ -n "${WEB_HOST:-}" ]; then
    printf 'https://%s-%s/pressure?token=%s' "$port" "$WEB_HOST" "$token"
    return 0
  fi
  return 1
}

pmx_local_pressure_url() {
  port="${PORT:-3000}"
  token="${BROWSERLESS_TOKEN:-${TOKEN:-change-me}}"
  printf 'http://localhost:%s/pressure?token=%s' "$port" "$token"
}

pmx_copy_to_clipboard() {
  value="$1"

  if command -v wl-copy >/dev/null 2>&1; then
    printf '%s' "$value" | wl-copy >/dev/null 2>&1 && return 0
  fi
  if command -v xclip >/dev/null 2>&1; then
    printf '%s' "$value" | xclip -selection clipboard >/dev/null 2>&1 && return 0
  fi
  if command -v xsel >/dev/null 2>&1; then
    printf '%s' "$value" | xsel --clipboard --input >/dev/null 2>&1 && return 0
  fi
  if command -v pbcopy >/dev/null 2>&1; then
    printf '%s' "$value" | pbcopy >/dev/null 2>&1 && return 0
  fi
  if command -v clip.exe >/dev/null 2>&1; then
    printf '%s' "$value" | clip.exe >/dev/null 2>&1 && return 0
  fi

  if command -v base64 >/dev/null 2>&1; then
    encoded="$(printf '%s' "$value" | base64 | tr -d '\n')"
    # OSC 52 clipboard escape. Many browser terminals support it, some block it.
    printf '\033]52;c;%s\a' "$encoded" >/dev/tty 2>/dev/null && return 0
  fi

  return 1
}

pmx_print_capacity_summary() {
  json_file="$1"
  node - "$json_file" <<'NODE'
const fs = require('fs');
const file = process.argv[2];
const raw = fs.readFileSync(file, 'utf8').trim();
if (!raw) {
  console.error(`Capacity response is empty: ${file}`);
  process.exit(2);
}

let data;
try {
  data = JSON.parse(raw);
} catch (error) {
  console.error(`Capacity response is not valid JSON: ${file}`);
  console.error(raw.slice(0, 500));
  process.exit(2);
}
const cores = data.cores ?? '?';
const total = data.totalMemoryGb ?? '?';
const free = data.freeMemoryGb ?? '?';
const concurrent = data.concurrent ?? '?';
const queued = data.maxQueued ?? data.queued ?? '?';
const mode = data.mode ?? 'unknown';

console.log('RESSOURCES FIREBASE STUDIO');
console.log(`- CPU: ${cores} coeur(s) disponible(s)`);
console.log(`- RAM: ${total} Go total, ${free} Go libre au moment du test`);
console.log(`- Concurrence PMX: ${concurrent} session navigateur active max`);
console.log(`- File attente PMX: ${queued} job(s) max`);
console.log(`- Mode: ${mode}`);
NODE
}
