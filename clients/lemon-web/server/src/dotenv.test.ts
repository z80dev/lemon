import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { describe, expect, it, beforeEach, afterEach } from 'vitest';
import { loadDotenvFromDir } from './dotenv.js';

describe('loadDotenvFromDir', () => {
  const originalEnv = process.env;

  beforeEach(() => {
    process.env = { ...originalEnv };
  });

  afterEach(() => {
    process.env = { ...originalEnv };
  });

  function withTempEnvFile(content: string, fn: (dir: string) => void): void {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'lemon-web-server-env-'));
    fs.writeFileSync(path.join(dir, '.env'), content);

    try {
      fn(dir);
    } finally {
      fs.rmSync(dir, { recursive: true, force: true });
    }
  }

  it('loads supported .env formats and ignores comments/invalid keys', () => {
    withTempEnvFile(
      [
        '# top comment',
        'PLAIN=value',
        'SPACED= hello world  ',
        'DOUBLE="line1\\nline2"',
        "SINGLE='literal # not comment'",
        'INLINE=abc # comment',
        'export EXPORTED=ok',
        'INVALID-KEY=ignored',
      ].join('\n'),
      (dir) => {
        loadDotenvFromDir(dir);
      }
    );

    expect(process.env.PLAIN).toBe('value');
    expect(process.env.SPACED).toBe('hello world');
    expect(process.env.DOUBLE).toBe('line1\nline2');
    expect(process.env.SINGLE).toBe('literal # not comment');
    expect(process.env.INLINE).toBe('abc');
    expect(process.env.EXPORTED).toBe('ok');
    expect(process.env['INVALID-KEY']).toBeUndefined();
  });

  it('does not overwrite existing values by default', () => {
    process.env.KEEP = 'original';

    withTempEnvFile('KEEP=override\nNEW_KEY=new', (dir) => {
      loadDotenvFromDir(dir);
    });

    expect(process.env.KEEP).toBe('original');
    expect(process.env.NEW_KEY).toBe('new');
  });

  it('overwrites existing values when override is true', () => {
    process.env.KEEP = 'original';

    withTempEnvFile('KEEP=override', (dir) => {
      loadDotenvFromDir(dir, { override: true });
    });

    expect(process.env.KEEP).toBe('override');
  });

  it('is a no-op when .env is missing', () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'lemon-web-server-env-missing-'));

    try {
      loadDotenvFromDir(dir);
      expect(process.env).toBeDefined();
    } finally {
      fs.rmSync(dir, { recursive: true, force: true });
    }
  });
});
