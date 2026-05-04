#!/usr/bin/env sh
set -eu

PORT="${PORT:-3000}"
ROOT="${PMX_BROWSERLESS_ROOT:-}"

if [ -z "${ROOT}" ]; then
  if [ -f "./scripts/start-browserless.sh" ]; then
    ROOT="$(pwd)"
  else
    ROOT="$(find /workspaces -maxdepth 2 -type f -path '*/scripts/start-browserless.sh' -print -quit 2>/dev/null | sed 's#/scripts/start-browserless.sh##')"
  fi
fi

if [ -z "${ROOT}" ] || [ ! -f "${ROOT}/scripts/start-browserless.sh" ]; then
  echo "PMX Browserless runtime root not found" >/tmp/pmx-browserless.log
  exit 1
fi

cd "${ROOT}"

if ! (ss -ltn 2>/dev/null || netstat -ltn 2>/dev/null || true) | grep -q ":${PORT} "; then
  nohup sh scripts/start-browserless.sh > /tmp/pmx-browserless.log 2>&1 &
fi

# GitHub forwarded ports are private by default even when forwardPorts exists.
# PMX needs a public endpoint because Coolify/form-filler calls /pressure and
# /chromium/function without a GitHub browser cookie.
(
  deadline=$(( $(date +%s) + 240 ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if (ss -ltn 2>/dev/null || netstat -ltn 2>/dev/null || true) | grep -q ":${PORT} "; then
      break
    fi
    sleep 3
  done
  if command -v gh >/dev/null 2>&1 && [ -n "${CODESPACE_NAME:-}" ]; then
    gh codespace ports visibility "${PORT}:public" -c "${CODESPACE_NAME}" >/tmp/pmx-codespace-port.log 2>&1 || true
  else
    echo "GitHub CLI unavailable or CODESPACE_NAME missing; port visibility must be set externally." >/tmp/pmx-codespace-port.log
  fi
) &

echo "PMX Browserless startup requested on port ${PORT} from ${ROOT}"
