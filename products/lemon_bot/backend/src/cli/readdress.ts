import { Database } from 'bun:sqlite';
import { join } from 'node:path';
import { localSettings } from '../core/config';

const maxBots = 200;
const callbackPath = '/internal/runtime/followup/admission';
const guidance = 'Sign in to Lemon Bot as each Bot owner, then follow Bot > Settings > lifecycle status panel > Update address when offered, or Finish setup for interrupted setup. For pending or outcome_unknown work choose Check status and wait for the backend to reconcile its owning receipts read-only. Never retry an uncertain mutation or create a replacement Bot. Local status is a saved snapshot, not a live controller acknowledgement.';

export interface LocalAdmissionRow {
  id: unknown;
  name: unknown;
  profileId: unknown;
  issuer: unknown;
  pendingIssuer: unknown;
  lifecycle: unknown;
  readdressTarget: unknown;
  addressStepsAcknowledged: boolean;
}
export interface LocalAdmissionSnapshot { bots: LocalAdmissionRow[]; totalBots: number; truncated: boolean }
export interface ReaddressCliDependencies {
  env: Record<string, string | undefined>;
  readLocal(dataDir: string, limit: number): LocalAdmissionSnapshot;
  stdout(value: string): void;
  stderr(value: string): void;
}
type AdmissionState = 'configured' | 'pending' | 'rejected' | 'outcome_unknown' | 'missing' | 'unknown';
type LifecycleAction = 'create' | 'import' | 'update' | 'readdress' | 'delete' | 'move' | 'reset' | 'unknown';
type LifecycleStatus = 'running' | 'outcome_unknown' | 'failed' | 'unknown';
interface AdmissionView {
  id: string;
  name: string;
  admissionState: AdmissionState;
  addressMatches: boolean | null;
  lifecycle: { action: LifecycleAction; status: LifecycleStatus; canReaddress: boolean } | null;
  nextAction: 'update_address' | 'reconcile_read_only' | 'finish_setup' | 'none' | 'inspect_in_browser';
}
interface StatusResult {
  schemaVersion: 1;
  status: 'ok' | 'owner_action_required' | 'unavailable';
  source: 'local_read_only';
  readdressAvailable: false;
  reason: 'owner_session_required';
  totalBots: number | null;
  truncated: boolean;
  bots: AdmissionView[];
  guidance: string;
}
function object(value: unknown): Record<string, unknown> | null { return value !== null && typeof value === 'object' && !Array.isArray(value) ? value as Record<string, unknown> : null; }
function admissionState(value: unknown): AdmissionState {
  if (value === null) return 'missing';
  const state = object(value)?.state;
  return state === 'configured' || state === 'pending' || state === 'rejected' || state === 'outcome_unknown' ? state : 'unknown';
}
function lifecycleAction(value: unknown): LifecycleAction {
  return value === 'create' || value === 'import' || value === 'update' || value === 'readdress' || value === 'delete' || value === 'move' || value === 'reset' ? value : 'unknown';
}
function lifecycleStatus(value: unknown): LifecycleStatus { return value === 'running' || value === 'outcome_unknown' || value === 'failed' ? value : 'unknown'; }
function identifier(value: unknown): value is string { return typeof value === 'string' && /^[^/\u0000-\u0020\u007f]{1,128}$/.test(value); }
function callbackMatches(value: unknown, expected: string): boolean | null {
  const url = object(value)?.url;
  if (typeof url !== 'string' || url.length > 2048) return null;
  try {
    const parsed = new URL(url);
    if (parsed.username || parsed.password || parsed.search || parsed.hash || parsed.protocol !== 'http:' && parsed.protocol !== 'https:') return null;
    return parsed.toString() === expected;
  } catch { return null; }
}
function project(row: LocalAdmissionRow, expected: string): AdmissionView {
  if (!identifier(row.id)) throw new Error('Invalid saved Bot identity');
  const name = typeof row.name === 'string'
    ? row.name.replace(/[\u0000-\u001f\u007f-\u009f\u200e\u200f\u2028-\u202e\u2066-\u2069]/g, ' ').replace(/\s+/g, ' ').trim().slice(0, 120) || 'Unnamed Bot'
    : 'Unnamed Bot';
  const candidate = row.pendingIssuer ?? row.issuer;
  const candidateValid = candidate === null || identifier(row.profileId) && object(candidate)?.profileId === row.profileId;
  const state = candidateValid ? admissionState(candidate) : 'unknown';
  const addressMatches = identifier(row.profileId) && object(row.issuer)?.profileId === row.profileId ? callbackMatches(row.issuer, expected) : null;
  const activeState = admissionState(row.issuer);
  const pendingState = admissionState(row.pendingIssuer);
  const uncertainAdmission = activeState === 'pending' || activeState === 'outcome_unknown' || pendingState === 'pending' || pendingState === 'outcome_unknown';
  const addressChange = addressMatches === false;
  const addressRecovery = !!row.readdressTarget && !row.addressStepsAcknowledged;
  const fence = object(row.lifecycle);
  const action = lifecycleAction(fence?.action);
  const status = lifecycleStatus(fence?.status);
  const canReaddress = fence
    ? (addressChange || addressRecovery || action === 'readdress') && status !== 'running' && status !== 'unknown' && (action === 'create' || action === 'import' || action === 'update' || action === 'readdress')
    : addressChange;
  const lifecycle: AdmissionView['lifecycle'] = fence
    ? { action, status, canReaddress }
    : addressChange ? { action: 'readdress', status: 'failed', canReaddress: true } : null;
  let nextAction: AdmissionView['nextAction'];
  if (uncertainAdmission || status === 'outcome_unknown' || status === 'running') nextAction = 'reconcile_read_only';
  else if (!candidateValid || state === 'unknown' || row.lifecycle !== null && (!fence || action === 'unknown' || status === 'unknown')) nextAction = 'inspect_in_browser';
  else if (canReaddress) nextAction = 'update_address';
  else if (action === 'create' || action === 'import' || state === 'missing') nextAction = 'finish_setup';
  else if (lifecycle || state !== 'configured' || addressMatches !== true) nextAction = 'inspect_in_browser';
  else nextAction = 'none';
  return { id: row.id, name, admissionState: state, addressMatches, lifecycle, nextAction };
}

/** No Store constructor, private key, local sign-in, controller token or mutation path. */
export function readLocalAdmissions(dataDir: string, limit: number): LocalAdmissionSnapshot {
  if (!Number.isSafeInteger(limit) || limit < 1 || limit > maxBots) throw new Error('Invalid status limit');
  const db = new Database(join(dataDir, 'product.sqlite'), { readonly: true, strict: true });
  try {
    db.exec('BEGIN');
    const { totalBots } = db.query("SELECT count(*) AS totalBots FROM entities WHERE collection='bots'").get() as { totalBots: number };
    const rows = db.query("SELECT id, substr(json_extract(value,'$.name'),1,480) AS name, substr(json_extract(value,'$.profileId'),1,129) AS profileId FROM entities WHERE collection='bots' ORDER BY id LIMIT ?").all(limit) as { id: unknown; name: unknown; profileId: unknown }[];
    // Extract only needed fields inside SQLite: private tokens/persona text never enter the CLI projection.
    const issuerQuery = db.query(`SELECT CASE WHEN json_type(value)='object' THEN json_object(
      'state',substr(json_extract(value,'$.state'),1,32),
      'url',substr(json_extract(value,'$.url'),1,2049),
      'profileId',substr(json_extract(value,'$.profileId'),1,129)) WHEN json_type(value)='null' THEN NULL ELSE '"invalid"' END AS value FROM metadata WHERE key=?`);
    const lifecycleQuery = db.query(`SELECT CASE WHEN json_type(value)='object' THEN json_object(
      'action',substr(json_extract(value,'$.action'),1,32),
      'status',substr(json_extract(value,'$.status'),1,32)) WHEN json_type(value)='null' THEN NULL ELSE '"invalid"' END AS value FROM metadata WHERE key=?`);
    const targetQuery = db.query("SELECT json_type(value)='text' AS present FROM metadata WHERE key=?");
    const stepsQuery = db.query(`SELECT json_extract(value,'$.steps."Update callback address"')='acknowledged'
      AND json_extract(value,'$.steps."Update Bot address"')='acknowledged'
      AND json_extract(value,'$.steps."Sync updated address"')='acknowledged' AS acknowledged FROM metadata WHERE key=?`);
    const decode = (row: unknown): unknown => {
      const value = (row as { value: string | null } | null)?.value;
      return value ? JSON.parse(value) as unknown : null;
    };
    const bots = rows.map(row => {
      if (!identifier(row.id)) throw new Error('Invalid saved Bot identity');
      return {
        ...row,
        issuer: decode(issuerQuery.get(`nativeFollowupIssuerConfig:${row.id}`)),
        pendingIssuer: decode(issuerQuery.get(`nativeFollowupIssuerPending:${row.id}`)),
        lifecycle: decode(lifecycleQuery.get(`botLifecycle:${row.id}`)),
        readdressTarget: (targetQuery.get(`botReaddressTarget:${row.id}`) as { present: number } | null)?.present === 1,
        addressStepsAcknowledged: (stepsQuery.get(`botSetup:${row.id}`) as { acknowledged: number | null } | null)?.acknowledged === 1,
      };
    });
    db.exec('COMMIT');
    return { bots, totalBots, truncated: totalBots > bots.length };
  } finally { db.close(); }
}
const defaults: ReaddressCliDependencies = {
  env: process.env, readLocal: readLocalAdmissions,
  stdout(value) { process.stdout.write(value); }, stderr(value) { process.stderr.write(value); },
};

/** Owner-only readdressing has no session-free operator equivalent; --all never impersonates owners. */
export async function runReaddressCli(args: string[], deps: ReaddressCliDependencies = defaults): Promise<number> {
  if (args.some(arg => arg !== '--status' && arg !== '--all' && arg !== '--json') || new Set(args).size !== args.length || args.includes('--status') === args.includes('--all')) {
    deps.stderr('Usage: lemon-bot readdress --status [--json] | --all [--json]\n'); return 2;
  }
  const result: StatusResult = { schemaVersion: 1, status: args.includes('--all') ? 'owner_action_required' : 'ok', source: 'local_read_only', readdressAvailable: false, reason: 'owner_session_required', totalBots: null, truncated: false, bots: [], guidance };
  try {
    const settings = localSettings(deps.env);
    const snapshot = deps.readLocal(settings.dataDir, maxBots);
    const expected = new URL(callbackPath, settings.publicUrl).toString();
    result.bots = snapshot.bots.slice(0, maxBots).map(row => project(row, expected));
    result.totalBots = snapshot.totalBots;
    result.truncated = snapshot.truncated || snapshot.totalBots > result.bots.length;
  } catch { result.status = 'unavailable'; result.guidance = 'Could not inspect saved Bot admission state. Check the local instance configuration and database; no changes were made.'; }
  if (args.includes('--json')) deps.stdout(`${JSON.stringify(result)}\n`);
  else {
    deps.stdout('Bot admission status (local saved snapshot; read-only).\n');
    if (result.totalBots !== null) deps.stdout(`Showing ${result.bots.length} of ${result.totalBots} Bots.\n`);
    for (const bot of result.bots) deps.stdout(`${bot.name} (${bot.id}): ${bot.admissionState}; address ${bot.addressMatches === null ? 'unknown' : bot.addressMatches ? 'matches' : 'changed'}; ${bot.nextAction}\n`);
    if (result.truncated && result.totalBots !== null) deps.stdout(`Inspect the remaining ${result.totalBots - result.bots.length} Bots in the browser.\n`);
    if (result.status === 'owner_action_required') deps.stdout('Readdress requires each Bot owner: local sign-in creates a product session, not session-free operator authority. No mutations were sent.\n');
    deps.stdout(`${result.guidance}\n`);
  }
  return result.status === 'ok' ? 0 : 1;
}
