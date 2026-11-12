import { resolve } from 'node:path';

// Bun's mock.restore() does not undo mock.module() replacements or cached imports.
// Each file needs its own module registry and DOM globals, not just fresh spies.
const cwd = resolve(import.meta.dir, '..');
const files = [...new Bun.Glob('**/*.test.{ts,tsx}').scanSync({ cwd: resolve(cwd, 'test'), onlyFiles: true })].sort();
if (files.length === 0) {
  console.error('No web test files found.');
  process.exit(1);
}
console.log(`Running ${files.length} web test files in isolated Bun processes.`);
for (const file of files) {
  const result = Bun.spawnSync([process.execPath, 'test', `./test/${file}`, ...Bun.argv.slice(2)], {
    cwd, stdin: 'inherit', stdout: 'inherit', stderr: 'inherit',
  });
  if (result.exitCode !== 0 || result.signalCode) process.exit(result.exitCode || 1);
}
