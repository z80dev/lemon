#!/usr/bin/env node
import { pathToFileURL } from 'node:url';

import { asInt, asString, parseCliArgs } from './cli-args.js';
import { startRelayServer } from './relay/server.js';

export function resolveRelayConfig(
  argv: string[],
  env: NodeJS.ProcessEnv = process.env,
): { port: number; token: string } {
  const args = parseCliArgs(argv);
  const port = asInt(args.port, asInt(env.LEMON_BROWSER_RELAY_PORT, 9224));
  const token =
    asString(args.token) ?? asString(env.LEMON_BROWSER_RELAY_TOKEN) ?? '';

  if (!Number.isInteger(port) || port <= 0 || port > 65535) {
    throw new Error('browser relay port must be between 1 and 65535');
  }
  if (!token) {
    throw new Error(
      'browser relay token is required; pass --token or LEMON_BROWSER_RELAY_TOKEN',
    );
  }
  return { port, token };
}

async function main(): Promise<void> {
  const config = resolveRelayConfig(process.argv.slice(2));
  const relay = await startRelayServer({
    ...config,
    log: (message, data) =>
      process.stderr.write(`[lemon-browser-relay] ${message} ${JSON.stringify(data ?? {})}\n`),
  });

  process.stdout.write(
    `Lemon browser relay listening on 127.0.0.1:${relay.port} (token required)\n`,
  );

  const shutdown = () => void relay.stop().finally(() => process.exit(0));
  process.on('SIGINT', shutdown);
  process.on('SIGTERM', shutdown);
}

function isMainModule(): boolean {
  const entry = process.argv[1];
  return !!entry && import.meta.url === pathToFileURL(entry).href;
}

if (isMainModule()) {
  main().catch((error) => {
    process.stderr.write(`${error instanceof Error ? error.message : String(error)}\n`);
    process.exit(1);
  });
}
