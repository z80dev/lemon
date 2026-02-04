#!/usr/bin/env node
/**
 * CLI Entry Point for Lemon TUI
 */

import { LemonTUI } from './index.js';
import { parseModelSpec, resolveConfig, getModelString, type ResolvedConfig } from './config.js';
import { setTheme } from './theme.js';
import type { AgentConnectionOptions } from './agent-connection.js';

// ============================================================================
// CLI Entry Point
// ============================================================================

interface CLIArgs {
  cwd?: string;
  model?: string;
  provider?: string;
  baseUrl?: string;
  systemPrompt?: string;
  sessionFile?: string;
  debug?: boolean;
  ui?: boolean;
  lemonPath?: string;
}

function parseArgs(): CLIArgs {
  const args = process.argv.slice(2);
  const options: CLIArgs = {};

  for (let i = 0; i < args.length; i++) {
    const arg = args[i];

    switch (arg) {
      case '--cwd':
      case '-d':
        options.cwd = args[++i];
        break;

      case '--model':
      case '-m':
        options.model = args[++i];
        break;

      case '--provider':
      case '-p':
        options.provider = args[++i];
        break;

      case '--base-url':
        options.baseUrl = args[++i];
        break;

      case '--system-prompt':
        options.systemPrompt = args[++i];
        break;

      case '--session-file':
        options.sessionFile = args[++i];
        break;

      case '--debug':
        options.debug = true;
        break;

      case '--no-ui':
        options.ui = false;
        break;

      case '--lemon-path':
        options.lemonPath = args[++i];
        break;

      case '--help':
      case '-h':
        console.log(`
Lemon TUI - Terminal interface for Lemon coding agent

Usage: lemon-tui [options]

Options:
  --cwd, -d <path>       Working directory for the agent
  --model, -m <spec>     Model specification (provider:model_id or just model_id)
  --provider, -p <name>  Provider name (anthropic, openai, kimi, etc.)
  --base-url <url>       Base URL override for model provider
  --system-prompt <text> Custom system prompt
  --session-file <path>  Resume session from file
  --debug                Enable debug mode
  --no-ui                Disable UI overlays
  --lemon-path <path>    Path to lemon project root
  --help, -h             Show this help message

Configuration:
  Config file: ~/.lemon/config.json
  Environment variables override config file values.
  CLI arguments override everything.
`);
        process.exit(0);
        break;

      default:
        if (arg.startsWith('-')) {
          console.error(`Unknown option: ${arg}`);
          process.exit(1);
        }
    }
  }

  return options;
}

/**
 * Build AgentConnectionOptions from CLI args and resolved config
 */
function buildOptions(cliArgs: CLIArgs, config: ResolvedConfig): AgentConnectionOptions {
  const options: AgentConnectionOptions = {
    cwd: cliArgs.cwd,
    debug: config.debug,
    ui: cliArgs.ui,
    lemonPath: cliArgs.lemonPath,
    systemPrompt: cliArgs.systemPrompt,
    sessionFile: cliArgs.sessionFile,
  };

  // Build model string - if CLI provided full "provider:model", use that
  // Otherwise, use resolved config
  options.model = getModelString(config);

  // Base URL from config (already resolved with precedence)
  if (config.baseUrl) {
    options.baseUrl = config.baseUrl;
  }

  return options;
}

// Main
const cliArgs = parseArgs();

// If model includes provider prefix, parse and override provider/model for resolution
const modelSpec = parseModelSpec(cliArgs.model);
if (modelSpec.provider) {
  cliArgs.provider = modelSpec.provider;
}
if (modelSpec.model) {
  cliArgs.model = modelSpec.model;
}

// Resolve configuration: CLI args > env vars > config file
const resolvedConfig = resolveConfig({
  provider: cliArgs.provider,
  model: cliArgs.model,
  baseUrl: cliArgs.baseUrl,
  debug: cliArgs.debug,
});

// Apply theme from resolved config
setTheme(resolvedConfig.theme);

// Build final options for the TUI
const options = buildOptions(cliArgs, resolvedConfig);

const app = new LemonTUI(options);
app.start();
