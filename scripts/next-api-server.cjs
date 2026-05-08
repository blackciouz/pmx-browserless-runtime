const { spawn } = require('node:child_process');
const fs = require('node:fs');
const path = require('node:path');

const port = String(process.env.PORT || '3000');
const serverMode = String(process.env.PMX_NEXT_SERVER_MODE || (process.env.PMX_BROWSERLESS_FIREBASE_STUDIO === '1' ? 'start' : 'dev'));
const nextBin = path.join(process.cwd(), 'node_modules', 'next', 'dist', 'bin', 'next');
const nextRequireHook = path.join(process.cwd(), 'node_modules', 'next', 'dist', 'server', 'require-hook.js');
const buildIdFile = path.join(process.cwd(), '.next', 'BUILD_ID');

try {
  fs.accessSync(nextBin);
  fs.accessSync(nextRequireHook);
} catch {
  console.error('Local Next.js install is missing required files.');
  console.error(`Checked: ${nextBin}`);
  console.error(`Checked: ${nextRequireHook}`);
  console.error('Run: npm install --no-audit --no-fund');
  console.error('If it still fails: rm -rf node_modules/next node_modules/react node_modules/react-dom node_modules/playwright && npm install --no-audit --no-fund');
  process.exit(1);
}

function runNext(args, label) {
  console.error(`[pmx-browserless] ${label}: next ${args.join(' ')}`);
  const child = spawn(process.execPath, [nextBin, ...args], {
    cwd: process.cwd(),
    env: {
      ...process.env,
      NEXT_TELEMETRY_DISABLED: '1',
    },
    stdio: 'inherit',
    shell: false,
  });

  return child;
}

async function buildIfNeeded() {
  if (serverMode !== 'start') return;
  if (process.env.PMX_NEXT_FORCE_BUILD !== '1' && fs.existsSync(buildIdFile)) return;

  await new Promise((resolve, reject) => {
    const build = runNext(['build'], 'building production runtime');
    build.on('exit', (code, signal) => {
      if (code === 0) {
        resolve();
        return;
      }
      reject(new Error(`[pmx-browserless] next build failed code=${code ?? ''} signal=${signal ?? ''}`));
    });
    build.on('error', reject);
  });
}

const args = serverMode === 'start'
  ? ['start', '-H', '0.0.0.0', '-p', port]
  : ['dev', '--webpack', '-H', '0.0.0.0', '-p', port];

buildIfNeeded().then(() => {
  const child = runNext(args, serverMode === 'start' ? 'starting production runtime' : 'starting dev runtime');

  const forward = signal => {
    if (!child.killed) child.kill(signal);
  };

  process.on('SIGINT', () => forward('SIGINT'));
  process.on('SIGTERM', () => forward('SIGTERM'));

  child.on('exit', (code, signal) => {
    console.error(`[pmx-browserless] Next ${serverMode} server exited code=${code ?? ''} signal=${signal ?? ''}`);
    if (signal) process.kill(process.pid, signal);
    process.exit(code || 0);
  });

  child.on('error', error => {
    console.error(error);
    process.exit(1);
  });
}).catch(error => {
  console.error(error instanceof Error ? error.message : String(error));
  process.exit(1);
});
