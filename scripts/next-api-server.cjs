const { spawn } = require('node:child_process');

const port = String(process.env.PORT || '3000');
const command = 'npx';
const child = spawn(command, ['next', 'dev', '-H', '0.0.0.0', '-p', port], {
  cwd: process.cwd(),
  env: process.env,
  stdio: 'inherit',
  shell: process.platform === 'win32',
});

const forward = signal => {
  if (!child.killed) child.kill(signal);
};

process.on('SIGINT', () => forward('SIGINT'));
process.on('SIGTERM', () => forward('SIGTERM'));

child.on('exit', (code, signal) => {
  if (signal) process.kill(process.pid, signal);
  process.exit(code || 0);
});

child.on('error', error => {
  console.error(error);
  process.exit(1);
});
