import type { RunningSessionInfo } from '@lemon-web/shared';

export interface BridgeOptions {
  cwd?: string;
  model?: string;
  baseUrl?: string;
  systemPrompt?: string;
  sessionFile?: string;
  debug?: boolean;
  ui?: boolean;
  lemonPath?: string;
  port?: number;
  staticDir?: string;
}

export function contentTypeFor(ext: string): string | null {
  switch (ext) {
    case '.html':
      return 'text/html';
    case '.js':
      return 'text/javascript';
    case '.css':
      return 'text/css';
    case '.svg':
      return 'image/svg+xml';
    case '.json':
      return 'application/json';
    case '.png':
      return 'image/png';
    case '.jpg':
    case '.jpeg':
      return 'image/jpeg';
    case '.woff':
      return 'font/woff';
    case '.woff2':
      return 'font/woff2';
    default:
      return null;
  }
}

export function parseArgs(argv: string[]): BridgeOptions {
  const opts: BridgeOptions = {};
  for (let i = 2; i < argv.length; i += 1) {
    const arg = argv[i];
    const next = argv[i + 1];
    switch (arg) {
      case '--cwd':
        opts.cwd = next;
        i += 1;
        break;
      case '--model':
        opts.model = next;
        i += 1;
        break;
      case '--base_url':
      case '--base-url':
        opts.baseUrl = next;
        i += 1;
        break;
      case '--system-prompt':
      case '--system_prompt':
        opts.systemPrompt = next;
        i += 1;
        break;
      case '--session-file':
      case '--session_file':
        opts.sessionFile = next;
        i += 1;
        break;
      case '--debug':
        opts.debug = true;
        break;
      case '--no-ui':
        opts.ui = false;
        break;
      case '--lemon-path':
        opts.lemonPath = next;
        i += 1;
        break;
      case '--port':
        opts.port = Number(next);
        i += 1;
        break;
      case '--static-dir':
        opts.staticDir = next;
        i += 1;
        break;
      default:
        break;
    }
  }
  return opts;
}

export function buildRpcArgs(opts: BridgeOptions): string[] {
  const args = ['run', '--no-start', 'scripts/debug_agent_rpc.exs', '--'];

  if (opts.cwd) {
    args.push('--cwd', opts.cwd);
  }
  if (opts.model) {
    args.push('--model', opts.model);
  }
  if (opts.baseUrl) {
    args.push('--base_url', opts.baseUrl);
  }
  if (opts.systemPrompt) {
    args.push('--system_prompt', opts.systemPrompt);
  }
  if (opts.sessionFile) {
    args.push('--session-file', opts.sessionFile);
  }
  if (opts.debug) {
    args.push('--debug');
  }
  if (opts.ui === false) {
    args.push('--no-ui');
  }

  return args;
}

export function decodeBase64Url(value: string): string {
  const normalized = value.replace(/-/g, '+').replace(/_/g, '/');
  const missingPadding = normalized.length % 4;
  const padded =
    missingPadding === 0 ? normalized : normalized + '='.repeat(4 - missingPadding);
  return Buffer.from(padded, 'base64').toString('utf8');
}

export function parseGatewayProbeOutput(
  stdout: string,
  stderr: string,
  status: number | null,
  processError: Error | null = null
): { sessions: RunningSessionInfo[]; error: string | null } {
  if (processError) {
    return { sessions: [], error: processError.message };
  }

  if (status !== null && status !== 0) {
    const err = (stderr || stdout || '').trim();
    return { sessions: [], error: err || `probe exited with status ${status}` };
  }

  const sessions: RunningSessionInfo[] = [];
  const lines = (stdout || '')
    .split('\n')
    .map((line) => line.trim())
    .filter((line) => line.length > 0);

  for (const line of lines) {
    if (line.startsWith('__ERROR__|')) {
      const parts = line.split('|');
      return { sessions: [], error: parts.slice(1).join('|') || 'gateway probe error' };
    }

    const parts = line.split('|');
    if (parts.length !== 3) {
      continue;
    }

    try {
      const session_id = decodeBase64Url(parts[0]);
      const cwd = decodeBase64Url(parts[1]);
      const is_streaming = parts[2] === '1';
      sessions.push({ session_id, cwd, is_streaming });
    } catch {
      continue;
    }
  }

  return { sessions, error: null };
}
