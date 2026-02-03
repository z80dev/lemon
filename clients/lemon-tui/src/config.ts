import * as fs from 'fs';
import { promises as fsPromises } from 'fs';
import * as os from 'os';
import * as path from 'path';

/**
 * Provider configuration
 */
export interface ProviderConfig {
  api_key?: string;
  base_url?: string;
}

/**
 * TUI-specific configuration
 */
export interface TUIConfig {
  theme?: string;
  debug?: boolean;
}

/**
 * Main Lemon configuration file structure (~/.lemon/config.json)
 */
export interface LemonConfig {
  default_provider?: string;
  default_model?: string;
  providers?: Record<string, ProviderConfig>;
  tui?: TUIConfig;
}

/**
 * Resolved configuration after merging config file + env vars + CLI args
 */
export interface ResolvedConfig {
  provider: string;
  model: string;
  apiKey?: string;
  baseUrl?: string;
  theme: string;
  debug: boolean;
}

export function parseModelSpec(model?: string): { provider?: string; model?: string } {
  if (!model) {
    return {};
  }
  const parts = model.split(':');
  if (parts.length >= 2) {
    const provider = parts.shift() || undefined;
    const modelId = parts.join(':') || undefined;
    return { provider, model: modelId };
  }
  return { model };
}

const DEFAULT_CONFIG: LemonConfig = {
  default_provider: 'anthropic',
  default_model: 'claude-sonnet-4-20250514',
  providers: {},
  tui: {
    theme: 'lemon',
    debug: false,
  },
};

/**
 * Get the config directory path (~/.lemon/)
 */
export function getConfigDir(): string {
  return path.join(os.homedir(), '.lemon');
}

/**
 * Get the config file path (~/.lemon/config.json)
 */
export function getConfigPath(): string {
  return path.join(getConfigDir(), 'config.json');
}

/**
 * Load config from file, returns defaults if file doesn't exist
 */
export async function loadConfig(): Promise<LemonConfig> {
  const configPath = getConfigPath();

  try {
    const content = await fsPromises.readFile(configPath, 'utf-8');
    const parsed = JSON.parse(content);
    return mergeConfig(DEFAULT_CONFIG, parsed);
  } catch {
    // Return defaults if file doesn't exist or is invalid JSON
    return { ...DEFAULT_CONFIG };
  }
}

/**
 * Load config synchronously (for startup) - returns defaults on error
 */
export function loadConfigSync(): LemonConfig {
  const configPath = getConfigPath();

  try {
    const content = fs.readFileSync(configPath, 'utf-8');
    const parsed = JSON.parse(content);
    return mergeConfig(DEFAULT_CONFIG, parsed);
  } catch {
    // Return defaults if file doesn't exist or is invalid JSON
    return { ...DEFAULT_CONFIG };
  }
}

/**
 * Save config to file, creates directory if needed
 */
export async function saveConfig(config: LemonConfig): Promise<void> {
  const configPath = getConfigPath();
  const configDir = getConfigDir();

  // Create directory if it doesn't exist
  await fsPromises.mkdir(configDir, { recursive: true });

  // Write config file
  await fsPromises.writeFile(configPath, JSON.stringify(config, null, 2), 'utf-8');
}

/**
 * Deep merge two config objects
 */
function mergeConfig(base: LemonConfig, override: Partial<LemonConfig>): LemonConfig {
  return {
    default_provider: override.default_provider ?? base.default_provider,
    default_model: override.default_model ?? base.default_model,
    providers: { ...base.providers, ...override.providers },
    tui: { ...base.tui, ...override.tui },
  };
}

/**
 * Map provider name to environment variable prefix
 */
function getEnvPrefix(provider: string): string {
  const prefixes: Record<string, string> = {
    anthropic: 'ANTHROPIC',
    openai: 'OPENAI',
    google: 'GOOGLE',
    kimi: 'KIMI',
  };
  return prefixes[provider] || provider.toUpperCase();
}

/**
 * Resolve the final configuration by merging:
 * 1. Config file (lowest priority)
 * 2. Environment variables
 * 3. CLI args (highest priority)
 *
 * @param cliArgs - Command line arguments that override everything
 */
export function resolveConfig(cliArgs?: {
  provider?: string;
  model?: string;
  baseUrl?: string;
  debug?: boolean;
}): ResolvedConfig {
  const config = loadConfigSync();

  // Determine provider (CLI > env > config)
  const provider = cliArgs?.provider
    || process.env.LEMON_DEFAULT_PROVIDER
    || config.default_provider
    || 'anthropic';

  // Determine model (CLI > env > config)
  const model = cliArgs?.model
    || process.env.LEMON_DEFAULT_MODEL
    || config.default_model
    || 'claude-sonnet-4-20250514';

  // Get provider-specific config
  const providerConfig = config.providers?.[provider] || {};
  const envPrefix = getEnvPrefix(provider);

  // Determine API key (env > config)
  // Note: env vars take precedence for API keys (security best practice)
  const apiKey = process.env[`${envPrefix}_API_KEY`] || providerConfig.api_key;

  // Determine base URL (CLI > env > config)
  const baseUrl = cliArgs?.baseUrl
    || process.env[`${envPrefix}_BASE_URL`]
    || (provider === 'anthropic' ? process.env.ANTHROPIC_BASE_URL : undefined) // Legacy support
    || providerConfig.base_url;

  // TUI config
  const theme = process.env.LEMON_THEME || config.tui?.theme || 'lemon';
  const envDebug =
    process.env.LEMON_DEBUG != null
      ? (process.env.LEMON_DEBUG === '1' || process.env.LEMON_DEBUG === 'true')
      : undefined;
  const debug = cliArgs?.debug
    ?? envDebug
    ?? config.tui?.debug
    ?? false;

  return {
    provider,
    model,
    apiKey,
    baseUrl,
    theme,
    debug,
  };
}

/**
 * Get the model string in "provider:model" format
 */
export function getModelString(config: ResolvedConfig): string {
  return `${config.provider}:${config.model}`;
}

/**
 * Save a single config key (for runtime updates like theme changes)
 */
export async function saveConfigKey<K extends keyof LemonConfig>(
  key: K,
  value: LemonConfig[K]
): Promise<void> {
  const config = await loadConfig();
  (config as any)[key] = value;
  await saveConfig(config);
}

/**
 * Save a TUI config key
 */
export async function saveTUIConfigKey<K extends keyof TUIConfig>(
  key: K,
  value: TUIConfig[K]
): Promise<void> {
  const config = await loadConfig();
  if (!config.tui) {
    config.tui = {};
  }
  config.tui[key] = value;
  await saveConfig(config);
}
