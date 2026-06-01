import os from 'node:os';
import { NextRequest, NextResponse } from 'next/server';
import type { Browser, BrowserContext } from 'playwright';

export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

const TOKEN = process.env.BROWSERLESS_TOKEN || process.env.TOKEN || 'change-me';
const CONCURRENT = positiveInt(process.env.CONCURRENT, 1);
const QUEUED = positiveInt(process.env.QUEUED, 20);
const DEFAULT_TIMEOUT = positiveInt(process.env.DEFAULT_TIMEOUT || process.env.TIMEOUT, 300_000);
const MAX_BODY_BYTES = positiveInt(process.env.MAX_BODY_BYTES, 20_000_000);
const REUSE_BROWSER = ['1', 'true', 'yes', 'on'].includes(String(process.env.PMX_REUSE_BROWSER || '').toLowerCase());
const HEADLESS = !/^(0|false|no)$/i.test(String(process.env.PMX_BROWSERLESS_HEADLESS || process.env.HEADLESS || 'true'));
const BASE_LAUNCH_ENV = { ...process.env };
const PROTECTED_ENV_KEYS = [
  'LD_LIBRARY_PATH',
  'PATH',
  'NODE_OPTIONS',
  'DISPLAY',
  'XDG_DATA_DIRS',
  'PLAYWRIGHT_BROWSERS_PATH',
  'PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH',
  'CHROMIUM_PATH',
] as const;

let active = 0;
let rejected = 0;
const waiters: Array<{ resolve: (value: boolean) => void; timer: NodeJS.Timeout }> = [];
let sharedBrowser: Browser | null = null;
let launchPromise: Promise<Browser> | null = null;
const pageOwner = new WeakMap<BrowserContext, unknown>();
let lastCpuSample = readCpuSample();

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

function snapshotProtectedEnv(): Partial<Record<(typeof PROTECTED_ENV_KEYS)[number], string>> {
  const snapshot: Partial<Record<(typeof PROTECTED_ENV_KEYS)[number], string>> = {};
  for (const key of PROTECTED_ENV_KEYS) {
    if (process.env[key] !== undefined) snapshot[key] = process.env[key];
  }
  return snapshot;
}

function restoreProtectedEnv(snapshot: Partial<Record<(typeof PROTECTED_ENV_KEYS)[number], string>>): void {
  for (const key of PROTECTED_ENV_KEYS) {
    if (snapshot[key] === undefined) {
      delete process.env[key];
    } else {
      process.env[key] = snapshot[key];
    }
  }
}

function proxyFromContext(context: unknown): { server: string; username?: string; password?: string } | null {
  const source = context && typeof context === 'object'
    ? context as Record<string, unknown>
    : {};
  const raw = source.browserlessProxy ?? source.proxy ?? source.proxyUrl;
  if (!raw) return null;

  let server = '';
  let username = '';
  let password = '';
  if (typeof raw === 'string') {
    server = raw.trim();
  } else if (raw && typeof raw === 'object') {
    const record = raw as Record<string, unknown>;
    server = String(record.server ?? record.url ?? '').trim();
    username = String(record.username ?? '').trim();
    password = String(record.password ?? '');
  }

  if (!server) return null;
  let parsed: URL;
  try {
    parsed = new URL(server);
  } catch {
    throw new Error('Invalid proxy URL');
  }
  if (!['http:', 'https:', 'socks4:', 'socks5:'].includes(parsed.protocol)) {
    throw new Error('Unsupported proxy protocol');
  }

  const proxy: { server: string; username?: string; password?: string } = {
    server: `${parsed.protocol}//${parsed.hostname}${parsed.port ? `:${parsed.port}` : ''}`,
  };
  const parsedUsername = decodeURIComponent(parsed.username || '');
  const parsedPassword = decodeURIComponent(parsed.password || '');
  if (username || parsedUsername) proxy.username = username || parsedUsername;
  if (password || parsedPassword) proxy.password = password || parsedPassword;
  return proxy;
}

function readCpuSample(): { idle: number; total: number } {
  let idle = 0;
  let total = 0;
  for (const cpu of os.cpus()) {
    const times = cpu.times || {};
    idle += times.idle || 0;
    total += (times.user || 0) + (times.nice || 0) + (times.sys || 0) + (times.irq || 0) + (times.idle || 0);
  }
  return { idle, total };
}

function cpuPercent(): number {
  const current = readCpuSample();
  const previous = lastCpuSample;
  lastCpuSample = current;
  const totalDelta = current.total - previous.total;
  const idleDelta = current.idle - previous.idle;
  if (totalDelta > 0) {
    const busy = 1 - idleDelta / totalDelta;
    return Math.max(0, Math.min(100, Math.round(busy * 100)));
  }
  const load = os.loadavg()[0] || 0;
  return Math.max(0, Math.min(100, Math.round((load / Math.max(1, os.cpus().length)) * 100)));
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

function sleep(ms: number): Promise<void> {
  return new Promise(resolve => setTimeout(resolve, ms));
}

async function bounded<T>(task: Promise<T>, timeoutMs: number): Promise<T | undefined> {
  let timer: NodeJS.Timeout | undefined;
  try {
    return await Promise.race([
      task,
      new Promise<undefined>(resolve => {
        timer = setTimeout(() => resolve(undefined), timeoutMs);
      }),
    ]);
  } finally {
    if (timer) clearTimeout(timer);
  }
}

function puppeteerCompatiblePage(page: any): any {
  const originalEvaluate = page.evaluate.bind(page);
  page.evaluate = async (fn: unknown, ...args: unknown[]) => {
    if (args.length <= 1) return originalEvaluate(fn, args[0]);
    if (typeof fn !== 'function') return originalEvaluate(fn, args[0]);
    return originalEvaluate(({ source, values }: { source: string; values: unknown[] }) => {
      const pageFn = (0, eval)('(' + source + ')') as (...innerArgs: unknown[]) => unknown;
      return pageFn(...values);
    }, { source: fn.toString(), values: args });
  };

  if (typeof page.setUserAgent !== 'function') {
    page.setUserAgent = async (userAgent: string) => {
      await page.setExtraHTTPHeaders?.({ 'User-Agent': userAgent });
      await page.addInitScript?.((ua: string) => {
        Object.defineProperty(navigator, 'userAgent', { get: () => ua });
      }, userAgent);
    };
  }

  if (typeof page.setViewport !== 'function') {
    page.setViewport = async (viewport: { width?: number; height?: number }) => {
      if (viewport?.width && viewport?.height) {
        await page.setViewportSize({ width: viewport.width, height: viewport.height });
      }
    };
  }

  if (typeof page.evaluateOnNewDocument !== 'function') {
    page.evaluateOnNewDocument = async (fn: (...args: unknown[]) => unknown, ...args: unknown[]) => {
      if (args.length <= 1) {
        await page.addInitScript(fn, args[0]);
        return;
      }
      await page.addInitScript(({ source, values }: { source: string; values: unknown[] }) => {
        const pageFn = (0, eval)('(' + source + ')') as (...innerArgs: unknown[]) => unknown;
        return pageFn(...values);
      }, { source: fn.toString(), values: args });
    };
  }

  if (typeof page.waitForTimeout !== 'function') {
    page.waitForTimeout = (ms: number) => new Promise(resolve => setTimeout(resolve, ms));
  }

  const originalGoto = page.goto.bind(page);
  page.goto = (url: string, options?: Record<string, unknown>) => {
    const waitUntil = options?.waitUntil;
    const normalized = waitUntil === 'networkidle2' || waitUntil === 'networkidle0'
      ? 'networkidle'
      : waitUntil;
    return originalGoto(url, { ...options, waitUntil: normalized });
  };

  const requestHandlers: Array<(request: unknown) => unknown> = [];
  const originalOn = page.on.bind(page);
  page.on = (event: string, handler: (...args: unknown[]) => unknown) => {
    if (event === 'request') {
      requestHandlers.push(handler);
      return page;
    }
    return originalOn(event, handler);
  };

  page.setRequestInterception = async (enabled: boolean) => {
    if (!enabled) return;
    await page.route('**/*', async (route: any) => {
      const request = route.request();
      let handled = false;
      const adapter = {
        url: () => request.url(),
        method: () => request.method(),
        resourceType: () => request.resourceType(),
        headers: () => request.headers(),
        postData: () => request.postData(),
        continue: async () => {
          if (handled) return;
          handled = true;
          await route.continue();
        },
        abort: async () => {
          if (handled) return;
          handled = true;
          await route.abort();
        },
      };

      for (const handler of requestHandlers) {
        await Promise.resolve(handler(adapter));
        if (handled) return;
      }
      if (!handled) await route.continue();
    });
  };

  return page;
}

async function closeExtraPages(context: BrowserContext | undefined, keepPage: unknown): Promise<void> {
  if (!context || typeof context.pages !== 'function') return;
  const pages = context.pages();
  if (pages.length <= 1) return;
  const keep = (keepPage as any) || pages[pages.length - 1];
  for (const page of pages) {
    if (page === keep) continue;
    await page.close().catch(() => undefined);
  }
  if (keep) pageOwner.set(context, keep);
}

async function runFunction(code: unknown, context: unknown, timeoutMs: number): Promise<unknown> {
  const fn = compile(code);
  if (typeof fn !== 'function') throw new Error('Browserless code did not export a function');

  const envSnapshot = snapshotProtectedEnv();
  const browser = REUSE_BROWSER ? await getBrowser() : await launchBrowser();
  let browserContext: BrowserContext | undefined;
  let timedOut = false;
  let timeoutTimer: NodeJS.Timeout | undefined;

  const work = (async () => {
    const proxy = proxyFromContext(context);
    browserContext = await browser.newContext({
      ignoreHTTPSErrors: true,
      viewport: { width: 1600, height: 1000 },
      ...(proxy ? { proxy } : {}),
    });
    browserContext.on?.('page', async (newPage) => {
      try {
        const previous = pageOwner.get(browserContext as BrowserContext) as any;
        await newPage.waitForLoadState?.('domcontentloaded', { timeout: 5000 }).catch(() => undefined);
        if (previous && previous !== newPage && !previous.isClosed?.()) {
          const nextUrl = newPage.url();
          if (nextUrl && nextUrl !== 'about:blank') {
            await previous.goto(nextUrl, { waitUntil: 'domcontentloaded', timeout: 15000 }).catch(() => undefined);
          }
          await newPage.close().catch(() => undefined);
          await closeExtraPages(browserContext, previous);
          return;
        }
        pageOwner.set(browserContext as BrowserContext, newPage);
        await closeExtraPages(browserContext, newPage);
      } catch (_) {}
    });
    const page = puppeteerCompatiblePage(await browserContext.newPage());
    pageOwner.set(browserContext, page);
    return fn({ page, context: context || {}, browser });
  })();
  work.catch(() => undefined);

  try {
    timeoutTimer = setTimeout(() => {
      timedOut = true;
      const contextToClose = browserContext;
      if (contextToClose) bounded(contextToClose.close().catch(() => undefined), 2500).catch(() => undefined);
      if (!REUSE_BROWSER) bounded(browser.close().catch(() => undefined), 2500).catch(() => undefined);
    }, timeoutMs);
    return await Promise.race([work, timeoutPromise(timeoutMs)]);
  } finally {
    if (timeoutTimer) clearTimeout(timeoutTimer);
    if (browserContext && !timedOut) {
      await bounded(closeExtraPages(browserContext, pageOwner.get(browserContext)).catch(() => undefined), 2000);
    }
    if (browserContext) await bounded(browserContext.close().catch(() => undefined), 3000);
    if (!REUSE_BROWSER) await bounded(browser.close().catch(() => undefined), 3000);
    restoreProtectedEnv(envSnapshot);
    if (timedOut) await sleep(25);
  }
}

async function getBrowser(): Promise<Browser> {
  if (sharedBrowser?.isConnected()) return sharedBrowser;
  if (launchPromise) return launchPromise;

  launchPromise = (async () => {
    const browser = await launchBrowser();
    browser.on('disconnected', () => {
      if (sharedBrowser === browser) sharedBrowser = null;
    });
    sharedBrowser = browser;
    return browser;
  })();

  try {
    return await launchPromise;
  } finally {
    launchPromise = null;
  }
}

async function launchBrowser(): Promise<Browser> {
  const { chromium } = await import('playwright');
  return chromium.launch({
    executablePath: process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH || process.env.CHROMIUM_PATH || undefined,
    headless: HEADLESS,
    env: BASE_LAUNCH_ENV,
    args: [
      '--no-sandbox',
      '--disable-dev-shm-usage',
      '--disable-gpu',
      '--disable-setuid-sandbox',
      '--profile-directory=Default',
      '--no-first-run',
      '--no-default-browser-check',
      '--disable-search-engine-choice-screen',
      '--disable-features=ChromeWhatsNewUI,OptimizationGuideModelDownloading,MediaRouter',
      '--window-size=1600,1000',
      '--start-maximized',
      '--mute-audio',
    ],
  });
}

function pressurePayload() {
  const total = os.totalmem();
  const free = os.freemem();
  const memory = Math.round(((total - free) / Math.max(1, total)) * 100);
  const cpu = cpuPercent();
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
      reuseBrowser: REUSE_BROWSER,
    },
  };
}

function capacityPayload() {
  return {
    ok: true,
    mode: 'next-api-playwright-lite',
    cdp: false,
    reuseBrowser: REUSE_BROWSER,
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
