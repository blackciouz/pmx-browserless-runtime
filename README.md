# PMX Browserless Runtime

Minimal runtime for PMX remote Browserless providers.

It is intended for:

- GitHub Codespaces
- CodeSandbox templates
- Firebase Studio workspaces
- Hugging Face Spaces Docker runtime

The runtime starts real Docker Browserless when Docker is available. If Docker is
not available, it falls back to a Playwright-based compatible server that
supports the PMX endpoints used for qualification and campaign runs:

- `GET /pressure?token=<TOKEN>`
- `GET /capacity?token=<TOKEN>`
- `POST /chromium/function?token=<TOKEN>&timeout=300000`
- `POST /function?token=<TOKEN>&timeout=300000`

The lite fallback does not expose Browserless CDP/live-session endpoints. Use
Docker Browserless for human captcha live intervention.

## Hugging Face Spaces Notes

Use `Dockerfile.hf-playwright` for Hugging Face when the Browserless Docker image
is blocked or unreliable. This runtime does not install or run Browserless
itself; it installs system Chromium and serves the PMX-compatible Playwright lite
API directly:

```text
GET  /pressure?token=<TOKEN>
GET  /capacity?token=<TOKEN>
POST /chromium/function?token=<TOKEN>&timeout=300000
```

The PMX Hugging Face provider defaults to this `playwright_lite` mode. Keep the
legacy Browserless image only when CDP/live-session behavior is required.

## Modes

```env
PMX_BROWSERLESS_MODE=auto      # Docker when available, then Playwright lite
PMX_BROWSERLESS_MODE=lite      # Always use pmx-browserless-lite.cjs
PMX_BROWSERLESS_MODE=next-api  # Use Next.js API route /api/browserless
```

Use `next-api` for Firebase Studio, Z.ai, and similar sandboxes where standalone
Node processes are killed after roughly 60-90 seconds. In that mode the browser
runner lives inside the main Next.js process.

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
It also tries to run `gh codespace ports visibility 3000:public` at boot, because
GitHub private forwarded ports return HTML/login pages to PMX instead of JSON.

Important: PMX must inject the same token used in the generated pressure URL. If `BROWSERLESS_TOKEN` is not configured in Codespaces, Browserless starts with `TOKEN=change-me`, which is useful only for manual testing.

## CodeSandbox Notes

PMX can use this repository as a stable template/reference. The API currently starts Browserless through the CodeSandbox SDK by running Docker directly in the sandbox and injecting the generated Browserless token.

## Firebase Studio Notes

Firebase Studio/Z.ai should use the Next.js API route mode. Do not start a
standalone Node server in these environments: it can be killed after a short
idle window. The direct `/pressure` and `/chromium/function` paths are rewritten
to `/api/browserless`, so PMX can use a normal pressure URL.

Firebase Studio defaults to `CONCURRENT=2`. This keeps the runtime useful without
overloading small Firebase Studio workspaces. Increase it in `.env.firebase-studio`
only after a real `/chromium/function` test stays stable.

Firebase Studio also defaults to `PMX_FIREBASE_HEADFUL_XVFB=1`. The launcher
runs the Next API runtime under `xvfb-run` and sets Chromium to headed mode
inside the virtual display. Keep this enabled unless you are debugging basic
headless-only pages; it is required for some popover/combobox forms that crash
the Firebase system Chromium in pure headless mode.

Firebase Studio starts the Next API runtime in webpack dev mode by default.
This avoids `next build` SIGBUS failures seen in small Firebase Studio
workspaces. If you explicitly switch to production mode and the build fails, the
launcher falls back to dev mode unless `PMX_NEXT_BUILD_FALLBACK_DEV=0`.

The Next API runtime launches an isolated Chromium per request by default. This
matches the Anyscale runner behavior and avoids cross-site crashes leaking
between qualification leads. Set `PMX_REUSE_BROWSER=1` only when speed matters
more than isolation.

From a blank Firebase Studio workspace terminal:

```bash
curl -fsSL https://raw.githubusercontent.com/blackciouz/pmx-browserless-runtime/master/scripts/firebase-studio-bootstrap.sh | sh
```

If the script asks for a Firebase Studio rebuild/hard restart, do it once. This
is required when the workspace root did not already load `.idx/dev.nix`.

In a second terminal, test local compatibility:

```bash
cd pmx-browserless-runtime
sh scripts/firebase-studio-test.sh
```

The test script runs a basic Browserless compatibility check and, by default,
a strict form canary against a searchable combobox. If the strict canary fails,
do not register the Firebase Studio URL as a primary PMX provider for complex
forms yet. For a basic-only smoke test, run:

```bash
PMX_FIREBASE_STRICT_FORM_TESTS=0 sh scripts/firebase-studio-test.sh
```

If your prompt already ends with `pmx-browserless-runtime`, do not run the
`cd pmx-browserless-runtime` line again. The test script does not start the
server; keep the first terminal running `sh scripts/firebase-studio-start.sh`.

If the function test says that the Chromium executable is missing, run:

```bash
cd pmx-browserless-runtime
npx playwright install chromium
sh scripts/firebase-studio-test.sh
```

Then expose port `3000` publicly in Firebase Studio and register this URL in PMX:

```text
https://<public-preview-host>/pressure?token=<TOKEN>
```

## Agent Prompt

```text
Clone exactly https://github.com/blackciouz/pmx-browserless-runtime.
Do not clone forks or renamed repositories.
Run: cd pmx-browserless-runtime && sh scripts/firebase-studio-start.sh
Open a second terminal and run: cd pmx-browserless-runtime && sh scripts/firebase-studio-test.sh
Expose port 3000 publicly in Firebase Studio.
Test:
- GET /pressure?token=TOKEN
- GET /capacity?token=TOKEN
- POST /chromium/function?token=TOKEN&timeout=30000 with example.com
Return the public pressure URL, function URL, token, CPU/RAM, and test results.
Do not return success if function fails or if Chromium cannot launch.
```

## Local Test

```bash
cp .env.example .env
docker compose up
```

Then open:

```text
http://localhost:3000/pressure?token=change-me
```
