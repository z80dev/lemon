import { readFileSync, writeFileSync } from 'node:fs';
import { loadConfig } from './load.ts';
import type { Config } from './types.ts';
export function serializeConfig(config: Config): string {
  return JSON.stringify({ channel: config.channel, batchSize: config.batchSize, sender: config.sender }, null, 2) + '\n';
}
export function saveConfig(path: string, config: Config): void { writeFileSync(path, serializeConfig(config)); }
export function readConfig(path: string): Config { return loadConfig(JSON.parse(readFileSync(path, 'utf8'))); }
