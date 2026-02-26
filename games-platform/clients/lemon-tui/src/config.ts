import * as fs from 'fs';
import { promises as fsPromises } from 'fs';
import * as os from 'os';
import * as path from 'path';
import * as toml from '@iarna/toml';

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
 * Control plane configuration (remote/server mode)
 *
 * Example (~/.lemon/config.toml):
 * [control_plane]
 * ws_url = "ws://localhost:4040/ws"
 * token = "..."
 * role = "operator"
 * scopes = ["read", "write"]
 * client_id = "lemon-tui"
 */
export interface ControlPlaneConfig {
  ws_url?: string;
  token?: string;
  role?: string;
  scopes?: string[];
  client_id?: string;
}

/**
 * Main Lemon configuration file structure (~/.lemon/config.toml)
 */
export interface AgentConfig {
  default_provider?: string;
  default_model?: string;
}

export interface LemonConfig {
  providers?: Record<string, ProviderConfig>;
  agent?: AgentConfig;
  tui?: TUIConfig;
  control_plane?: ControlPlaneConfig;
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
  wsUrl?: string;
  wsToken?: string;
  wsRole?: string;
  wsScopes?: string[];
  wsClientId?: string;
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
  providers: {},
  agent: {
    default_provider: 'anthropic',
    default_model: 'claude-sonnet-4-20250514',
  },
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
 * Get the config file path (~/.lemon/config.toml)
 */
export function getConfigPath(): string {
  return path.join(getConfigDir(), 'config.toml');
}

/**
 * Get the project config path (<cwd>/.lemon/config.toml)
 */
export function getProjectConfigPath(cwd: string): string {
  return path.join(cwd, '.lemon', 'config.toml');
}

async function loadProjectConfig(cwd: string): Promise<Partial<LemonConfig>> {
  const configPath = getProjectConfigPath(cwd);

  try {
    const content = await fsPromises.readFile(configPath, 'utf-8');
    return toml.parse(content) as LemonConfig;
  } catch {
    return {};
  }
}

function loadProjectConfigSync(cwd: string): Partial<LemonConfig> {
  const configPath = getProjectConfigPath(cwd);

  try {
    const content = fs.readFileSync(configPath, 'utf-8');
    return toml.parse(content) as LemonConfig;
  } catch {
    return {};
  }
}

/**
 * Load config from file, returns defaults if file doesn't exist
 */
export async function loadConfig(cwd?: string): Promise<LemonConfig> {
  const configPath = getConfigPath();

  try {
    const content = await fsPromises.readFile(configPath, 'utf-8');
    const parsed = toml.parse(content) as LemonConfig;
    const merged = mergeConfig(DEFAULT_CONFIG, parsed);
    if (cwd) {
      return mergeConfig(merged, await loadProjectConfig(cwd));
    }
    return merged;
  } catch {
    // Return defaults if file doesn't exist or is invalid TOML
    return { ...DEFAULT_CONFIG };
  }
}

/**
 * Load config synchronously (for startup) - returns defaults on error
 */
export function loadConfigSync(cwd?: string): LemonConfig {
  const configPath = getConfigPath();

  try {
    const content = fs.readFileSync(configPath, 'utf-8');
    const parsed = toml.parse(content) as LemonConfig;
    const merged = mergeConfig(DEFAULT_CONFIG, parsed);
    if (cwd) {
      return mergeConfig(merged, loadProjectConfigSync(cwd));
    }
    return merged;
  } catch {
    // Return defaults if file doesn't exist or is invalid TOML
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
  await fsPromises.writeFile(configPath, toml.stringify(config as toml.JsonMap), 'utf-8');
}

/**
 * Deep merge two config objects
 */
function mergeConfig(base: LemonConfig, override: Partial<LemonConfig>): LemonConfig {
  const overrideAgent = override.agent ?? {};

  return {
    providers: { ...base.providers, ...override.providers },
    agent: {
      ...base.agent,
      ...overrideAgent,
    },
    tui: { ...base.tui, ...override.tui },
    control_plane: { ...base.control_plane, ...override.control_plane },
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
  cwd?: string;
}): ResolvedConfig {
  const config = loadConfigSync(cliArgs?.cwd);
  const agentConfig = config.agent || {};
  const controlPlaneConfig = config.control_plane || {};

  // Determine provider (CLI > env > config)
  const provider = cliArgs?.provider
    || process.env.LEMON_DEFAULT_PROVIDER
    || agentConfig.default_provider
    || 'anthropic';

  // Determine model (CLI > env > config)
  const model = cliArgs?.model
    || process.env.LEMON_DEFAULT_MODEL
    || agentConfig.default_model
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

  const wsUrl = process.env.LEMON_WS_URL || controlPlaneConfig.ws_url;
  const wsToken = process.env.LEMON_WS_TOKEN || controlPlaneConfig.token;
  const wsRole = process.env.LEMON_WS_ROLE || controlPlaneConfig.role;
  const wsScopes =
    process.env.LEMON_WS_SCOPES
      ? process.env.LEMON_WS_SCOPES.split(',').map((s) => s.trim()).filter(Boolean)
      : controlPlaneConfig.scopes;
  const wsClientId = process.env.LEMON_WS_CLIENT_ID || controlPlaneConfig.client_id;

  return {
    provider,
    model,
    apiKey,
    baseUrl,
    theme,
    debug,
    wsUrl,
    wsToken,
    wsRole,
    wsScopes,
    wsClientId,
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
  if (key === 'agent' && typeof value === 'object' && value) {
    config.agent = { ...(config.agent || {}), ...(value as AgentConfig) };
  } else if (key === 'tui' && typeof value === 'object' && value) {
    config.tui = { ...(config.tui || {}), ...(value as TUIConfig) };
  } else if (key === 'providers' && typeof value === 'object' && value) {
    config.providers = { ...(config.providers || {}), ...(value as Record<string, ProviderConfig>) };
  } else {
    (config as any)[key] = value;
  }
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
