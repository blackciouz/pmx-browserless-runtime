#!/usr/bin/env sh
set -eu

export PORT="${PORT:-3000}"
export TOKEN="${BROWSERLESS_TOKEN:-${TOKEN:-change-me}}"
export CONCURRENT="${CONCURRENT:-1}"
export QUEUED="${QUEUED:-20}"
export TIMEOUT="${TIMEOUT:-300000}"
export MAX_MEMORY_PERCENT="${MAX_MEMORY_PERCENT:-95}"
export MAX_CPU_PERCENT="${MAX_CPU_PERCENT:-95}"

echo "Starting Browserless on port ${PORT} with CONCURRENT=${CONCURRENT}, QUEUED=${QUEUED}"

if command -v docker >/dev/null 2>&1; then
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

echo "Docker is not available. This runtime must run in Docker-capable CodeSandbox/Codespaces."
exit 1

