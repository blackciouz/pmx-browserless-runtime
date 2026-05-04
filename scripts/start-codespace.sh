#!/usr/bin/env sh
set -eu

PORT="${PORT:-3000}"

nohup sh scripts/start-browserless.sh > /tmp/pmx-browserless.log 2>&1 &

# GitHub forwarded ports are private by default even when forwardPorts exists.
# PMX needs a public endpoint because Coolify/form-filler calls /pressure and
# /chromium/function without a GitHub browser cookie.
(
  sleep 8
  if command -v gh >/dev/null 2>&1 && [ -n "${CODESPACE_NAME:-}" ]; then
    gh codespace ports visibility "${PORT}:public" -c "${CODESPACE_NAME}" >/tmp/pmx-codespace-port.log 2>&1 || true
  fi
) &

echo "PMX Browserless startup requested on port ${PORT}"
