#!/usr/bin/env node
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

import { asBool, asInt, asString, parseCliArgs, type CliArgs } from './cli-args.js';
import { LemonSocket } from './lemon-socket.js';
import { runBrowserNode } from './index.js';
import { resolveOpenClawUserDataDir } from './openclaw-profile.js';

export type BrowserNodeCliConfig = {
  wsUrl: string;
  cdpPort: number;
  headless: boolean;
  noSandbox: boolean;
  attachOnly: boolean;
  executablePath: string | null;
  openclawProfile: string;
  userDataDir: string;
  doPair: boolean;
  nodeName: string;
  operatorToken: string | null;
  token: string | null;
  challengeToken: string | null;
};

export function resolveCliConfig(params: {
  args: CliArgs;
  env?: NodeJS.ProcessEnv;
  hostname?: string;
  storedToken?: string | null;
}): BrowserNodeCliConfig {
  const env = params.env ?? process.env;

  const wsUrl = asString(params.args['ws-url']) ?? 'ws://localhost:4040/ws';
  const cdpPort = asInt(params.args['cdp-port'], 18800);
  const headless = asBool(params.args['headless']);
  const noSandbox = asBool(params.args['no-sandbox']);
  const attachOnly = asBool(params.args['attach-only']);
  const executablePath = asString(params.args['executable-path']) ?? asString(env.LEMON_CHROME_EXECUTABLE);

  const openclawProfile = asString(params.args['openclaw-profile']) ?? 'openclaw';
  const userDataDir =
    asString(params.args['user-data-dir']) ??
    resolveOpenClawUserDataDir(openclawProfile);

  const doPair = asBool(params.args['pair']);
  const defaultNodeName = `Local Browser (${params.hostname ?? os.hostname()})`;
  const nodeName = asString(params.args['node-name']) ?? defaultNodeName;

  const operatorToken =
    asString(params.args['operator-token']) ??
    asString(env.LEMON_OPERATOR_TOKEN) ??
    null;

  const token =
    asString(params.args['token']) ??
    asString(params.storedToken) ??
    null;

  const challengeToken = asString(params.args['challenge-token']);

  return {
    wsUrl,
    cdpPort,
    headless,
    noSandbox,
    attachOnly,
    executablePath,
    openclawProfile,
    userDataDir,
    doPair,
    nodeName,
    operatorToken,
    token,
    challengeToken,
  };
}

const TOKEN_PATH = path.join(os.homedir(), '.lemon', 'nodes', 'browser-node.json');

function readStoredToken(): { token: string } | null {
  try {
    const raw = fs.readFileSync(TOKEN_PATH, 'utf8');
    const parsed = JSON.parse(raw);
    const token = asString(parsed?.token);
    if (token) return { token };
    return null;
  } catch {
    return null;
  }
}

function writeStoredToken(token: string) {
  fs.mkdirSync(path.dirname(TOKEN_PATH), { recursive: true });
  fs.writeFileSync(TOKEN_PATH, JSON.stringify({ token }, null, 2) + '\n', 'utf8');
}

async function pairAndGetNodeToken(params: {
  wsUrl: string;
  nodeName: string;
  operatorToken?: string | null;
}): Promise<{ token: string; nodeId?: string; pairingId?: string }> {
  const { socket } = await LemonSocket.connect(params.wsUrl, {
    role: 'operator',
    client: { id: 'lemon-browser-node-pair' },
    auth: params.operatorToken ? { token: params.operatorToken } : undefined,
  });

  try {
    const request: any = await socket.call('node.pair.request', {
      nodeType: 'browser',
      nodeName: params.nodeName,
    });

    const pairingId = asString(request?.pairingId);
    if (!pairingId) throw new Error('node.pair.request did not return pairingId');

    const approved: any = await socket.call('node.pair.approve', { pairingId });
    const challengeToken = asString(approved?.challengeToken);
    const nodeId = asString(approved?.nodeId) ?? undefined;
    if (!challengeToken) throw new Error('node.pair.approve did not return challengeToken');

    const verified: any = await socket.call('connect.challenge', { challenge: challengeToken });
    const token = asString(verified?.token);
    if (!token) throw new Error('connect.challenge did not return a token');

    return { token, nodeId, pairingId };
  } finally {
    socket.close();
  }
}

async function main() {
  const args = parseCliArgs(process.argv.slice(2));
  const config = resolveCliConfig({
    args,
    storedToken: readStoredToken()?.token ?? null,
  });

  let token = config.token;
  if (config.doPair) {
    const paired = await pairAndGetNodeToken({
      wsUrl: config.wsUrl,
      nodeName: config.nodeName,
      operatorToken: config.operatorToken,
    });
    token = paired.token;
    writeStoredToken(token);
    process.stdout.write(`Paired node "${config.nodeName}" (pairingId=${paired.pairingId ?? 'unknown'})\n`);
    process.stdout.write(`Stored node token at ${TOKEN_PATH}\n`);
  } else if (!token && config.challengeToken) {
    // One-off operator-scope connection to exchange a pairing challenge for a session token.
    const { socket } = await LemonSocket.connect(config.wsUrl, {});
    const res: any = await socket.call('connect.challenge', { challenge: config.challengeToken });
    socket.close();

    const newToken = asString(res?.token);
    if (!newToken) throw new Error('connect.challenge did not return a token');
    token = newToken;
    writeStoredToken(token);
    process.stdout.write(`Stored node token at ${TOKEN_PATH}\n`);
  }

  if (!token) {
    throw new Error(
      'Missing token. Provide --token, or use --pair, or provide --challenge-token from node.pair.approve and re-run.',
    );
  }

  process.stdout.write(
    [
      'lemon-browser-node',
      `wsUrl=${config.wsUrl}`,
      `cdpPort=${config.cdpPort}`,
      `userDataDir=${config.userDataDir}`,
      `headless=${config.headless}`,
      `attachOnly=${config.attachOnly}`,
    ].join(' ') + '\n',
  );

  await runBrowserNode({
    wsUrl: config.wsUrl,
    token,
    cdpPort: config.cdpPort,
    userDataDir: config.userDataDir,
    executablePath: config.executablePath ?? undefined,
    headless: config.headless,
    noSandbox: config.noSandbox,
    attachOnly: config.attachOnly,
  });
}

function isMainModule(): boolean {
  const entry = process.argv[1];
  if (!entry) {
    return false;
  }
  return import.meta.url === pathToFileURL(entry).href;
}

if (isMainModule()) {
  main().catch((err) => {
    const msg = err instanceof Error ? err.stack || err.message : String(err);
    process.stderr.write(msg + '\n');
    process.exit(1);
  });
}
