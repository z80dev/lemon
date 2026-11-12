import { describe, expect, test } from 'bun:test';
import { Database } from 'bun:sqlite';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { readLocalAdmissions, runReaddressCli, type LocalAdmissionRow, type ReaddressCliDependencies } from '../../src/cli/readdress';

const callback = 'https://bot.example/internal/runtime/followup/admission';
const oldCallback = 'http://127.0.0.1:4100/internal/runtime/followup/admission';
const issuer = (state: string, url = callback) => ({ state, url, profileId: 'profile_1', encryptedToken: 'PRIVATE_CIPHERTEXT', digest: 'PRIVATE_DIGEST' });
function row(changes: Partial<LocalAdmissionRow> = {}): LocalAdmissionRow {
  return { id: 'bot_1', name: 'Research helper', profileId: 'profile_1', issuer: issuer('configured'), pendingIssuer: null, lifecycle: null, readdressTarget: null, addressStepsAcknowledged: false, ...changes };
}
function fixture(rows = [row()]) {
  const stdout: string[] = []; const stderr: string[] = []; let reads = 0;
  const deps: ReaddressCliDependencies = {
    env: { HOME: '/private-home', LEMON_BOT_PUBLIC_URL: 'https://bot.example', LEMON_BOT_OPERATOR_TOKEN: 'PRIVATE_OPERATOR' },
    readLocal(dataDir, limit) { expect(dataDir).toBe('/private-home/.lemon/lemon_bot'); expect(limit).toBe(200); reads++; return { bots: rows, totalBots: rows.length, truncated: false }; },
    stdout(value) { stdout.push(value); }, stderr(value) { stderr.push(value); },
  };
  return { deps, stdout, stderr, reads: () => reads, result: () => JSON.parse(stdout.join('')) };
}

describe('local admission status and readdress fallback', () => {
  test('status is an argv-only bounded JSON projection without credentials or private Bot content', async () => {
    const f = fixture([row({ issuer: { ...issuer('configured'), token: 'PRIVATE_TOKEN' }, lifecycle: null })]);
    expect(await runReaddressCli(['--status', '--json'], f.deps)).toBe(0);
    expect(f.result()).toMatchObject({ schemaVersion: 1, status: 'ok', source: 'local_read_only', readdressAvailable: false, reason: 'owner_session_required', totalBots: 1, truncated: false,
      bots: [{ id: 'bot_1', name: 'Research helper', admissionState: 'configured', addressMatches: true, lifecycle: null, nextAction: 'none' }] });
    expect(f.reads()).toBe(1); expect(f.stderr).toHaveLength(0);
    for (const secret of ['PRIVATE_CIPHERTEXT', 'PRIVATE_DIGEST', 'PRIVATE_TOKEN', 'PRIVATE_OPERATOR', '/private-home', callback]) expect(f.stdout.join('')).not.toContain(secret);
  });
  test('address change lists the actionable owner Update address lifecycle', async () => {
    const f = fixture([row({ issuer: issuer('configured', oldCallback) })]);
    expect(await runReaddressCli(['--status', '--json'], f.deps)).toBe(0);
    expect(f.result().bots[0]).toMatchObject({ name: 'Research helper', addressMatches: false, lifecycle: { action: 'readdress', status: 'failed', canReaddress: true }, nextAction: 'update_address' });
    expect(f.result().guidance).toContain('Bot > Settings > lifecycle status panel > Update address'); expect(f.result().guidance).toContain('Check status');
  });
  test('--all refuses session-free mutations and still returns the status projection', async () => {
    const f = fixture([row({ issuer: issuer('configured', oldCallback) })]);
    expect(await runReaddressCli(['--all', '--json'], f.deps)).toBe(1);
    expect(f.result().status).toBe('owner_action_required'); expect(f.result().bots[0].nextAction).toBe('update_address');
    expect(f.result().guidance).toContain('owner'); expect(f.reads()).toBe(1);
  });
  for (const location of ['issuer', 'pendingIssuer', 'lifecycle'] as const) test(`unknown ${location} is inspected repeatedly without redispatch`, async () => {
    const changes = location === 'lifecycle' ? { lifecycle: { action: 'readdress', status: 'outcome_unknown', message: 'PRIVATE_MESSAGE', id: 'PRIVATE_MUTATION' } } : { [location]: issuer('outcome_unknown') };
    const f = fixture([row({ issuer: issuer('configured', oldCallback), ...changes })]);
    expect(await runReaddressCli(['--all', '--json'], f.deps)).toBe(1);
    const first = f.result(); f.stdout.length = 0;
    expect(await runReaddressCli(['--all', '--json'], f.deps)).toBe(1);
    expect(f.result()).toEqual(first); expect(f.result().bots[0].nextAction).toBe('reconcile_read_only');
    expect(f.stdout.join('')).not.toContain('PRIVATE_'); expect(f.result().guidance).toContain('Never retry'); expect(f.reads()).toBe(2);
  });
  test('an uncertain retained issuer cannot be hidden by a different candidate', async () => {
    const f = fixture([row({ issuer: issuer('outcome_unknown', oldCallback), pendingIssuer: issuer('configured') })]);
    expect(await runReaddressCli(['--all', '--json'], f.deps)).toBe(1);
    expect(f.result().bots[0].nextAction).toBe('reconcile_read_only');
  });
  test('pending, rejected, missing and malformed admission states do not become ready', async () => {
    const f = fixture([
      row({ id: 'bot_pending', pendingIssuer: issuer('pending') }),
      row({ id: 'bot_rejected', issuer: issuer('rejected') }),
      row({ id: 'bot_missing', issuer: null }),
      row({ id: 'bot_invalid', issuer: issuer('PRIVATE_STATE') }),
      row({ id: 'bot_wrong_profile', issuer: { ...issuer('configured'), profileId: 'profile_other' } }),
    ]);
    expect(await runReaddressCli(['--status', '--json'], f.deps)).toBe(0);
    expect(f.result().bots.map((bot: { admissionState: string }) => bot.admissionState)).toEqual(['pending', 'rejected', 'missing', 'unknown', 'unknown']);
    expect(f.result().bots.map((bot: { nextAction: string }) => bot.nextAction)).toEqual(['reconcile_read_only', 'inspect_in_browser', 'finish_setup', 'inspect_in_browser', 'inspect_in_browser']);
    expect(f.stdout.join('')).not.toContain('PRIVATE_');
  });
  test('fences and partially finished address steps remain visible without replay', async () => {
    const f = fixture([
      row({ id: 'bot_setup', lifecycle: { action: 'create', status: 'failed' } }),
      row({ id: 'bot_running', lifecycle: { action: 'readdress', status: 'running' } }),
      row({ id: 'bot_partial', lifecycle: { action: 'update', status: 'failed' }, readdressTarget: 'https://bot.example' }),
    ]);
    expect(await runReaddressCli(['--status', '--json'], f.deps)).toBe(0);
    expect(f.result().bots.map((bot: { nextAction: string }) => bot.nextAction)).toEqual(['finish_setup', 'reconcile_read_only', 'update_address']);
  });
  test('malformed lifecycle state is never an idle or ready result', async () => {
    const f = fixture([row({ lifecycle: 'PRIVATE_INVALID_FENCE' })]);
    expect(await runReaddressCli(['--status', '--json'], f.deps)).toBe(0);
    expect(f.result().bots[0].nextAction).toBe('inspect_in_browser');
    expect(f.stdout.join('')).not.toContain('PRIVATE_');
  });
  test('display names are bounded and strip terminal controls and directional overrides', async () => {
    const f = fixture([
      row({ id: 'bot_named', name: '\u001b[31mResearch\nhelper\u202e' }),
      row({ id: 'bot_long', name: 'x'.repeat(1000) }),
      row({ id: 'bot_legacy', name: null }),
    ]);
    expect(await runReaddressCli(['--status', '--json'], f.deps)).toBe(0);
    expect(f.result().bots.map((bot: { name: string }) => bot.name)).toEqual(['[31mResearch helper', 'x'.repeat(120), 'Unnamed Bot']);
    expect(f.result().bots[0].name).not.toMatch(/[\u0000-\u001f\u007f-\u009f\u202a-\u202e]/);
  });
  test('human output remains sanitized and gives exact browser guidance', async () => {
    const f = fixture([row({ issuer: issuer('configured', oldCallback) })]);
    expect(await runReaddressCli(['--status'], f.deps)).toBe(0);
    expect(f.stdout.join('')).toContain('Research helper (bot_1)'); expect(f.stdout.join('')).toContain('update_address');
    expect(f.stdout.join('')).toContain('Settings'); expect(f.stdout.join('')).not.toContain('PRIVATE_');
  });
  test('bounds injected snapshots and reports truncation', async () => {
    const f = fixture(Array.from({ length: 205 }, (_, index) => row({ id: `bot_${index}` })));
    expect(await runReaddressCli(['--status', '--json'], f.deps)).toBe(0);
    expect(f.result().bots).toHaveLength(200); expect(f.result().totalBots).toBe(205); expect(f.result().truncated).toBe(true); expect(f.stdout.join('').length).toBeLessThan(100_000);
  });
  test('human truncation reports shown and total Bot counts', async () => {
    const f = fixture(Array.from({ length: 205 }, (_, index) => row({ id: `bot_${index}` })));
    expect(await runReaddressCli(['--status'], f.deps)).toBe(0);
    expect(f.stdout.join('')).toContain('Showing 200 of 205 Bots');
    expect(f.stdout.join('')).toContain('remaining 5 Bots');
  });
  test('read failures are not empty success and raw diagnostics never escape', async () => {
    const f = fixture(); f.deps.readLocal = () => { throw new Error('PRIVATE_PATH PRIVATE_TOKEN'); };
    expect(await runReaddressCli(['--status', '--json'], f.deps)).toBe(1);
    expect(f.result()).toMatchObject({ status: 'unavailable', totalBots: null, bots: [] }); expect(f.stdout.join('') + f.stderr.join('')).not.toContain('PRIVATE_');
  });
  for (const args of [[], ['--json'], ['--status', '--all'], ['--all', '--all'], ['--status', '--json', '--json'], ['--token', 'PRIVATE_ARGUMENT']]) test(`rejects unsupported arguments ${JSON.stringify(args)}`, async () => {
    const f = fixture(); expect(await runReaddressCli(args, f.deps)).toBe(2); expect(f.reads()).toBe(0); expect(f.stdout).toHaveLength(0); expect(f.stderr.join('')).not.toContain('PRIVATE_');
  });
});

describe('local admission SQLite inspection', () => {
  test('reads only selected public fields, never creates state and leaves uncertain receipts unchanged', async () => {
    const dataDir = await mkdtemp(join(tmpdir(), 'bot-admission-status-'));
    const path = join(dataDir, 'product.sqlite');
    const db = new Database(path);
    try {
      db.exec('CREATE TABLE entities(collection TEXT,id TEXT,value TEXT,PRIMARY KEY(collection,id)); CREATE TABLE metadata(key TEXT PRIMARY KEY,value TEXT);');
      db.query('INSERT INTO entities VALUES(?,?,?)').run('bots', 'bot_1', JSON.stringify({ id: 'bot_1', profileId: 'profile_1', name: 'Research helper', instructions: 'PRIVATE_INSTRUCTIONS' }));
      const stored = JSON.stringify(issuer('outcome_unknown'));
      db.query('INSERT INTO metadata VALUES(?,?)').run('nativeFollowupIssuerConfig:bot_1', stored);
      const snapshot = readLocalAdmissions(dataDir, 200);
      expect(snapshot.bots).toHaveLength(1); expect(snapshot.totalBots).toBe(1); expect(snapshot.truncated).toBe(false);
      expect(snapshot.bots[0]?.name).toBe('Research helper');
      expect(snapshot.bots[0]?.issuer).toEqual({ state: 'outcome_unknown', url: callback, profileId: 'profile_1' });
      expect(JSON.stringify(snapshot)).not.toContain('PRIVATE_');
      expect(db.query('SELECT value FROM metadata').get()).toEqual({ value: stored });
      expect(db.query('SELECT count(*) AS count FROM metadata').get()).toEqual({ count: 1 });
      db.query('INSERT INTO metadata VALUES(?,?)').run('botLifecycle:bot_1', JSON.stringify('PRIVATE_INVALID_FENCE'));
      expect(readLocalAdmissions(dataDir, 200).bots[0]?.lifecycle).toBe('invalid');
    } finally { db.close(); await rm(dataDir, { recursive: true, force: true }); }
  });
  test('SQLite total count covers Bots beyond the bounded row projection', async () => {
    const dataDir = await mkdtemp(join(tmpdir(), 'bot-admission-count-'));
    const db = new Database(join(dataDir, 'product.sqlite'));
    try {
      db.exec('CREATE TABLE entities(collection TEXT,id TEXT,value TEXT,PRIMARY KEY(collection,id)); CREATE TABLE metadata(key TEXT PRIMARY KEY,value TEXT); BEGIN');
      const insert = db.query('INSERT INTO entities VALUES(?,?,?)');
      for (let index = 0; index < 205; index++) insert.run('bots', `bot_${index}`, JSON.stringify({ id: `bot_${index}`, name: `Helper ${index}`, profileId: 'profile_1' }));
      db.exec('COMMIT');
      const snapshot = readLocalAdmissions(dataDir, 200);
      expect(snapshot.bots).toHaveLength(200); expect(snapshot.totalBots).toBe(205); expect(snapshot.truncated).toBe(true);
    } finally { db.close(); await rm(dataDir, { recursive: true, force: true }); }
  });
  test('missing database fails without initializing an instance', async () => {
    const dataDir = await mkdtemp(join(tmpdir(), 'bot-admission-missing-'));
    try { expect(() => readLocalAdmissions(dataDir, 200)).toThrow(); expect(await Bun.file(join(dataDir, 'product.sqlite')).exists()).toBe(false); }
    finally { await rm(dataDir, { recursive: true, force: true }); }
  });
});
