import type {
  Attachment, AttachmentUpload, Download, ErrorCode, JSONObject, Page, RestKey,
  RestQuery, RestRequest, RestResponse, Run, RuntimeAction, Transcription, TranscriptionRequest,
} from '../../../contracts/protocol.ts';
import { isErrorEnvelope, LemonBotError, localError } from './errors.ts';
import { RealtimeConnection } from './realtime.ts';
import type { RealtimeOptions } from './realtime.ts';

export function nonce(): string {
  return crypto.randomUUID();
}

type PathNames<P extends string> = P extends `${string}:${infer Name}/${infer Tail}`
  ? Name | PathNames<Tail> : P extends `${string}:${infer Name}` ? Name : never;
export type RestParams<K extends RestKey> = { [Name in PathNames<K>]: string };
type ParamsOption<K extends RestKey> = [PathNames<K>] extends [never]
  ? { params?: never } : { params: RestParams<K> };
type QueryOption<K extends RestKey> = RestQuery<K> extends undefined ? { query?: never }
  : {} extends RestQuery<K> ? { query?: RestQuery<K> } : { query: RestQuery<K> };
type BodyOption<K extends RestKey> = RestRequest<K> extends undefined
  ? { body?: never } : { body: RestRequest<K> };
export interface ByteRange { start: number; end?: number }
export type CallOptions<K extends RestKey> = ParamsOption<K> & QueryOption<K> & BodyOption<K>
  & { signal?: AbortSignal }
  & (K extends 'POST /attachments' ? { file: Blob; filename?: string } : { file?: never; filename?: never })
  & (K extends 'GET /downloads/:ticket' ? { range?: ByteRange } : { range?: never })
  & (K extends `${'PUT' | 'PATCH' | 'DELETE'} /scim/v2/${'Users' | 'Groups'}/:id`
    ? { ifMatch: string } : { ifMatch?: never });
type CallArguments<K extends RestKey> = {} extends CallOptions<K>
  ? [options?: CallOptions<K>] : [options: CallOptions<K>];

export interface ClientOptions { baseUrl: string; token?: string; fetch?: typeof fetch }
export interface DownloadOptions { range?: ByteRange; signal?: AbortSignal }
export type ReconcileRunsQuery = Omit<NonNullable<RestQuery<'GET /runs'>>, 'clientNonce'>;
export interface TranscribeOptions extends Omit<TranscriptionRequest, 'attachmentId'> { signal?: AbortSignal }

interface WireOptions {
  params?: Record<string, string>;
  query?: object;
  body?: unknown;
  signal?: AbortSignal;
  file?: Blob;
  filename?: string;
  range?: ByteRange;
  ifMatch?: string;
}

function normalizeBase(value: string): string {
  const url = new URL(value);
  if (!['http:', 'https:'].includes(url.protocol) || url.username || url.password || url.search || url.hash) {
    throw localError('invalid_request', 'Use a product HTTP(S) URL without credentials, query or fragment.');
  }
  const loopback = ['localhost', '127.0.0.1', '[::1]'].includes(url.hostname);
  if (url.protocol !== 'https:' && !loopback) {
    throw localError('invalid_request', 'Non-loopback product URLs require HTTPS.');
  }
  const pathname = url.pathname.replace(/\/+$/, '');
  url.pathname = pathname.endsWith('/v1') ? pathname : `${pathname}/v1`;
  return url.href.replace(/\/$/, '');
}

function rangeHeader(range: ByteRange): string {
  if (!Number.isSafeInteger(range.start) || range.start < 0
    || (range.end !== undefined && (!Number.isSafeInteger(range.end) || range.end < range.start))) {
    throw localError('invalid_request', 'A byte range needs a nonnegative start and optional inclusive end.');
  }
  return `bytes=${range.start}-${range.end ?? ''}`;
}


function knownIds(value: unknown): string[] {
  if (!value || typeof value !== 'object') return [];
  const record = value as Record<string, unknown>;
  const ids = ['id', 'runId', 'targetRunId'].flatMap(key => typeof record[key] === 'string' ? [record[key] as string] : []);
  for (const key of ['runs', 'entries', 'items', 'results', 'delivery']) {
    const values = record[key];
    if (Array.isArray(values)) for (const item of values) ids.push(...knownIds(item));
  }
  return ids;
}

function uncertain(value: unknown): boolean {
  if (!value || typeof value !== 'object') return false;
  const record = value as Record<string, unknown>;
  if (record.status === 'outcome_unknown' || record.state === 'outcome_unknown' || record.effectiveMode === 'outcome_unknown') return true;
  return ['runs', 'items', 'results', 'delivery'].some(key => {
    const values = record[key];
    return Array.isArray(values) && values.some(uncertain);
  });
}

export class LemonBotClient {
  readonly baseUrl: string;
  private readonly token?: string;
  private readonly fetcher: typeof fetch;

  constructor(options: ClientOptions) {
    this.baseUrl = normalizeBase(options.baseUrl);
    this.token = options.token;
    this.fetcher = options.fetch ?? globalThis.fetch.bind(globalThis);
  }

  instance() { return this.call('GET /instance'); }
  reconnectController() { return this.call('POST /instance/reconnect', { body: { clientNonce: nonce() } }); }
  runtimeAction(action: RuntimeAction, confirm = false) {
    return this.call('POST /instance/runtime/:action', { params: { action }, body: { clientNonce: nonce(), confirm } });
  }

  async call<K extends RestKey>(key: K, ...args: CallArguments<NoInfer<K>>): Promise<RestResponse<K>> {
    const options = (args[0] ?? {}) as WireOptions;
    const space = key.indexOf(' ');
    const method = key.slice(0, space);
    const template = key.slice(space + 1);
    const params = options.params ?? {};
    const path = template.replace(/:([A-Za-z][A-Za-z0-9]*)/g, (_, name: string) => {
      const value = params[name];
      if (!value || value.includes('/') || value === '.' || value === '..') {
        throw localError('invalid_request', `Missing or invalid path parameter ${name}.`);
      }
      return encodeURIComponent(value);
    });
    for (const name of Object.keys(params)) {
      if (!template.split('/').includes(`:${name}`)) throw localError('invalid_request', `Unexpected path parameter ${name}.`);
    }
    const url = new URL(template.startsWith('/hooks/') ? path : `${this.baseUrl}${path}`, this.baseUrl);
    if (options.query) {
      for (const [name, value] of Object.entries(options.query)) {
        if (value !== undefined) url.searchParams.set(name, Array.isArray(value) ? value.join(',') : String(value));
      }
    }
    let body: BodyInit | undefined;
    const scim = template.startsWith('/scim/v2/');
    const headers = new Headers({ Accept: key === 'GET /downloads/:ticket' ? '*/*' : scim ? 'application/scim+json' : 'application/json' });
    if (options.ifMatch !== undefined) headers.set('If-Match', options.ifMatch);
    if (this.token && key !== 'GET /downloads/:ticket') headers.set('Authorization', `Bearer ${this.token}`);
    if (key === 'POST /attachments') {
      if (!options.file) throw localError('invalid_request', 'Attachment uploads require original file bytes.');
      const form = new FormData();
      form.append('metadata', JSON.stringify(options.body));
      form.append('file', options.file, options.filename ?? 'upload');
      body = form;
    } else if (options.body !== undefined) {
      body = JSON.stringify(options.body);
      headers.set('Content-Type', scim ? 'application/scim+json' : 'application/json');
    }
    if (options.range) headers.set('Range', rangeHeader(options.range));
    const mutation = method !== 'GET' && key !== 'POST /pairings/preview';
    const requestBody = options.body;
    const clientNonce = requestBody && typeof requestBody === 'object' && 'clientNonce' in requestBody
      && typeof requestBody.clientNonce === 'string' ? requestBody.clientNonce : undefined;
    const resourceIds = params.id ? [params.id] : [];
    const value = await this.request(url, {
      method, headers, body, signal: options.signal, credentials: 'omit', redirect: 'manual',
      cache: 'no-store', referrerPolicy: 'no-referrer',
    }, mutation, clientNonce, resourceIds, key === 'GET /downloads/:ticket', key === 'GET /auth/oidc/callback/:providerId');
    return value as RestResponse<K>;
  }

  async upload(file: Blob, metadata: AttachmentUpload, filename?: string): Promise<Attachment> {
    return this.call('POST /attachments', { body: metadata, file, filename });
  }

  async download(id: string): Promise<Download> {
    return this.call('GET /attachments/:id/download', { params: { id } });
  }

  async downloadBytes(download: Download, options: DownloadOptions = {}): Promise<Uint8Array> {
    const url = new URL(download.url, this.baseUrl);
    const trusted = new URL(this.baseUrl);
    const prefix = `${trusted.pathname}/downloads/`;
    if (url.origin !== trusted.origin || url.username || url.password || url.search || url.hash
      || !url.pathname.startsWith(prefix) || !url.pathname.slice(prefix.length)
      || url.pathname.slice(prefix.length).includes('/')) {
      throw localError('forbidden', 'Download URL is not a signed ticket on the trusted product backend.');
    }
    if (download.expiresAtMs <= Date.now()) throw localError('expired', 'Download expired; request a new authorized ticket.');
    const headers = new Headers({ Accept: '*/*' });
    if (options.range) headers.set('Range', rangeHeader(options.range));
    return await this.request(url, {
      method: 'GET', headers, signal: options.signal, credentials: 'omit', redirect: 'manual',
      cache: 'no-store', referrerPolicy: 'no-referrer',
    }, false, undefined, [], true) as Uint8Array;
  }

  /** Explicit read reconciliation. This never replays the uncertain mutation. */
  async reconcileRuns(clientNonce: string, query: ReconcileRunsQuery = {}): Promise<Page<Run>> {
    return this.call('GET /runs', { query: { ...query, clientNonce } });
  }

  /** Upload audio first, then request real backend STT; never sends a chat message. */
  async transcribe(file: Blob, metadata: AttachmentUpload, options: TranscribeOptions, filename?: string): Promise<Transcription> {
    const attachment = await this.call('POST /attachments', {
      file, filename, body: { ...metadata, purpose: 'audio' }, signal: options.signal,
    });
    const { signal, ...body } = options;
    return this.call('POST /audio/transcriptions', { body: { ...body, attachmentId: attachment.id }, signal });
  }

  realtime(options: RealtimeOptions): RealtimeConnection {
    return new RealtimeConnection(this.baseUrl, this.token, options);
  }

  private async request(url: URL, init: RequestInit, mutation: boolean, clientNonce?: string,
    resourceIds: string[] = [], binary = false, redirectResponse = false): Promise<unknown> {
    if (init.signal?.aborted) throw localError('invalid_request', 'Request was cancelled before dispatch.', { cause: init.signal.reason, clientNonce, resourceIds });
    let response: Response;
    try {
      response = await this.fetcher(url, init);
    } catch (cause) {
      throw localError(mutation ? 'outcome_unknown' : 'upstream_unavailable', mutation
        ? 'Connection lost; this action may have taken effect. Reconcile with GET; do not resend.'
        : 'The product backend could not be reached.', { cause, clientNonce, resourceIds });
    }
    const context = { status: response.status, clientNonce, resourceIds };
    if (redirectResponse && response.status === 302) {
      const location = response.headers.get('Location');
      if (location) return { status: 302, location };
    }
    if (response.ok && binary) {
      try { return new Uint8Array(await response.arrayBuffer()); }
      catch (cause) { throw localError('upstream_unavailable', 'Download was interrupted.', { ...context, cause }); }
    }
    if (response.status === 204 && response.ok) return undefined;
    let value: unknown;
    try { value = await response.json(); }
    catch (cause) {
      throw new LemonBotError({
        code: mutation ? 'outcome_unknown' : 'upstream_unavailable',
        message: mutation ? 'No valid action receipt was received. Reconcile before another attempt.' : 'Backend returned no valid JSON response.',
        requestId: response.headers.get('X-Request-Id') ?? '', retrySafe: !mutation,
      }, { ...context, cause });
    }
    if (!response.ok) {
      if (isErrorEnvelope(value)) throw new LemonBotError(value.error, context);
      const code: ErrorCode = response.status === 401 ? 'unauthenticated' : response.status === 403 ? 'forbidden'
        : response.status === 404 ? 'not_found' : response.status === 409 ? 'conflict'
        : response.status === 412 ? 'revision_conflict' : response.status === 400 ? 'invalid_request'
        : response.status === 413 ? 'too_large' : mutation ? 'outcome_unknown' : 'upstream_unavailable';
      const scim = value && typeof value === 'object' && 'detail' in value && typeof value.detail === 'string' ? value.detail : null;
      throw new LemonBotError({ code, message: scim ?? 'Backend returned an invalid error envelope.', requestId: response.headers.get('X-Request-Id') ?? '', retrySafe: response.status === 412 }, context);
    }
    if (mutation && uncertain(value)) {
      throw new LemonBotError({ code: 'outcome_unknown', message: 'Action outcome is not confirmed. Reconcile the returned resources before another attempt.',
        requestId: response.headers.get('X-Request-Id') ?? '', retrySafe: false,
        details: { resourceIds: knownIds(value), currentResource: value as JSONObject },
      }, context);
    }
    return value;
  }
}
