# PMX Browserless Runtime

Minimal runtime for PMX remote Browserless providers.

It is intended for:

- GitHub Codespaces
- CodeSandbox templates
- future Hugging Face Spaces Docker runtime

## Pressure URL

Browserless exposes:

```text
https://<host>/pressure?token=<TOKEN>
```

PMX uses this endpoint to read capacity before sending qualification or campaign jobs.

## Required Variables

```env
TOKEN=change-me
CONCURRENT=1
QUEUED=20
TIMEOUT=300000
MAX_MEMORY_PERCENT=95
MAX_CPU_PERCENT=95
PORT=3000
```

For Codespaces, `BROWSERLESS_TOKEN` is also accepted and has priority over `TOKEN`.

## Codespaces Notes

The devcontainer starts Browserless automatically with Docker-in-Docker and exposes port `3000`.

Important: PMX must inject the same token used in the generated pressure URL. If `BROWSERLESS_TOKEN` is not configured in Codespaces, Browserless starts with `TOKEN=change-me`, which is useful only for manual testing.

## CodeSandbox Notes

PMX can use this repository as a stable template/reference. The API currently starts Browserless through the CodeSandbox SDK by running Docker directly in the sandbox and injecting the generated Browserless token.

## Local Test

```bash
cp .env.example .env
docker compose up
```

Then open:

```text
http://localhost:3000/pressure?token=change-me
```

