#!/usr/bin/env node
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

import { LemonSocket } from './lemon-socket.js';
import { runBrowserNode } from './index.js';
import { resolveOpenClawUserDataDir } from './openclaw-profile.js';

type Args = Record<string, string | boolean>;

function parseArgs(argv: string[]): Args {
  const out: Args = {};
  for (let i = 0; i < argv.length; i += 1) {
    const a = argv[i]!;
    if (!a.startsWith('--')) continue;
    const key = a.slice(2);
    const next = argv[i + 1];
    if (!next || next.startsWith('--')) {
      out[key] = true;
    } else {
      out[key] = next;
      i += 1;
    }
  }
  return out;
}

function asString(v: unknown): string | null {
  if (typeof v === 'string' && v.trim()) return v.trim();
  return null;
}

function asBool(v: unknown): boolean {
  if (v === true) return true;
  if (typeof v === 'string') return ['1', 'true', 'yes', 'on'].includes(v.toLowerCase());
  return false;
}

function asInt(v: unknown, def: number): number {
  if (typeof v === 'string') {
    const n = Number.parseInt(v, 10);
    if (Number.isFinite(n) && n > 0) return n;
  }
  return def;
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
  const args = parseArgs(process.argv.slice(2));

  const wsUrl = asString(args['ws-url']) ?? 'ws://localhost:4040/ws';
  const cdpPort = asInt(args['cdp-port'], 18800);
  const headless = asBool(args['headless']);
  const noSandbox = asBool(args['no-sandbox']);
  const attachOnly = asBool(args['attach-only']);
  const executablePath = asString(args['executable-path']) ?? asString(process.env.LEMON_CHROME_EXECUTABLE);

  const openclawProfile = asString(args['openclaw-profile']) ?? 'openclaw';
  const userDataDir =
    asString(args['user-data-dir']) ??
    resolveOpenClawUserDataDir(openclawProfile);

  const doPair = asBool(args['pair']);

  const defaultNodeName = `Local Browser (${os.hostname()})`;
  const nodeName = asString(args['node-name']) ?? defaultNodeName;

  const operatorToken =
    asString(args['operator-token']) ??
    asString(process.env.LEMON_OPERATOR_TOKEN) ??
    null;

  let token = asString(args['token']) ?? readStoredToken()?.token ?? null;

  const challengeToken = asString(args['challenge-token']);
  if (doPair) {
    const paired = await pairAndGetNodeToken({ wsUrl, nodeName, operatorToken });
    token = paired.token;
    writeStoredToken(token);
    process.stdout.write(`Paired node "${nodeName}" (pairingId=${paired.pairingId ?? 'unknown'})\n`);
    process.stdout.write(`Stored node token at ${TOKEN_PATH}\n`);
  } else if (!token && challengeToken) {
    // One-off operator-scope connection to exchange a pairing challenge for a session token.
    const { socket } = await LemonSocket.connect(wsUrl, {});
    const res: any = await socket.call('connect.challenge', { challenge: challengeToken });
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
      `wsUrl=${wsUrl}`,
      `cdpPort=${cdpPort}`,
      `userDataDir=${userDataDir}`,
      `headless=${headless}`,
      `attachOnly=${attachOnly}`,
    ].join(' ') + '\n',
  );

  await runBrowserNode({
    wsUrl,
    token,
    cdpPort,
    userDataDir,
    executablePath: executablePath ?? undefined,
    headless,
    noSandbox,
    attachOnly,
  });
}

main().catch((err) => {
  const msg = err instanceof Error ? err.stack || err.message : String(err);
  process.stderr.write(msg + '\n');
  process.exit(1);
});
