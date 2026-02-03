import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { promises as fs } from 'fs';
import * as os from 'os';
import * as path from 'path';

const ORIGINAL_ENV = { ...process.env };

function resetEnv() {
  process.env = { ...ORIGINAL_ENV };
  const keys = [
    'LEMON_DEFAULT_PROVIDER',
    'LEMON_DEFAULT_MODEL',
    'LEMON_THEME',
    'LEMON_DEBUG',
    'ANTHROPIC_BASE_URL',
    'OPENAI_BASE_URL',
    'KIMI_BASE_URL',
    'GOOGLE_BASE_URL',
    'ANTHROPIC_API_KEY',
    'OPENAI_API_KEY',
    'KIMI_API_KEY',
    'GOOGLE_API_KEY'
  ];
  for (const key of keys) {
    delete process.env[key];
  }
}

async function writeConfig(tmpDir: string, config: Record<string, unknown>) {
  const configDir = path.join(tmpDir, '.lemon');
  await fs.mkdir(configDir, { recursive: true });
  await fs.writeFile(path.join(configDir, 'config.json'), JSON.stringify(config, null, 2), 'utf-8');
}

describe('config helpers', () => {
  beforeEach(() => {
    resetEnv();
    vi.resetModules();
    vi.clearAllMocks();
  });

  afterEach(() => {
    resetEnv();
    vi.resetModules();
    vi.clearAllMocks();
  });

  it('parses provider:model specs', () => {
    return import('./config.js').then(({ parseModelSpec }) => {
      expect(parseModelSpec('openai:gpt-4')).toEqual({ provider: 'openai', model: 'gpt-4' });
      expect(parseModelSpec('anthropic:claude:sonnet')).toEqual({ provider: 'anthropic', model: 'claude:sonnet' });
      expect(parseModelSpec('gpt-4')).toEqual({ model: 'gpt-4' });
      expect(parseModelSpec(undefined)).toEqual({});
    });
  });

  it('uses config debug when env is unset', async () => {
    const tmpDir = await fs.mkdtemp(path.join(os.tmpdir(), 'lemon-config-'));
    process.env.HOME = tmpDir;
    vi.doMock('os', async (importOriginal) => {
      const actual = await importOriginal<typeof os>();
      return { ...actual, homedir: () => tmpDir };
    });

    await writeConfig(tmpDir, {
      default_provider: 'anthropic',
      default_model: 'claude-sonnet-4-20250514',
      providers: {},
      tui: { theme: 'lemon', debug: true }
    });

    const { resolveConfig } = await import('./config.js');
    const resolved = resolveConfig();
    expect(resolved.debug).toBe(true);
  });

  it('does not apply ANTHROPIC_BASE_URL to non-anthropic providers', async () => {
    const tmpDir = await fs.mkdtemp(path.join(os.tmpdir(), 'lemon-config-'));
    process.env.HOME = tmpDir;
    vi.doMock('os', async (importOriginal) => {
      const actual = await importOriginal<typeof os>();
      return { ...actual, homedir: () => tmpDir };
    });
    process.env.ANTHROPIC_BASE_URL = 'https://anthropic.example';

    await writeConfig(tmpDir, {
      default_provider: 'openai',
      default_model: 'gpt-4o',
      providers: {
        openai: { base_url: 'https://openai.example' }
      },
      tui: { theme: 'lemon', debug: false }
    });

    const { resolveConfig } = await import('./config.js');
    const resolved = resolveConfig();
    expect(resolved.provider).toBe('openai');
    expect(resolved.baseUrl).toBe('https://openai.example');
  });

  it('applies ANTHROPIC_BASE_URL for anthropic when set', async () => {
    const tmpDir = await fs.mkdtemp(path.join(os.tmpdir(), 'lemon-config-'));
    process.env.HOME = tmpDir;
    vi.doMock('os', async (importOriginal) => {
      const actual = await importOriginal<typeof os>();
      return { ...actual, homedir: () => tmpDir };
    });
    process.env.ANTHROPIC_BASE_URL = 'https://anthropic.example';

    await writeConfig(tmpDir, {
      default_provider: 'anthropic',
      default_model: 'claude-sonnet-4-20250514',
      providers: {},
      tui: { theme: 'lemon', debug: false }
    });

    const { resolveConfig } = await import('./config.js');
    const resolved = resolveConfig();
    expect(resolved.provider).toBe('anthropic');
    expect(resolved.baseUrl).toBe('https://anthropic.example');
  });
});
