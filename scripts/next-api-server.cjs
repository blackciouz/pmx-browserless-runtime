const { spawn } = require('node:child_process');
const path = require('node:path');

const port = String(process.env.PORT || '3000');
const nextBin = path.join(process.cwd(), 'node_modules', 'next', 'dist', 'bin', 'next');

try {
  require('node:fs').accessSync(nextBin);
} catch {
  console.error(`Missing local Next.js binary: ${nextBin}`);
  console.error('Run: npm install --no-audit --no-fund');
  process.exit(1);
}

const child = spawn(process.execPath, [nextBin, 'dev', '-H', '0.0.0.0', '-p', port], {
  cwd: process.cwd(),
  env: process.env,
  stdio: 'inherit',
  shell: false,
});

const forward = signal => {
  if (!child.killed) child.kill(signal);
};

process.on('SIGINT', () => forward('SIGINT'));
process.on('SIGTERM', () => forward('SIGTERM'));

child.on('exit', (code, signal) => {
  console.error(`[pmx-browserless] Next dev server exited code=${code ?? ''} signal=${signal ?? ''}`);
  if (signal) process.kill(process.pid, signal);
  process.exit(code || 0);
});

child.on('error', error => {
  console.error(error);
  process.exit(1);
});
