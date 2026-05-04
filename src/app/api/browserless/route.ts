import os from 'node:os';
import { NextRequest, NextResponse } from 'next/server';

export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

const TOKEN = process.env.BROWSERLESS_TOKEN || process.env.TOKEN || 'change-me';
const CONCURRENT = positiveInt(process.env.CONCURRENT, 1);
const QUEUED = positiveInt(process.env.QUEUED, 20);
const DEFAULT_TIMEOUT = positiveInt(process.env.DEFAULT_TIMEOUT || process.env.TIMEOUT, 300_000);
const MAX_BODY_BYTES = positiveInt(process.env.MAX_BODY_BYTES, 20_000_000);

let active = 0;
let rejected = 0;
const waiters: Array<{ resolve: (value: boolean) => void; timer: NodeJS.Timeout }> = [];

function positiveInt(value: unknown, fallback: number): number {
  const parsed = Number(value);
  return Number.isFinite(parsed) && parsed > 0 ? Math.floor(parsed) : fallback;
}

function json(payload: unknown, status = 200): NextResponse {
  return NextResponse.json(payload, {
    status,
    headers: { 'cache-control': 'no-store' },
  });
}

function authorized(request: NextRequest): boolean {
  if (!TOKEN) return true;
  return request.nextUrl.searchParams.get('token') === TOKEN;
}

function acquire(timeoutMs: number): Promise<boolean> {
  if (active < CONCURRENT) {
    active += 1;
    return Promise.resolve(true);
  }
  if (waiters.length >= QUEUED) {
    rejected += 1;
    return Promise.resolve(false);
  }
  return new Promise(resolve => {
    const waiter = {
      resolve,
      timer: setTimeout(() => {
        const index = waiters.indexOf(waiter);
        if (index >= 0) waiters.splice(index, 1);
        rejected += 1;
        resolve(false);
      }, timeoutMs),
    };
    waiters.push(waiter);
  });
}

function release(): void {
  active = Math.max(0, active - 1);
  const waiter = waiters.shift();
  if (!waiter) return;
  clearTimeout(waiter.timer);
  active += 1;
  waiter.resolve(true);
}

function compile(code: unknown): (input: { page: unknown; context: unknown; browser: unknown }) => unknown | Promise<unknown> {
  const source = String(code || '').trim();
  if (!source) throw new Error('Missing code');
  if (source.startsWith('export default')) {
    return new Function(`${source.replace(/^export\s+default\s+/, 'return ')};`)();
  }
  if (source.includes('module.exports')) {
    const module: { exports?: unknown } = {};
    new Function('module', 'exports', source)(module, module.exports);
    return module.exports as (input: { page: unknown; context: unknown; browser: unknown }) => unknown | Promise<unknown>;
  }
  return new Function(`return (${source});`)();
}

function timeoutPromise(timeoutMs: number): Promise<never> {
  return new Promise((_, reject) => {
    setTimeout(() => reject(new Error(`Timeout after ${timeoutMs}ms`)), timeoutMs);
  });
}

async function runFunction(code: unknown, context: unknown, timeoutMs: number): Promise<unknown> {
  const fn = compile(code);
  if (typeof fn !== 'function') throw new Error('Browserless code did not export a function');

  const playwright = await import('playwright');
  const chromium = playwright.chromium;
  let browser: Awaited<ReturnType<typeof chromium.launch>> | undefined;

  const work = (async () => {
    browser = await chromium.launch({
      executablePath: process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH || process.env.CHROMIUM_PATH || undefined,
      headless: true,
      args: [
        '--no-sandbox',
        '--disable-dev-shm-usage',
        '--disable-gpu',
        '--disable-setuid-sandbox',
      ],
    });
    const page = await browser.newPage();
    return fn({ page, context: context || {}, browser });
  })();

  try {
    return await Promise.race([work, timeoutPromise(timeoutMs)]);
  } finally {
    if (browser) await browser.close().catch(() => undefined);
  }
}

function pressurePayload() {
  const total = os.totalmem();
  const free = os.freemem();
  const memory = Math.round(((total - free) / Math.max(1, total)) * 100);
  const cpu = Math.min(100, Math.round((os.loadavg()[0] / Math.max(1, os.cpus().length)) * 100));
  return {
    pressure: {
      cpu,
      memory,
      date: Date.now(),
      isAvailable: active < CONCURRENT && waiters.length < QUEUED,
      maxConcurrent: CONCURRENT,
      maxQueued: QUEUED,
      running: active,
      queued: waiters.length,
      recentlyRejected: rejected,
      reason: '',
      message: '',
      hostCpu: cpu,
      hostMemory: memory,
      mode: 'next-api-playwright-lite',
      cdp: false,
    },
  };
}

function capacityPayload() {
  return {
    ok: true,
    mode: 'next-api-playwright-lite',
    cdp: false,
    cores: os.cpus().length,
    totalMemoryGb: +(os.totalmem() / 1024 / 1024 / 1024).toFixed(1),
    freeMemoryGb: +(os.freemem() / 1024 / 1024 / 1024).toFixed(1),
    active,
    queued: waiters.length,
    concurrent: CONCURRENT,
    maxQueued: QUEUED,
  };
}

function errorReason(error: unknown): string {
  const message = error instanceof Error ? error.message : String(error);
  if (/timeout/i.test(message)) return 'timeout';
  if (/executable|chromium|browser/i.test(message)) return 'browser_launch_failed';
  if (/missing code|export|function/i.test(message)) return 'compile_error';
  return 'browser_error';
}

export async function GET(request: NextRequest) {
  if (!authorized(request)) return json({ error: 'Invalid token' }, 401);
  const action = request.nextUrl.searchParams.get('action') || 'health';
  if (action === 'pressure') return json(pressurePayload());
  if (action === 'capacity') return json(capacityPayload());
  if (action === 'health') return json({ ok: true, mode: 'next-api-playwright-lite' });
  return json({ error: 'Not found', action }, 404);
}

export async function POST(request: NextRequest) {
  if (!authorized(request)) return json({ error: 'Invalid token' }, 401);
  const action = request.nextUrl.searchParams.get('action') || 'function';
  if (action !== 'function') return json({ error: 'Not found', action }, 404);

  const timeoutMs = positiveInt(request.nextUrl.searchParams.get('timeout'), DEFAULT_TIMEOUT);
  const slot = await acquire(timeoutMs);
  if (!slot) return json({ error: 'Queue full or acquire timeout', reason: 'queue_full' }, 429);

  try {
    const raw = await request.text();
    if (raw.length > MAX_BODY_BYTES) return json({ error: 'Body too large', reason: 'body_too_large' }, 413);
    const payload = raw ? JSON.parse(raw) as { code?: unknown; context?: unknown } : {};
    const data = await runFunction(payload.code, payload.context || {}, timeoutMs);
    return json({ data });
  } catch (error) {
    return json({
      error: error instanceof Error ? error.message : String(error),
      reason: errorReason(error),
    }, /timeout/i.test(error instanceof Error ? error.message : String(error)) ? 408 : 500);
  } finally {
    release();
  }
}
