import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { promises as fs } from 'fs';
import * as fsSync from 'fs';
import * as os from 'os';
import * as path from 'path';
import * as toml from '@iarna/toml';

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
  await fs.writeFile(
    path.join(configDir, 'config.toml'),
    toml.stringify(config as toml.JsonMap),
    'utf-8'
  );
}

async function writeProjectConfig(projectDir: string, config: Record<string, unknown>) {
  const configDir = path.join(projectDir, '.lemon');
  await fs.mkdir(configDir, { recursive: true });
  await fs.writeFile(
    path.join(configDir, 'config.toml'),
    toml.stringify(config as toml.JsonMap),
    'utf-8'
  );
}

async function createTmpDir(): Promise<string> {
  return await fs.mkdtemp(path.join(os.tmpdir(), 'lemon-config-'));
}

async function cleanupTmpDir(tmpDir: string): Promise<void> {
  try {
    await fs.rm(tmpDir, { recursive: true, force: true });
  } catch {
    // Ignore cleanup errors
  }
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
      providers: {},
      agent: { default_provider: 'anthropic', default_model: 'claude-sonnet-4-20250514' },
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
      agent: { default_provider: 'openai', default_model: 'gpt-4o' },
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
      agent: { default_provider: 'anthropic', default_model: 'claude-sonnet-4-20250514' },
      providers: {},
      tui: { theme: 'lemon', debug: false }
    });

    const { resolveConfig } = await import('./config.js');
    const resolved = resolveConfig();
    expect(resolved.provider).toBe('anthropic');
    expect(resolved.baseUrl).toBe('https://anthropic.example');
  });
});

describe('parseModelSpec', () => {
  beforeEach(() => {
    vi.resetModules();
  });

  it('handles empty string', async () => {
    const { parseModelSpec } = await import('./config.js');
    expect(parseModelSpec('')).toEqual({});
  });

  it('handles model with multiple colons', async () => {
    const { parseModelSpec } = await import('./config.js');
    expect(parseModelSpec('provider:model:version:extra')).toEqual({
      provider: 'provider',
      model: 'model:version:extra'
    });
  });

  it('handles provider with empty model after colon', async () => {
    const { parseModelSpec } = await import('./config.js');
    expect(parseModelSpec('provider:')).toEqual({ provider: 'provider', model: undefined });
  });

  it('handles colon at start', async () => {
    const { parseModelSpec } = await import('./config.js');
    expect(parseModelSpec(':model')).toEqual({ provider: undefined, model: 'model' });
  });

  it('handles just a colon', async () => {
    const { parseModelSpec } = await import('./config.js');
    expect(parseModelSpec(':')).toEqual({ provider: undefined, model: undefined });
  });
});

describe('getConfigDir', () => {
  beforeEach(() => {
    vi.resetModules();
  });

  afterEach(() => {
    vi.resetModules();
  });

  it('returns path under home directory', async () => {
    const mockHome = '/mock/home';
    vi.doMock('os', async (importOriginal) => {
      const actual = await importOriginal<typeof os>();
      return { ...actual, homedir: () => mockHome };
    });

    const { getConfigDir } = await import('./config.js');
    expect(getConfigDir()).toBe(path.join(mockHome, '.lemon'));
  });

  it('uses os.homedir() for path resolution', async () => {
    const tmpDir = await createTmpDir();
    vi.doMock('os', async (importOriginal) => {
      const actual = await importOriginal<typeof os>();
      return { ...actual, homedir: () => tmpDir };
    });

    const { getConfigDir } = await import('./config.js');
    expect(getConfigDir()).toBe(path.join(tmpDir, '.lemon'));
    await cleanupTmpDir(tmpDir);
  });

  it('returns consistent path on multiple calls', async () => {
    const { getConfigDir } = await import('./config.js');
    const first = getConfigDir();
    const second = getConfigDir();
    expect(first).toBe(second);
  });
});

describe('getConfigPath', () => {
  beforeEach(() => {
    vi.resetModules();
  });

  afterEach(() => {
    vi.resetModules();
  });

  it('returns config.toml under config directory', async () => {
    const mockHome = '/mock/home';
    vi.doMock('os', async (importOriginal) => {
      const actual = await importOriginal<typeof os>();
      return { ...actual, homedir: () => mockHome };
    });

    const { getConfigPath } = await import('./config.js');
    expect(getConfigPath()).toBe(path.join(mockHome, '.lemon', 'config.toml'));
  });

  it('returns path consistent with getConfigDir', async () => {
    const { getConfigDir, getConfigPath } = await import('./config.js');
    expect(getConfigPath()).toBe(path.join(getConfigDir(), 'config.toml'));
  });
});

describe('loadConfig', () => {
  beforeEach(() => {
    resetEnv();
    vi.resetModules();
  });

  afterEach(() => {
    resetEnv();
    vi.resetModules();
  });

  it('returns defaults when config file does not exist', async () => {
    const tmpDir = await createTmpDir();
    vi.doMock('os', async (importOriginal) => {
      const actual = await importOriginal<typeof os>();
      return { ...actual, homedir: () => tmpDir };
    });

    const { loadConfig } = await import('./config.js');
    const config = await loadConfig();

    expect(config.agent?.default_provider).toBe('anthropic');
    expect(config.agent?.default_model).toBe('claude-sonnet-4-20250514');
    expect(config.tui?.theme).toBe('lemon');
    expect(config.tui?.debug).toBe(false);

    await cleanupTmpDir(tmpDir);
  });

  it('loads config from existing file', async () => {
    const tmpDir = await createTmpDir();
    vi.doMock('os', async (importOriginal) => {
      const actual = await importOriginal<typeof os>();
      return { ...actual, homedir: () => tmpDir };
    });

    await writeConfig(tmpDir, {
      agent: { default_provider: 'openai', default_model: 'gpt-4' },
      tui: { theme: 'dark', debug: true }
    });

    const { loadConfig } = await import('./config.js');
    const config = await loadConfig();

    expect(config.agent?.default_provider).toBe('openai');
    expect(config.agent?.default_model).toBe('gpt-4');
    expect(config.tui?.theme).toBe('dark');
    expect(config.tui?.debug).toBe(true);

    await cleanupTmpDir(tmpDir);
  });

  it('merges project config when cwd is provided', async () => {
    const tmpDir = await createTmpDir();
    vi.doMock('os', async (importOriginal) => {
      const actual = await importOriginal<typeof os>();
      return { ...actual, homedir: () => tmpDir };
    });

    await writeConfig(tmpDir, {
      agent: { default_provider: 'anthropic', default_model: 'claude-sonnet-4-20250514' },
      tui: { theme: 'lemon', debug: false }
    });

    const projectDir = path.join(tmpDir, 'project');
    await writeProjectConfig(projectDir, {
      agent: { default_model: 'claude-opus-4-20250514' },
      tui: { theme: 'solarized', debug: true }
    });

    const { loadConfig } = await import('./config.js');
    const config = await loadConfig(projectDir);

    expect(config.agent?.default_provider).toBe('anthropic');
    expect(config.agent?.default_model).toBe('claude-opus-4-20250514');
    expect(config.tui?.theme).toBe('solarized');
    expect(config.tui?.debug).toBe(true);

    await cleanupTmpDir(tmpDir);
  });

  it('returns defaults when config file contains invalid TOML', async () => {
    const tmpDir = await createTmpDir();
    vi.doMock('os', async (importOriginal) => {
      const actual = await importOriginal<typeof os>();
      return { ...actual, homedir: () => tmpDir };
    });

    const configDir = path.join(tmpDir, '.lemon');
    await fs.mkdir(configDir, { recursive: true });
    await fs.writeFile(path.join(configDir, 'config.toml'), 'not valid toml {{{', 'utf-8');

    const { loadConfig } = await import('./config.js');
    const config = await loadConfig();

    expect(config.agent?.default_provider).toBe('anthropic');
    expect(config.agent?.default_model).toBe('claude-sonnet-4-20250514');

    await cleanupTmpDir(tmpDir);
  });

  it('merges partial config with defaults', async () => {
    const tmpDir = await createTmpDir();
    vi.doMock('os', async (importOriginal) => {
      const actual = await importOriginal<typeof os>();
      return { ...actual, homedir: () => tmpDir };
    });

    // Only specify some fields
    await writeConfig(tmpDir, {
      agent: { default_provider: 'google' }
      // default_model and tui are not specified
    });

    const { loadConfig } = await import('./config.js');
    const config = await loadConfig();

    expect(config.agent?.default_provider).toBe('google');
    expect(config.agent?.default_model).toBe('claude-sonnet-4-20250514'); // Default
    expect(config.tui?.theme).toBe('lemon'); // Default

    await cleanupTmpDir(tmpDir);
  });

  it('loads provider configurations', async () => {
    const tmpDir = await createTmpDir();
    vi.doMock('os', async (importOriginal) => {
      const actual = await importOriginal<typeof os>();
      return { ...actual, homedir: () => tmpDir };
    });

    await writeConfig(tmpDir, {
      agent: { default_provider: 'anthropic' },
      providers: {
        anthropic: { api_key: 'sk-ant-xxx', base_url: 'https://custom.anthropic.com' },
        openai: { api_key: 'sk-openai-xxx' }
      }
    });

    const { loadConfig } = await import('./config.js');
    const config = await loadConfig();

    expect(config.providers?.anthropic?.api_key).toBe('sk-ant-xxx');
    expect(config.providers?.anthropic?.base_url).toBe('https://custom.anthropic.com');
    expect(config.providers?.openai?.api_key).toBe('sk-openai-xxx');

    await cleanupTmpDir(tmpDir);
  });

  it('handles empty config file', async () => {
    const tmpDir = await createTmpDir();
    vi.doMock('os', async (importOriginal) => {
      const actual = await importOriginal<typeof os>();
      return { ...actual, homedir: () => tmpDir };
    });

    const configDir = path.join(tmpDir, '.lemon');
    await fs.mkdir(configDir, { recursive: true });
    await fs.writeFile(path.join(configDir, 'config.toml'), '', 'utf-8');

    const { loadConfig } = await import('./config.js');
    const config = await loadConfig();

    // Empty file is invalid TOML, should return defaults
    expect(config.agent?.default_provider).toBe('anthropic');

    await cleanupTmpDir(tmpDir);
  });

  it('handles config file with empty object', async () => {
    const tmpDir = await createTmpDir();
    vi.doMock('os', async (importOriginal) => {
      const actual = await importOriginal<typeof os>();
      return { ...actual, homedir: () => tmpDir };
    });

    await writeConfig(tmpDir, {});

    const { loadConfig } = await import('./config.js');
    const config = await loadConfig();

    // Empty object should be merged with defaults
    expect(config.agent?.default_provider).toBe('anthropic');
    expect(config.agent?.default_model).toBe('claude-sonnet-4-20250514');

    await cleanupTmpDir(tmpDir);
  });
});

describe('loadConfigSync', () => {
  beforeEach(() => {
    resetEnv();
    vi.resetModules();
  });

  afterEach(() => {
    resetEnv();
    vi.resetModules();
  });

  it('returns defaults when config file does not exist', async () => {
    const tmpDir = await createTmpDir();
    vi.doMock('os', async (importOriginal) => {
      const actual = await importOriginal<typeof os>();
      return { ...actual, homedir: () => tmpDir };
    });

    const { loadConfigSync } = await import('./config.js');
    const config = loadConfigSync();

    expect(config.agent?.default_provider).toBe('anthropic');
    expect(config.agent?.default_model).toBe('claude-sonnet-4-20250514');

    await cleanupTmpDir(tmpDir);
  });

  it('loads config synchronously from existing file', async () => {
    const tmpDir = await createTmpDir();
    vi.doMock('os', async (importOriginal) => {
      const actual = await importOriginal<typeof os>();
      return { ...actual, homedir: () => tmpDir };
    });

    await writeConfig(tmpDir, {
      agent: { default_provider: 'kimi', default_model: 'moonshot-v1' }
    });

    const { loadConfigSync } = await import('./config.js');
    const config = loadConfigSync();

    expect(config.agent?.default_provider).toBe('kimi');
    expect(config.agent?.default_model).toBe('moonshot-v1');

    await cleanupTmpDir(tmpDir);
  });

  it('returns defaults on invalid TOML', async () => {
    const tmpDir = await createTmpDir();
    vi.doMock('os', async (importOriginal) => {
      const actual = await importOriginal<typeof os>();
      return { ...actual, homedir: () => tmpDir };
    });

    const configDir = path.join(tmpDir, '.lemon');
    await fs.mkdir(configDir, { recursive: true });
    await fs.writeFile(path.join(configDir, 'config.toml'), '{ broken toml', 'utf-8');

    const { loadConfigSync } = await import('./config.js');
    const config = loadConfigSync();

    expect(config.agent?.default_provider).toBe('anthropic');

    await cleanupTmpDir(tmpDir);
  });
});

describe('saveConfig', () => {
  beforeEach(() => {
    resetEnv();
    vi.resetModules();
  });

  afterEach(() => {
    resetEnv();
    vi.resetModules();
  });

  it('creates config directory if it does not exist', async () => {
    const tmpDir = await createTmpDir();
    vi.doMock('os', async (importOriginal) => {
      const actual = await importOriginal<typeof os>();
      return { ...actual, homedir: () => tmpDir };
    });

    const { saveConfig, getConfigDir } = await import('./config.js');

    const configDir = getConfigDir();
    // Ensure directory doesn't exist
    try {
      await fs.rm(configDir, { recursive: true });
    } catch {
      // Ignore if doesn't exist
    }

    await saveConfig({
      agent: { default_provider: 'test', default_model: 'test-model' }
    });

    const stat = await fs.stat(configDir);
    expect(stat.isDirectory()).toBe(true);

    await cleanupTmpDir(tmpDir);
  });

  it('writes config to file', async () => {
    const tmpDir = await createTmpDir();
    vi.doMock('os', async (importOriginal) => {
      const actual = await importOriginal<typeof os>();
      return { ...actual, homedir: () => tmpDir };
    });

    const { saveConfig, getConfigPath } = await import('./config.js');

    const testConfig = {
      agent: { default_provider: 'openai', default_model: 'gpt-4-turbo' },
      providers: {
        openai: { api_key: 'test-key' }
      },
      tui: { theme: 'custom', debug: true }
    };

    await saveConfig(testConfig);

    const configPath = getConfigPath();
    const content = await fs.readFile(configPath, 'utf-8');
    const parsed = toml.parse(content) as any;

    expect(parsed.agent.default_provider).toBe('openai');
    expect(parsed.agent.default_model).toBe('gpt-4-turbo');
    expect(parsed.providers.openai.api_key).toBe('test-key');
    expect(parsed.tui.theme).toBe('custom');

    await cleanupTmpDir(tmpDir);
  });

  it('overwrites existing config file', async () => {
    const tmpDir = await createTmpDir();
    vi.doMock('os', async (importOriginal) => {
      const actual = await importOriginal<typeof os>();
      return { ...actual, homedir: () => tmpDir };
    });

    await writeConfig(tmpDir, {
      agent: { default_provider: 'old', default_model: 'old-model' }
    });

    const { saveConfig, getConfigPath } = await import('./config.js');

    await saveConfig({
      agent: { default_provider: 'new', default_model: 'new-model' }
    });

    const configPath = getConfigPath();
    const content = await fs.readFile(configPath, 'utf-8');
    const parsed = toml.parse(content) as any;

    expect(parsed.agent.default_provider).toBe('new');
    expect(parsed.agent.default_model).toBe('new-model');

    await cleanupTmpDir(tmpDir);
  });

  it('writes TOML content', async () => {
    const tmpDir = await createTmpDir();
    vi.doMock('os', async (importOriginal) => {
      const actual = await importOriginal<typeof os>();
      return { ...actual, homedir: () => tmpDir };
    });

    const { saveConfig, getConfigPath } = await import('./config.js');

    await saveConfig({
      agent: { default_provider: 'test' }
    });

    const configPath = getConfigPath();
    const content = await fs.readFile(configPath, 'utf-8');

    // Check that TOML is present
    expect(content).toContain('[agent]');
    expect(content).toContain('default_provider');

    await cleanupTmpDir(tmpDir);
  });

  it('handles empty config object', async () => {
    const tmpDir = await createTmpDir();
    vi.doMock('os', async (importOriginal) => {
      const actual = await importOriginal<typeof os>();
      return { ...actual, homedir: () => tmpDir };
    });

    const { saveConfig, getConfigPath } = await import('./config.js');

    await saveConfig({});

    const configPath = getConfigPath();
    const content = await fs.readFile(configPath, 'utf-8');
    const parsed = content.trim() === '' ? {} : (toml.parse(content) as any);

    expect(parsed).toEqual({});

    await cleanupTmpDir(tmpDir);
  });
});

describe('getModelString', () => {
  beforeEach(() => {
    vi.resetModules();
  });

  it('formats provider and model correctly', async () => {
    const { getModelString } = await import('./config.js');

    const config = {
      provider: 'anthropic',
      model: 'claude-sonnet-4-20250514',
      theme: 'lemon',
      debug: false
    };

    expect(getModelString(config)).toBe('anthropic:claude-sonnet-4-20250514');
  });

  it('handles various provider names', async () => {
    const { getModelString } = await import('./config.js');

    expect(getModelString({
      provider: 'openai',
      model: 'gpt-4',
      theme: 'lemon',
      debug: false
    })).toBe('openai:gpt-4');

    expect(getModelString({
      provider: 'google',
      model: 'gemini-pro',
      theme: 'lemon',
      debug: false
    })).toBe('google:gemini-pro');

    expect(getModelString({
      provider: 'kimi',
      model: 'moonshot-v1',
      theme: 'lemon',
      debug: false
    })).toBe('kimi:moonshot-v1');
  });

  it('handles model names with colons', async () => {
    const { getModelString } = await import('./config.js');

    const config = {
      provider: 'custom',
      model: 'model:version:extra',
      theme: 'lemon',
      debug: false
    };

    expect(getModelString(config)).toBe('custom:model:version:extra');
  });

  it('handles empty strings', async () => {
    const { getModelString } = await import('./config.js');

    expect(getModelString({
      provider: '',
      model: '',
      theme: 'lemon',
      debug: false
    })).toBe(':');
  });
});

describe('saveConfigKey', () => {
  beforeEach(() => {
    resetEnv();
    vi.resetModules();
  });

  afterEach(() => {
    resetEnv();
    vi.resetModules();
  });

  it('saves a single config key while preserving others', async () => {
    const tmpDir = await createTmpDir();
    vi.doMock('os', async (importOriginal) => {
      const actual = await importOriginal<typeof os>();
      return { ...actual, homedir: () => tmpDir };
    });

    await writeConfig(tmpDir, {
      agent: { default_provider: 'anthropic', default_model: 'claude-opus' },
      tui: { theme: 'light', debug: false }
    });

    const { saveConfigKey, loadConfig } = await import('./config.js');

    await saveConfigKey('agent', { default_model: 'claude-sonnet-4-20250514' });

    const config = await loadConfig();
    expect(config.agent?.default_provider).toBe('anthropic'); // Preserved
    expect(config.agent?.default_model).toBe('claude-sonnet-4-20250514'); // Updated
    expect(config.tui?.theme).toBe('light'); // Preserved

    await cleanupTmpDir(tmpDir);
  });

  it('creates config file if it does not exist', async () => {
    const tmpDir = await createTmpDir();
    vi.doMock('os', async (importOriginal) => {
      const actual = await importOriginal<typeof os>();
      return { ...actual, homedir: () => tmpDir };
    });

    const { saveConfigKey, loadConfig } = await import('./config.js');

    await saveConfigKey('agent', { default_provider: 'openai' });

    const config = await loadConfig();
    expect(config.agent?.default_provider).toBe('openai');

    await cleanupTmpDir(tmpDir);
  });

  it('updates providers object', async () => {
    const tmpDir = await createTmpDir();
    vi.doMock('os', async (importOriginal) => {
      const actual = await importOriginal<typeof os>();
      return { ...actual, homedir: () => tmpDir };
    });

    await writeConfig(tmpDir, {
      agent: { default_provider: 'anthropic' }
    });

    const { saveConfigKey, loadConfig } = await import('./config.js');

    await saveConfigKey('providers', {
      anthropic: { api_key: 'new-key' },
      openai: { api_key: 'openai-key' }
    });

    const config = await loadConfig();
    expect(config.providers?.anthropic?.api_key).toBe('new-key');
    expect(config.providers?.openai?.api_key).toBe('openai-key');

    await cleanupTmpDir(tmpDir);
  });

  it('updates tui object entirely', async () => {
    const tmpDir = await createTmpDir();
    vi.doMock('os', async (importOriginal) => {
      const actual = await importOriginal<typeof os>();
      return { ...actual, homedir: () => tmpDir };
    });

    await writeConfig(tmpDir, {
      agent: { default_provider: 'anthropic' },
      tui: { theme: 'light', debug: false }
    });

    const { saveConfigKey, loadConfig } = await import('./config.js');

    await saveConfigKey('tui', { theme: 'dark', debug: true });

    const config = await loadConfig();
    expect(config.tui?.theme).toBe('dark');
    expect(config.tui?.debug).toBe(true);

    await cleanupTmpDir(tmpDir);
  });
});

describe('saveTUIConfigKey', () => {
  beforeEach(() => {
    resetEnv();
    vi.resetModules();
  });

  afterEach(() => {
    resetEnv();
    vi.resetModules();
  });

  it('saves a TUI config key while preserving other TUI settings', async () => {
    const tmpDir = await createTmpDir();
    vi.doMock('os', async (importOriginal) => {
      const actual = await importOriginal<typeof os>();
      return { ...actual, homedir: () => tmpDir };
    });

    await writeConfig(tmpDir, {
      agent: { default_provider: 'anthropic' },
      tui: { theme: 'light', debug: false }
    });

    const { saveTUIConfigKey, loadConfig } = await import('./config.js');

    await saveTUIConfigKey('theme', 'dark');

    const config = await loadConfig();
    expect(config.tui?.theme).toBe('dark');
    expect(config.tui?.debug).toBe(false); // Preserved

    await cleanupTmpDir(tmpDir);
  });

  it('creates tui object if it does not exist', async () => {
    const tmpDir = await createTmpDir();
    vi.doMock('os', async (importOriginal) => {
      const actual = await importOriginal<typeof os>();
      return { ...actual, homedir: () => tmpDir };
    });

    await writeConfig(tmpDir, {
      agent: { default_provider: 'anthropic' }
      // No tui field
    });

    const { saveTUIConfigKey, loadConfig } = await import('./config.js');

    await saveTUIConfigKey('debug', true);

    const config = await loadConfig();
    expect(config.tui?.debug).toBe(true);

    await cleanupTmpDir(tmpDir);
  });

  it('creates config file if it does not exist', async () => {
    const tmpDir = await createTmpDir();
    vi.doMock('os', async (importOriginal) => {
      const actual = await importOriginal<typeof os>();
      return { ...actual, homedir: () => tmpDir };
    });

    const { saveTUIConfigKey, loadConfig } = await import('./config.js');

    await saveTUIConfigKey('theme', 'monokai');

    const config = await loadConfig();
    expect(config.tui?.theme).toBe('monokai');

    await cleanupTmpDir(tmpDir);
  });

  it('preserves non-TUI config when saving TUI key', async () => {
    const tmpDir = await createTmpDir();
    vi.doMock('os', async (importOriginal) => {
      const actual = await importOriginal<typeof os>();
      return { ...actual, homedir: () => tmpDir };
    });

    await writeConfig(tmpDir, {
      agent: { default_provider: 'openai', default_model: 'gpt-4' },
      providers: { openai: { api_key: 'test' } },
      tui: { theme: 'light' }
    });

    const { saveTUIConfigKey, loadConfig } = await import('./config.js');

    await saveTUIConfigKey('debug', true);

    const config = await loadConfig();
    expect(config.agent?.default_provider).toBe('openai');
    expect(config.agent?.default_model).toBe('gpt-4');
    expect(config.providers?.openai?.api_key).toBe('test');
    expect(config.tui?.theme).toBe('light');
    expect(config.tui?.debug).toBe(true);

    await cleanupTmpDir(tmpDir);
  });
});

describe('resolveConfig', () => {
  beforeEach(() => {
    resetEnv();
    vi.resetModules();
  });

  afterEach(() => {
    resetEnv();
    vi.resetModules();
  });

  it('returns defaults when no config file exists', async () => {
    const tmpDir = await createTmpDir();
    vi.doMock('os', async (importOriginal) => {
      const actual = await importOriginal<typeof os>();
      return { ...actual, homedir: () => tmpDir };
    });

    const { resolveConfig } = await import('./config.js');
    const config = resolveConfig();

    expect(config.provider).toBe('anthropic');
    expect(config.model).toBe('claude-sonnet-4-20250514');
    expect(config.theme).toBe('lemon');
    expect(config.debug).toBe(false);

    await cleanupTmpDir(tmpDir);
  });

  it('uses project config when cwd is provided', async () => {
    const tmpDir = await createTmpDir();
    vi.doMock('os', async (importOriginal) => {
      const actual = await importOriginal<typeof os>();
      return { ...actual, homedir: () => tmpDir };
    });

    await writeConfig(tmpDir, {
      agent: { default_provider: 'anthropic', default_model: 'claude-sonnet-4-20250514' },
      tui: { theme: 'lemon', debug: false }
    });

    const projectDir = path.join(tmpDir, 'project');
    await writeProjectConfig(projectDir, {
      agent: { default_provider: 'openai', default_model: 'gpt-4o' },
      tui: { theme: 'solarized', debug: true }
    });

    const { resolveConfig } = await import('./config.js');
    const config = resolveConfig({ cwd: projectDir });

    expect(config.provider).toBe('openai');
    expect(config.model).toBe('gpt-4o');
    expect(config.theme).toBe('solarized');
    expect(config.debug).toBe(true);

    await cleanupTmpDir(tmpDir);
  });

  it('CLI args override environment variables', async () => {
    const tmpDir = await createTmpDir();
    vi.doMock('os', async (importOriginal) => {
      const actual = await importOriginal<typeof os>();
      return { ...actual, homedir: () => tmpDir };
    });

    process.env.LEMON_DEFAULT_PROVIDER = 'openai';
    process.env.LEMON_DEFAULT_MODEL = 'gpt-4';

    const { resolveConfig } = await import('./config.js');
    const config = resolveConfig({
      provider: 'anthropic',
      model: 'claude-opus'
    });

    expect(config.provider).toBe('anthropic');
    expect(config.model).toBe('claude-opus');

    await cleanupTmpDir(tmpDir);
  });

  it('environment variables override config file', async () => {
    const tmpDir = await createTmpDir();
    vi.doMock('os', async (importOriginal) => {
      const actual = await importOriginal<typeof os>();
      return { ...actual, homedir: () => tmpDir };
    });

    await writeConfig(tmpDir, {
      agent: {
        default_provider: 'anthropic',
        default_model: 'claude-sonnet-4-20250514'
      }
    });

    process.env.LEMON_DEFAULT_PROVIDER = 'google';
    process.env.LEMON_DEFAULT_MODEL = 'gemini-pro';

    const { resolveConfig } = await import('./config.js');
    const config = resolveConfig();

    expect(config.provider).toBe('google');
    expect(config.model).toBe('gemini-pro');

    await cleanupTmpDir(tmpDir);
  });

  it('uses provider-specific API key from environment', async () => {
    const tmpDir = await createTmpDir();
    vi.doMock('os', async (importOriginal) => {
      const actual = await importOriginal<typeof os>();
      return { ...actual, homedir: () => tmpDir };
    });

    await writeConfig(tmpDir, {
      agent: { default_provider: 'openai' },
      providers: {
        openai: { api_key: 'config-key' }
      }
    });

    process.env.OPENAI_API_KEY = 'env-key';

    const { resolveConfig } = await import('./config.js');
    const config = resolveConfig();

    expect(config.apiKey).toBe('env-key'); // Env takes precedence

    await cleanupTmpDir(tmpDir);
  });

  it('uses provider-specific base URL from environment', async () => {
    const tmpDir = await createTmpDir();
    vi.doMock('os', async (importOriginal) => {
      const actual = await importOriginal<typeof os>();
      return { ...actual, homedir: () => tmpDir };
    });

    await writeConfig(tmpDir, {
      agent: { default_provider: 'openai' },
      providers: {
        openai: { base_url: 'https://config.example.com' }
      }
    });

    process.env.OPENAI_BASE_URL = 'https://env.example.com';

    const { resolveConfig } = await import('./config.js');
    const config = resolveConfig();

    expect(config.baseUrl).toBe('https://env.example.com');

    await cleanupTmpDir(tmpDir);
  });

  it('handles LEMON_DEBUG=1', async () => {
    const tmpDir = await createTmpDir();
    vi.doMock('os', async (importOriginal) => {
      const actual = await importOriginal<typeof os>();
      return { ...actual, homedir: () => tmpDir };
    });

    process.env.LEMON_DEBUG = '1';

    const { resolveConfig } = await import('./config.js');
    const config = resolveConfig();

    expect(config.debug).toBe(true);

    await cleanupTmpDir(tmpDir);
  });

  it('handles LEMON_DEBUG=true', async () => {
    const tmpDir = await createTmpDir();
    vi.doMock('os', async (importOriginal) => {
      const actual = await importOriginal<typeof os>();
      return { ...actual, homedir: () => tmpDir };
    });

    process.env.LEMON_DEBUG = 'true';

    const { resolveConfig } = await import('./config.js');
    const config = resolveConfig();

    expect(config.debug).toBe(true);

    await cleanupTmpDir(tmpDir);
  });

  it('handles LEMON_DEBUG=false', async () => {
    const tmpDir = await createTmpDir();
    vi.doMock('os', async (importOriginal) => {
      const actual = await importOriginal<typeof os>();
      return { ...actual, homedir: () => tmpDir };
    });

    process.env.LEMON_DEBUG = 'false';

    const { resolveConfig } = await import('./config.js');
    const config = resolveConfig();

    expect(config.debug).toBe(false);

    await cleanupTmpDir(tmpDir);
  });

  it('handles LEMON_DEBUG=0', async () => {
    const tmpDir = await createTmpDir();
    vi.doMock('os', async (importOriginal) => {
      const actual = await importOriginal<typeof os>();
      return { ...actual, homedir: () => tmpDir };
    });

    process.env.LEMON_DEBUG = '0';

    const { resolveConfig } = await import('./config.js');
    const config = resolveConfig();

    expect(config.debug).toBe(false);

    await cleanupTmpDir(tmpDir);
  });

  it('CLI debug overrides env debug', async () => {
    const tmpDir = await createTmpDir();
    vi.doMock('os', async (importOriginal) => {
      const actual = await importOriginal<typeof os>();
      return { ...actual, homedir: () => tmpDir };
    });

    process.env.LEMON_DEBUG = 'true';

    const { resolveConfig } = await import('./config.js');
    const config = resolveConfig({ debug: false });

    expect(config.debug).toBe(false);

    await cleanupTmpDir(tmpDir);
  });

  it('uses LEMON_THEME from environment', async () => {
    const tmpDir = await createTmpDir();
    vi.doMock('os', async (importOriginal) => {
      const actual = await importOriginal<typeof os>();
      return { ...actual, homedir: () => tmpDir };
    });

    await writeConfig(tmpDir, {
      tui: { theme: 'config-theme' }
    });

    process.env.LEMON_THEME = 'env-theme';

    const { resolveConfig } = await import('./config.js');
    const config = resolveConfig();

    expect(config.theme).toBe('env-theme');

    await cleanupTmpDir(tmpDir);
  });

  it('uses CLI baseUrl when provided', async () => {
    const tmpDir = await createTmpDir();
    vi.doMock('os', async (importOriginal) => {
      const actual = await importOriginal<typeof os>();
      return { ...actual, homedir: () => tmpDir };
    });

    process.env.ANTHROPIC_BASE_URL = 'https://env.example.com';

    const { resolveConfig } = await import('./config.js');
    const config = resolveConfig({ baseUrl: 'https://cli.example.com' });

    expect(config.baseUrl).toBe('https://cli.example.com');

    await cleanupTmpDir(tmpDir);
  });

  it('handles unknown provider with uppercase env prefix', async () => {
    const tmpDir = await createTmpDir();
    vi.doMock('os', async (importOriginal) => {
      const actual = await importOriginal<typeof os>();
      return { ...actual, homedir: () => tmpDir };
    });

    process.env.CUSTOM_API_KEY = 'custom-key';
    process.env.CUSTOM_BASE_URL = 'https://custom.example.com';

    const { resolveConfig } = await import('./config.js');
    const config = resolveConfig({ provider: 'custom' });

    expect(config.apiKey).toBe('custom-key');
    expect(config.baseUrl).toBe('https://custom.example.com');

    await cleanupTmpDir(tmpDir);
  });

  it('returns undefined apiKey when not configured', async () => {
    const tmpDir = await createTmpDir();
    vi.doMock('os', async (importOriginal) => {
      const actual = await importOriginal<typeof os>();
      return { ...actual, homedir: () => tmpDir };
    });

    const { resolveConfig } = await import('./config.js');
    const config = resolveConfig();

    expect(config.apiKey).toBeUndefined();

    await cleanupTmpDir(tmpDir);
  });

  it('returns undefined baseUrl when not configured', async () => {
    const tmpDir = await createTmpDir();
    vi.doMock('os', async (importOriginal) => {
      const actual = await importOriginal<typeof os>();
      return { ...actual, homedir: () => tmpDir };
    });

    const { resolveConfig } = await import('./config.js');
    const config = resolveConfig();

    expect(config.baseUrl).toBeUndefined();

    await cleanupTmpDir(tmpDir);
  });

  it('uses api_key from config when env is not set', async () => {
    const tmpDir = await createTmpDir();
    vi.doMock('os', async (importOriginal) => {
      const actual = await importOriginal<typeof os>();
      return { ...actual, homedir: () => tmpDir };
    });

    await writeConfig(tmpDir, {
      agent: { default_provider: 'anthropic' },
      providers: {
        anthropic: { api_key: 'config-api-key' }
      }
    });

    const { resolveConfig } = await import('./config.js');
    const config = resolveConfig();

    expect(config.apiKey).toBe('config-api-key');

    await cleanupTmpDir(tmpDir);
  });

  it('uses base_url from config when env is not set', async () => {
    const tmpDir = await createTmpDir();
    vi.doMock('os', async (importOriginal) => {
      const actual = await importOriginal<typeof os>();
      return { ...actual, homedir: () => tmpDir };
    });

    await writeConfig(tmpDir, {
      agent: { default_provider: 'openai' },
      providers: {
        openai: { base_url: 'https://config.example.com' }
      }
    });

    const { resolveConfig } = await import('./config.js');
    const config = resolveConfig();

    expect(config.baseUrl).toBe('https://config.example.com');

    await cleanupTmpDir(tmpDir);
  });
});

describe('config merging (via loadConfig)', () => {
  beforeEach(() => {
    resetEnv();
    vi.resetModules();
  });

  afterEach(() => {
    resetEnv();
    vi.resetModules();
  });

  it('merges providers from config with empty defaults', async () => {
    const tmpDir = await createTmpDir();
    vi.doMock('os', async (importOriginal) => {
      const actual = await importOriginal<typeof os>();
      return { ...actual, homedir: () => tmpDir };
    });

    await writeConfig(tmpDir, {
      providers: {
        anthropic: { api_key: 'ant-key' },
        openai: { api_key: 'oai-key' }
      }
    });

    const { loadConfig } = await import('./config.js');
    const config = await loadConfig();

    expect(config.providers?.anthropic?.api_key).toBe('ant-key');
    expect(config.providers?.openai?.api_key).toBe('oai-key');

    await cleanupTmpDir(tmpDir);
  });

  it('preserves default values for unspecified fields', async () => {
    const tmpDir = await createTmpDir();
    vi.doMock('os', async (importOriginal) => {
      const actual = await importOriginal<typeof os>();
      return { ...actual, homedir: () => tmpDir };
    });

    await writeConfig(tmpDir, {
      tui: { debug: true }
      // theme not specified
    });

    const { loadConfig } = await import('./config.js');
    const config = await loadConfig();

    expect(config.tui?.debug).toBe(true);
    expect(config.tui?.theme).toBe('lemon'); // Default preserved

    await cleanupTmpDir(tmpDir);
  });

  it('overrides default_provider when specified', async () => {
    const tmpDir = await createTmpDir();
    vi.doMock('os', async (importOriginal) => {
      const actual = await importOriginal<typeof os>();
      return { ...actual, homedir: () => tmpDir };
    });

    await writeConfig(tmpDir, {
      agent: { default_provider: 'google' }
    });

    const { loadConfig } = await import('./config.js');
    const config = await loadConfig();

    expect(config.agent?.default_provider).toBe('google');
    expect(config.agent?.default_model).toBe('claude-sonnet-4-20250514'); // Default

    await cleanupTmpDir(tmpDir);
  });

});

describe('edge cases and error handling', () => {
  beforeEach(() => {
    resetEnv();
    vi.resetModules();
  });

  afterEach(() => {
    resetEnv();
    vi.resetModules();
  });

  it('handles unicode in config values', async () => {
    const tmpDir = await createTmpDir();
    vi.doMock('os', async (importOriginal) => {
      const actual = await importOriginal<typeof os>();
      return { ...actual, homedir: () => tmpDir };
    });

    await writeConfig(tmpDir, {
      tui: { theme: 'theme-\u00e9\u00e8\u00ea-unicode' }
    });

    const { loadConfig } = await import('./config.js');
    const config = await loadConfig();

    expect(config.tui?.theme).toBe('theme-\u00e9\u00e8\u00ea-unicode');

    await cleanupTmpDir(tmpDir);
  });

  it('handles very long config values', async () => {
    const tmpDir = await createTmpDir();
    vi.doMock('os', async (importOriginal) => {
      const actual = await importOriginal<typeof os>();
      return { ...actual, homedir: () => tmpDir };
    });

    const longValue = 'a'.repeat(10000);
    await writeConfig(tmpDir, {
      agent: { default_model: longValue }
    });

    const { loadConfig } = await import('./config.js');
    const config = await loadConfig();

    expect(config.agent?.default_model).toBe(longValue);
    expect(config.agent?.default_model?.length).toBe(10000);

    await cleanupTmpDir(tmpDir);
  });

  it('handles special characters in config values', async () => {
    const tmpDir = await createTmpDir();
    vi.doMock('os', async (importOriginal) => {
      const actual = await importOriginal<typeof os>();
      return { ...actual, homedir: () => tmpDir };
    });

    await writeConfig(tmpDir, {
      agent: { default_model: 'model/with\\special"chars\nand\ttabs' }
    });

    const { loadConfig } = await import('./config.js');
    const config = await loadConfig();

    expect(config.agent?.default_model).toBe('model/with\\special"chars\nand\ttabs');

    await cleanupTmpDir(tmpDir);
  });
});

describe('provider env prefix mapping', () => {
  beforeEach(() => {
    resetEnv();
    vi.resetModules();
  });

  afterEach(() => {
    resetEnv();
    vi.resetModules();
  });

  it('maps anthropic provider to ANTHROPIC prefix', async () => {
    const tmpDir = await createTmpDir();
    vi.doMock('os', async (importOriginal) => {
      const actual = await importOriginal<typeof os>();
      return { ...actual, homedir: () => tmpDir };
    });

    process.env.ANTHROPIC_API_KEY = 'anthropic-key';

    const { resolveConfig } = await import('./config.js');
    const config = resolveConfig({ provider: 'anthropic' });

    expect(config.apiKey).toBe('anthropic-key');

    await cleanupTmpDir(tmpDir);
  });

  it('maps openai provider to OPENAI prefix', async () => {
    const tmpDir = await createTmpDir();
    vi.doMock('os', async (importOriginal) => {
      const actual = await importOriginal<typeof os>();
      return { ...actual, homedir: () => tmpDir };
    });

    process.env.OPENAI_API_KEY = 'openai-key';

    const { resolveConfig } = await import('./config.js');
    const config = resolveConfig({ provider: 'openai' });

    expect(config.apiKey).toBe('openai-key');

    await cleanupTmpDir(tmpDir);
  });

  it('maps google provider to GOOGLE prefix', async () => {
    const tmpDir = await createTmpDir();
    vi.doMock('os', async (importOriginal) => {
      const actual = await importOriginal<typeof os>();
      return { ...actual, homedir: () => tmpDir };
    });

    process.env.GOOGLE_API_KEY = 'google-key';

    const { resolveConfig } = await import('./config.js');
    const config = resolveConfig({ provider: 'google' });

    expect(config.apiKey).toBe('google-key');

    await cleanupTmpDir(tmpDir);
  });

  it('maps kimi provider to KIMI prefix', async () => {
    const tmpDir = await createTmpDir();
    vi.doMock('os', async (importOriginal) => {
      const actual = await importOriginal<typeof os>();
      return { ...actual, homedir: () => tmpDir };
    });

    process.env.KIMI_API_KEY = 'kimi-key';

    const { resolveConfig } = await import('./config.js');
    const config = resolveConfig({ provider: 'kimi' });

    expect(config.apiKey).toBe('kimi-key');

    await cleanupTmpDir(tmpDir);
  });

  it('maps unknown provider to uppercase name', async () => {
    const tmpDir = await createTmpDir();
    vi.doMock('os', async (importOriginal) => {
      const actual = await importOriginal<typeof os>();
      return { ...actual, homedir: () => tmpDir };
    });

    process.env.MYCOMPANY_API_KEY = 'mycompany-key';

    const { resolveConfig } = await import('./config.js');
    const config = resolveConfig({ provider: 'mycompany' });

    expect(config.apiKey).toBe('mycompany-key');

    await cleanupTmpDir(tmpDir);
  });
});

describe('concurrent config operations', () => {
  beforeEach(() => {
    resetEnv();
    vi.resetModules();
  });

  afterEach(() => {
    resetEnv();
    vi.resetModules();
  });

  it('handles multiple concurrent loadConfig calls', async () => {
    const tmpDir = await createTmpDir();
    vi.doMock('os', async (importOriginal) => {
      const actual = await importOriginal<typeof os>();
      return { ...actual, homedir: () => tmpDir };
    });

    await writeConfig(tmpDir, {
      agent: { default_provider: 'test', default_model: 'test-model' }
    });

    const { loadConfig } = await import('./config.js');

    const results = await Promise.all([
      loadConfig(),
      loadConfig(),
      loadConfig(),
      loadConfig(),
      loadConfig()
    ]);

    for (const config of results) {
      expect(config.agent?.default_provider).toBe('test');
      expect(config.agent?.default_model).toBe('test-model');
    }

    await cleanupTmpDir(tmpDir);
  });

  it('handles saveConfig followed by loadConfig', async () => {
    const tmpDir = await createTmpDir();
    vi.doMock('os', async (importOriginal) => {
      const actual = await importOriginal<typeof os>();
      return { ...actual, homedir: () => tmpDir };
    });

    const { saveConfig, loadConfig } = await import('./config.js');

    await saveConfig({ agent: { default_provider: 'saved', default_model: 'saved-model' } });
    const config = await loadConfig();

    expect(config.agent?.default_provider).toBe('saved');
    expect(config.agent?.default_model).toBe('saved-model');

    await cleanupTmpDir(tmpDir);
  });
});
