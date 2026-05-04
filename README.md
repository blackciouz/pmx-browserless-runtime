# PMX Browserless Runtime

Minimal runtime for PMX remote Browserless providers.

It is intended for:

- GitHub Codespaces
- CodeSandbox templates
- Firebase Studio workspaces
- future Hugging Face Spaces Docker runtime

The runtime starts real Docker Browserless when Docker is available. If Docker is
not available, it falls back to a Playwright-based compatible server that
supports the PMX endpoints used for qualification and campaign runs:

- `GET /pressure?token=<TOKEN>`
- `GET /capacity?token=<TOKEN>`
- `POST /chromium/function?token=<TOKEN>&timeout=300000`
- `POST /function?token=<TOKEN>&timeout=300000`

The lite fallback does not expose Browserless CDP/live-session endpoints. Use
Docker Browserless for human captcha live intervention.

## Pressure URL

Browserless exposes:

```text
https://<host>/pressure?token=<TOKEN>
```

PMX uses this endpoint to read capacity before sending qualification or campaign jobs.

## Required Variables

```env
TOKEN=change-me
BROWSERLESS_TOKEN=change-me
CONCURRENT=1
QUEUED=20
TIMEOUT=300000
DEFAULT_TIMEOUT=300000
MAX_MEMORY_PERCENT=95
MAX_CPU_PERCENT=95
PORT=3000
PMX_BROWSERLESS_MODE=auto
```

For Codespaces, `BROWSERLESS_TOKEN` is also accepted and has priority over `TOKEN`.

## Codespaces Notes

The devcontainer starts Browserless automatically and exposes port `3000`.

Important: PMX must inject the same token used in the generated pressure URL. If `BROWSERLESS_TOKEN` is not configured in Codespaces, Browserless starts with `TOKEN=change-me`, which is useful only for manual testing.

## CodeSandbox Notes

PMX can use this repository as a stable template/reference. The API currently starts Browserless through the CodeSandbox SDK by running Docker directly in the sandbox and injecting the generated Browserless token.

## Firebase Studio Notes

Firebase Studio can use this repo as a plain workspace. Start the server with:

```bash
export BROWSERLESS_TOKEN=<token>
export CONCURRENT=1
export QUEUED=20
export TIMEOUT=300000
export PMX_BROWSERLESS_MODE=lite
sh scripts/start-browserless.sh
```

Then expose port `3000` publicly and register the resulting `/pressure?token=...`
URL in PMX.

## Local Test

```bash
cp .env.example .env
docker compose up
```

Then open:

```text
http://localhost:3000/pressure?token=change-me
```
