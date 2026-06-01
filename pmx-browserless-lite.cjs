const http = require('http');
const os = require('os');
const path = require('path');
const { URL } = require('url');

const TOKEN = process.env.BROWSERLESS_TOKEN || process.env.TOKEN || '';
const PORT = Number(process.env.PORT || 3000);
const CONCURRENT = positiveInt(process.env.CONCURRENT, 1);
const QUEUED = positiveInt(process.env.QUEUED, 20);
const DEFAULT_TIMEOUT = positiveInt(process.env.DEFAULT_TIMEOUT || process.env.TIMEOUT, 300000);
const MAX_SLEEP_MS = positiveInt(process.env.MAX_SLEEP_MS, 600000);
const WINDOW_WIDTH = positiveInt(process.env.PMX_BROWSERLESS_WINDOW_WIDTH, 1920);
const WINDOW_HEIGHT = positiveInt(process.env.PMX_BROWSERLESS_WINDOW_HEIGHT, 1080);
const IS_FIREBASE_STUDIO = process.env.PMX_BROWSERLESS_FIREBASE_STUDIO === '1';
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
];

let active = 0;
let rejected = 0;
const waiters = [];
const pageOwner = new WeakMap();
let lastCpuSample = readCpuSample();

function positiveInt(value, fallback) {
  const parsed = Number.parseInt(String(value || ''), 10);
  return Number.isFinite(parsed) && parsed > 0 ? parsed : fallback;
}

function snapshotProtectedEnv() {
  const snapshot = {};
  for (const key of PROTECTED_ENV_KEYS) {
    if (process.env[key] !== undefined) snapshot[key] = process.env[key];
  }
  return snapshot;
}

function restoreProtectedEnv(snapshot) {
  for (const key of PROTECTED_ENV_KEYS) {
    if (snapshot[key] === undefined) {
      delete process.env[key];
    } else {
      process.env[key] = snapshot[key];
    }
  }
}

function proxyFromContext(context) {
  const raw = context && typeof context === 'object'
    ? (context.browserlessProxy || context.proxy || context.proxyUrl)
    : null;
  if (!raw) return null;

  let server = '';
  let username = '';
  let password = '';

  if (typeof raw === 'string') {
    server = raw.trim();
  } else if (raw && typeof raw === 'object') {
    server = String(raw.server || raw.url || '').trim();
    username = String(raw.username || '').trim();
    password = String(raw.password || '');
  }

  if (!server) return null;
  let parsed;
  try {
    parsed = new URL(server);
  } catch {
    throw new Error('Invalid proxy URL');
  }
  if (!['http:', 'https:', 'socks4:', 'socks5:'].includes(parsed.protocol)) {
    throw new Error('Unsupported proxy protocol');
  }

  const proxy = {
    server: `${parsed.protocol}//${parsed.hostname}${parsed.port ? `:${parsed.port}` : ''}`,
  };
  const parsedUsername = decodeURIComponent(parsed.username || '');
  const parsedPassword = decodeURIComponent(parsed.password || '');
  if (username || parsedUsername) proxy.username = username || parsedUsername;
  if (password || parsedPassword) proxy.password = password || parsedPassword;
  return proxy;
}

function readCpuSample() {
  let idle = 0;
  let total = 0;
  for (const cpu of os.cpus()) {
    const times = cpu.times || {};
    idle += times.idle || 0;
    total += (times.user || 0) + (times.nice || 0) + (times.sys || 0) + (times.irq || 0) + (times.idle || 0);
  }
  return { idle, total };
}

function cpuPercent() {
  const current = readCpuSample();
  const previous = lastCpuSample;
  lastCpuSample = current;

  const totalDelta = current.total - previous.total;
  const idleDelta = current.idle - previous.idle;
  if (totalDelta > 0) {
    const busy = 1 - (idleDelta / totalDelta);
    return Math.max(0, Math.min(100, Math.round(busy * 100)));
  }

  const load = os.loadavg()[0] || 0;
  return Math.max(0, Math.min(100, Math.round((load / Math.max(1, os.cpus().length)) * 100)));
}

function sendJson(res, status, payload) {
  res.writeHead(status, {
    'content-type': 'application/json; charset=utf-8',
    'cache-control': 'no-store',
  });
  res.end(JSON.stringify(payload));
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    let body = '';
    req.on('data', chunk => {
      body += chunk;
      if (body.length > 20_000_000) reject(new Error('Body too large'));
    });
    req.on('end', () => resolve(body));
    req.on('error', reject);
  });
}

function acquire(timeoutMs) {
  if (active < CONCURRENT) {
    active += 1;
    return Promise.resolve(true);
  }
  if (waiters.length >= QUEUED) {
    rejected += 1;
    return Promise.resolve(false);
  }
  return new Promise(resolve => {
    const waiter = { resolve, timer: null };
    waiter.timer = setTimeout(() => {
      const index = waiters.indexOf(waiter);
      if (index >= 0) waiters.splice(index, 1);
      rejected += 1;
      resolve(false);
    }, timeoutMs);
    waiters.push(waiter);
  });
}

function release() {
  active = Math.max(0, active - 1);
  const waiter = waiters.shift();
  if (!waiter) return;
  clearTimeout(waiter.timer);
  active += 1;
  waiter.resolve(true);
}

function compile(code) {
  const source = String(code || '').trim();
  if (!source) throw new Error('Missing code');
  if (source.startsWith('export default')) {
    return new Function(`${source.replace(/^export\s+default\s+/, 'return ')};`)();
  }
  if (source.includes('module.exports')) {
    const module = { exports: undefined };
    new Function('module', 'exports', source)(module, module.exports);
    return module.exports;
  }
  return new Function(`return (${source});`)();
}

function createTimeout(timeoutMs) {
  return new Promise((_, reject) => {
    setTimeout(() => reject(new Error(`Timeout after ${timeoutMs}ms`)), timeoutMs);
  });
}

function sleep(ms) {
  return new Promise(resolve => setTimeout(resolve, ms));
}

async function bounded(task, timeoutMs) {
  let timer;
  try {
    return await Promise.race([
      task,
      new Promise(resolve => {
        timer = setTimeout(() => resolve(undefined), timeoutMs);
      }),
    ]);
  } finally {
    if (timer) clearTimeout(timer);
  }
}

function puppeteerCompatiblePage(page) {
  const originalEvaluate = page.evaluate.bind(page);
  page.evaluate = async (fn, ...args) => {
    if (args.length <= 1) return originalEvaluate(fn, args[0]);
    if (typeof fn !== 'function') return originalEvaluate(fn, args[0]);
    return originalEvaluate(({ source, values }) => {
      const pageFn = (0, eval)('(' + source + ')');
      return pageFn(...values);
    }, { source: fn.toString(), values: args });
  };

  if (typeof page.setUserAgent !== 'function') {
    page.setUserAgent = async (userAgent) => {
      if (typeof page.setExtraHTTPHeaders === 'function') {
        await page.setExtraHTTPHeaders({ 'User-Agent': userAgent });
      }
      if (typeof page.addInitScript === 'function') {
        await page.addInitScript((ua) => {
          Object.defineProperty(navigator, 'userAgent', { get: () => ua });
        }, userAgent);
      }
    };
  }

  if (typeof page.setViewport !== 'function') {
    page.setViewport = async (viewport) => {
      if (viewport && viewport.width && viewport.height) {
        await page.setViewportSize({ width: viewport.width, height: viewport.height });
      }
    };
  }

  if (typeof page.evaluateOnNewDocument !== 'function') {
    page.evaluateOnNewDocument = async (fn, ...args) => {
      if (args.length <= 1) {
        await page.addInitScript(fn, args[0]);
        return;
      }
      await page.addInitScript(({ source, values }) => {
        const pageFn = (0, eval)('(' + source + ')');
        return pageFn(...values);
      }, { source: fn.toString(), values: args });
    };
  }

  if (typeof page.waitForTimeout !== 'function') {
    page.waitForTimeout = (ms) => new Promise(resolve => setTimeout(resolve, ms));
  }

  const originalGoto = page.goto.bind(page);
  page.goto = (url, options) => {
    const waitUntil = options && options.waitUntil;
    const normalized = waitUntil === 'networkidle2' || waitUntil === 'networkidle0'
      ? 'networkidle'
      : waitUntil;
    return originalGoto(url, { ...(options || {}), waitUntil: normalized });
  };

  const requestHandlers = [];
  const originalOn = page.on.bind(page);
  page.on = (event, handler) => {
    if (event === 'request') {
      requestHandlers.push(handler);
      return page;
    }
    return originalOn(event, handler);
  };

  page.setRequestInterception = async (enabled) => {
    if (!enabled) return;
    await page.route('**/*', async (route) => {
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

async function closeExtraPages(context, keepPage) {
  if (!context || typeof context.pages !== 'function') return;
  const pages = context.pages();
  if (pages.length <= 1) return;
  const newest = pages[pages.length - 1];
  const keep = keepPage || newest;
  for (const page of pages) {
    if (page === keep) continue;
    await page.close().catch(() => {});
  }
  if (keep) pageOwner.set(context, keep);
}

async function runFunction(code, context, timeoutMs) {
  const fn = compile(code);
  if (typeof fn !== 'function') throw new Error('Browserless code did not export a function');
  const playwright = await import('playwright');
  const chromium = playwright.chromium || (playwright.default && playwright.default.chromium);
  if (!chromium) throw new Error('Playwright chromium is unavailable');

  const envSnapshot = snapshotProtectedEnv();
  let browser;
  let browserContext;
  let timedOut = false;
  let timeoutTimer;
  const work = (async () => {
    const headless = !/^(0|false|no)$/i.test(String(process.env.PMX_BROWSERLESS_HEADLESS || process.env.HEADLESS || 'true'));
    const proxy = proxyFromContext(context);
    const commonOptions = {
      executablePath: process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH || process.env.CHROMIUM_PATH || undefined,
      headless,
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
        `--window-size=${WINDOW_WIDTH},${WINDOW_HEIGHT}`,
        '--window-position=0,0',
        '--start-maximized',
      ],
      env: BASE_LAUNCH_ENV,
    };
    const userDataDir = process.env.PMX_BROWSERLESS_USER_DATA_DIR || path.join(os.tmpdir(), 'pmx-browserless-profile');
    if (headless || IS_FIREBASE_STUDIO) {
      browser = await chromium.launch(commonOptions);
      browserContext = await browser.newContext({ ignoreHTTPSErrors: true, viewport: { width: 1600, height: 1000 }, ...(proxy ? { proxy } : {}) });
    } else {
      browserContext = await chromium.launchPersistentContext(userDataDir, { ...commonOptions, ignoreHTTPSErrors: true, viewport: null, ...(proxy ? { proxy } : {}) });
    }
    browserContext.on?.('page', async (newPage) => {
      try {
        const previous = pageOwner.get(browserContext);
        await newPage.waitForLoadState?.('domcontentloaded', { timeout: 5000 }).catch(() => {});
        if (previous && previous !== newPage && !previous.isClosed?.()) {
          const nextUrl = newPage.url();
          if (nextUrl && nextUrl !== 'about:blank') {
            await previous.goto(nextUrl, { waitUntil: 'domcontentloaded', timeout: 15000 }).catch(() => {});
          }
          await newPage.close().catch(() => {});
          await closeExtraPages(browserContext, previous);
          return;
        }
        pageOwner.set(browserContext, newPage);
        await closeExtraPages(browserContext, newPage);
      } catch (_) {}
    });
    const page = puppeteerCompatiblePage(await browserContext.newPage());
    pageOwner.set(browserContext, page);
    return fn({ page, context: context || {}, browser: browser || browserContext });
  })();
  work.catch(() => {});

  try {
    timeoutTimer = setTimeout(() => {
      timedOut = true;
      const contextToClose = browserContext;
      if (contextToClose) bounded(contextToClose.close().catch(() => {}), 2500).catch(() => {});
      if (browser) bounded(browser.close().catch(() => {}), 2500).catch(() => {});
    }, timeoutMs);
    return await Promise.race([work, createTimeout(timeoutMs)]);
  } finally {
    if (timeoutTimer) clearTimeout(timeoutTimer);
    if (browserContext && !timedOut) {
      await bounded(closeExtraPages(browserContext, pageOwner.get(browserContext)).catch(() => {}), 2000);
    }
    if (browserContext) await bounded(browserContext.close().catch(() => {}), 3000);
    if (browser) await bounded(browser.close().catch(() => {}), 3000);
    restoreProtectedEnv(envSnapshot);
    if (timedOut) await sleep(25);
  }
}

function pressurePayload() {
  const total = os.totalmem();
  const free = os.freemem();
  const memory = Math.round(((total - free) / Math.max(1, total)) * 100);
  const cpu = cpuPercent();
  return {
    pressure: {
      cpu,
      date: Date.now(),
      isAvailable: active < CONCURRENT && waiters.length < QUEUED,
      maxConcurrent: CONCURRENT,
      maxQueued: QUEUED,
      memory,
      message: '',
      queued: waiters.length,
      reason: '',
      recentlyRejected: rejected,
      running: active,
      hostCpu: cpu,
      hostMemory: memory,
      mode: 'playwright-lite',
      cdp: false,
    },
  };
}

function capacityPayload() {
  return {
    ok: true,
    mode: 'playwright-lite',
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

function authorized(url) {
  if (!TOKEN) return true;
  return url.searchParams.get('token') === TOKEN;
}

http.createServer(async (req, res) => {
  try {
    const url = new URL(req.url, `http://${req.headers.host}`);
    if (!authorized(url)) return sendJson(res, 401, { error: 'Invalid token' });
    const apiAction = url.pathname === '/api/browserless' ? (url.searchParams.get('action') || 'health') : null;

    if (req.method === 'GET' && (url.pathname === '/health' || url.pathname === '/' || (apiAction === 'health'))) {
      return sendJson(res, 200, { ok: true, mode: 'playwright-lite' });
    }

    if (req.method === 'GET' && (url.pathname === '/pressure' || apiAction === 'pressure')) {
      return sendJson(res, 200, pressurePayload());
    }

    if (req.method === 'GET' && (url.pathname === '/capacity' || apiAction === 'capacity')) {
      return sendJson(res, 200, capacityPayload());
    }

    if (req.method === 'GET' && url.pathname === '/json/version') {
      return sendJson(res, 501, {
        error: 'CDP is not exposed by playwright-lite. Use Docker Browserless for human captcha live sessions.',
        mode: 'playwright-lite',
        cdp: false,
      });
    }

    if (req.method === 'GET' && url.pathname === '/sleep') {
      const ms = Math.min(Number(url.searchParams.get('ms') || 0), MAX_SLEEP_MS);
      await new Promise(resolve => setTimeout(resolve, ms));
      return sendJson(res, 200, { ok: true, sleptMs: ms });
    }

    if (req.method === 'POST' && (url.pathname === '/chromium/function' || url.pathname === '/function' || apiAction === 'function')) {
      const timeoutMs = positiveInt(url.searchParams.get('timeout'), DEFAULT_TIMEOUT);
      const slot = await acquire(timeoutMs);
      if (!slot) return sendJson(res, 429, { error: 'Queue full or acquire timeout' });
      let released = false;
      const safeRelease = () => {
        if (released) return;
        released = true;
        release();
      };
      const leaseTimer = setTimeout(safeRelease, timeoutMs + 15000);
      try {
        const body = await readBody(req);
        const payload = body ? JSON.parse(body) : {};
        const data = await runFunction(payload.code, payload.context || {}, timeoutMs);
        return sendJson(res, 200, { data });
      } finally {
        clearTimeout(leaseTimer);
        safeRelease();
      }
    }

    return sendJson(res, 404, { error: 'Not found', mode: 'playwright-lite' });
  } catch (error) {
    return sendJson(res, 500, { error: error instanceof Error ? error.message : String(error) });
  }
}).listen(PORT, '0.0.0.0', () => {
  console.log(`PMX Browserless Lite listening on :${PORT}`);
  console.log(`mode=playwright-lite concurrent=${CONCURRENT} queued=${QUEUED}`);
});
