import { afterEach, describe, expect, it } from 'vitest';
import { promises as fs } from 'node:fs';
import * as os from 'node:os';
import * as path from 'node:path';
import { loadDotenvFromDir } from './dotenv.js';

const ORIGINAL_ENV = { ...process.env };

async function withTmpDir<T>(fn: (dir: string) => Promise<T>): Promise<T> {
  const tmpDir = await fs.mkdtemp(path.join(os.tmpdir(), 'lemon-dotenv-'));
  try {
    return await fn(tmpDir);
  } finally {
    await fs.rm(tmpDir, { recursive: true, force: true });
  }
}

afterEach(() => {
  process.env = { ...ORIGINAL_ENV };
});

describe('loadDotenvFromDir', () => {
  it('loads values from .env', async () => {
    await withTmpDir(async (tmpDir) => {
      await fs.writeFile(
        path.join(tmpDir, '.env'),
        [
          'DOTENV_SIMPLE=hello',
          'DOTENV_SPACED = world',
          'DOTENV_QUOTED="hello there"',
          "DOTENV_SINGLE='single value'",
          'DOTENV_COMMENTED=abc # comment',
          '',
        ].join('\n'),
        'utf-8'
      );

      loadDotenvFromDir(tmpDir);

      expect(process.env.DOTENV_SIMPLE).toBe('hello');
      expect(process.env.DOTENV_SPACED).toBe('world');
      expect(process.env.DOTENV_QUOTED).toBe('hello there');
      expect(process.env.DOTENV_SINGLE).toBe('single value');
      expect(process.env.DOTENV_COMMENTED).toBe('abc');
    });
  });

  it('supports export prefix and preserves existing env values', async () => {
    await withTmpDir(async (tmpDir) => {
      await fs.writeFile(
        path.join(tmpDir, '.env'),
        [
          'export DOTENV_EXPORTED=from_export',
          'DOTENV_EXISTING=from_file',
          '',
        ].join('\n'),
        'utf-8'
      );

      process.env.DOTENV_EXISTING = 'already_set';
      loadDotenvFromDir(tmpDir);

      expect(process.env.DOTENV_EXPORTED).toBe('from_export');
      expect(process.env.DOTENV_EXISTING).toBe('already_set');
    });
  });

  it('can override existing env values when override=true', async () => {
    await withTmpDir(async (tmpDir) => {
      await fs.writeFile(path.join(tmpDir, '.env'), 'DOTENV_EXISTING=from_file\n', 'utf-8');

      process.env.DOTENV_EXISTING = 'already_set';
      loadDotenvFromDir(tmpDir, { override: true });

      expect(process.env.DOTENV_EXISTING).toBe('from_file');
    });
  });
});
