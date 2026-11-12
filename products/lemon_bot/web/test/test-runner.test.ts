import { afterEach, expect, test } from 'bun:test';
import { copyFileSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';

const directories: string[] = [];
afterEach(() => { for (const directory of directories.splice(0)) rmSync(directory, { recursive: true, force: true }); });
function fixture(files: Record<string, string>) {
  const cwd = mkdtempSync(join(tmpdir(), 'lemon-web-tests-'));
  directories.push(cwd);
  mkdirSync(join(cwd, 'scripts'));
  mkdirSync(join(cwd, 'test'));
  copyFileSync(resolve(import.meta.dir, '../scripts/test.ts'), join(cwd, 'scripts/test.ts'));
  for (const [file, content] of Object.entries(files)) {
    mkdirSync(join(cwd, 'test', file, '..'), { recursive: true });
    writeFileSync(join(cwd, 'test', file), content);
  }
  return Bun.spawnSync([process.execPath, 'scripts/test.ts'], { cwd, stdout: 'pipe', stderr: 'pipe' });
}

test('runner discovers nested TS/TSX suites and isolates module mocks and globals', () => {
  const result = fixture({
    'value.ts': 'export const value = "real";',
    'a.test.ts': `import { expect, mock, test } from 'bun:test';
      mock.module('./value', () => ({ value: 'mock' }));
      globalThis.leaked = true;
      // Static imports cannot probe a module loaded after mock.module installs its replacement.
      const { value } = await import('./value');
      test('first suite', () => expect(value).toBe('mock'));`,
    'nested/b.test.tsx': `import { expect, test } from 'bun:test';
      import { value } from '../value';
      test('second suite', () => { expect(value).toBe('real'); expect(globalThis.leaked).toBeUndefined(); });`,
  });
  expect(result.exitCode).toBe(0);
  expect(result.stdout.toString()).toContain('Running 2 web test files');
  expect(result.stderr.toString().match(/ 1 pass/g)).toHaveLength(2);
});

test('runner fails the lane when a suite fails instead of running later suites', () => {
  const result = fixture({
    'a.test.ts': `import { expect, test } from 'bun:test'; test('broken suite', () => expect(1).toBe(2));`,
    'b.test.ts': `console.log('SHOULD_NOT_RUN');`,
  });
  expect(result.exitCode).not.toBe(0);
  expect(result.stderr.toString()).toContain('broken suite');
  expect(result.stdout.toString()).not.toContain('SHOULD_NOT_RUN');
});

test('runner refuses an empty suite', () => {
  const result = fixture({});
  expect(result.exitCode).toBe(1);
  expect(result.stderr.toString()).toContain('No web test files found');
});
