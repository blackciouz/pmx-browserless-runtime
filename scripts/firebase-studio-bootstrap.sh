#!/usr/bin/env sh
set -eu

WORKSPACE_ROOT="$(pwd)"
REPO_DIR="${PMX_BROWSERLESS_REPO_DIR:-pmx-browserless-runtime}"
REPO_URL="${PMX_BROWSERLESS_REPO_URL:-https://github.com/blackciouz/pmx-browserless-runtime.git}"

if [ -d "$REPO_DIR/.git" ]; then
  echo "Updating ${REPO_DIR}..."
  git -C "$REPO_DIR" pull --ff-only origin master
else
  rm -rf "$REPO_DIR"
  echo "Cloning ${REPO_URL}..."
  git clone "$REPO_URL" "$REPO_DIR"
fi

mkdir -p "$WORKSPACE_ROOT/.idx"
cp "$REPO_DIR/.idx/dev.nix" "$WORKSPACE_ROOT/.idx/dev.nix"

cd "$REPO_DIR"
npm install

if [ -n "${PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH:-}" ] && [ -x "${PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH}" ]; then
  echo "Using system Chromium: ${PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH}"
else
  echo "No system Chromium detected in this shell yet."
  echo "The workspace root .idx/dev.nix has been installed."
  echo "Run Firebase Studio rebuild/hard restart once, then run:"
  echo "cd ${REPO_DIR} && sh scripts/firebase-studio-start.sh"
  exit 20
fi

exec sh scripts/firebase-studio-start.sh
