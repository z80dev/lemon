import * as fs from 'fs';
import { promises as fsPromises } from 'fs';
import * as os from 'os';
import * as path from 'path';

export interface TUIConfig {
  theme: string;
  debug: boolean;
}

const DEFAULT_CONFIG: TUIConfig = {
  theme: 'lemon',
  debug: false,
};

/**
 * Get the config file path (~/.lemon/tui/config.json)
 */
export function getConfigPath(): string {
  return path.join(os.homedir(), '.lemon', 'tui', 'config.json');
}

/**
 * Get the config directory path (~/.lemon/tui/)
 */
function getConfigDir(): string {
  return path.join(os.homedir(), '.lemon', 'tui');
}

/**
 * Load config from file, returns defaults if file doesn't exist
 */
export async function loadConfig(): Promise<TUIConfig> {
  const configPath = getConfigPath();

  try {
    const content = await fsPromises.readFile(configPath, 'utf-8');
    const parsed = JSON.parse(content);
    return { ...DEFAULT_CONFIG, ...parsed };
  } catch {
    // Return defaults if file doesn't exist or is invalid JSON
    return { ...DEFAULT_CONFIG };
  }
}

/**
 * Save config to file, creates directory if needed
 */
export async function saveConfig(config: TUIConfig): Promise<void> {
  const configPath = getConfigPath();
  const configDir = getConfigDir();

  // Create directory if it doesn't exist
  await fsPromises.mkdir(configDir, { recursive: true });

  // Write config file
  await fsPromises.writeFile(configPath, JSON.stringify(config, null, 2), 'utf-8');
}

/**
 * Load config synchronously (for startup) - returns defaults on error
 */
export function loadConfigSync(): TUIConfig {
  const configPath = getConfigPath();

  try {
    const content = fs.readFileSync(configPath, 'utf-8');
    const parsed = JSON.parse(content);
    return { ...DEFAULT_CONFIG, ...parsed };
  } catch {
    // Return defaults if file doesn't exist or is invalid JSON
    return { ...DEFAULT_CONFIG };
  }
}

/**
 * Save a single config key
 */
export async function saveConfigKey<K extends keyof TUIConfig>(
  key: K,
  value: TUIConfig[K]
): Promise<void> {
  const config = await loadConfig();
  config[key] = value;
  await saveConfig(config);
}
