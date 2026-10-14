import { readFileSync, statSync } from 'node:fs';
import { createPrivateKey, sign } from 'node:crypto';
import { z } from 'zod';
import type * as P from '../../../contracts/protocol';
import type { BackendServices, Principal, Route } from '../core/services';
import { ApiError, fail } from '../core/errors';

const MAX_BYTES = 25 * 1024 * 1024;
const MAX_DURATION = 600_000;
const nonce = z.string().regex(/^[A-Za-z0-9_-]{16,128}$/);
const id = z.string().min(1).max(256).regex(/^[^/\\\x00-\x1f]+$/);
const language = z.string().min(2).max(64).regex(/^[A-Za-z]{2,8}(?:-[A-Za-z0-9]{1,8})*$/);
const voiceSchema = z.strictObject({ voiceId: z.string().min(1).max(128), speed: z.number().min(0.5).max(2), language: language.nullable() });
const speechSchema = z.strictObject({ clientNonce: nonce, text: z.string().min(1).max(4096), voice: voiceSchema, conversationId: id.optional(), voiceSessionId: id.optional() });
const transcriptionSchema = z.strictObject({ clientNonce: nonce, attachmentId: id, language: language.optional(), voiceSessionId: id.optional() });
const previewSchema = z.strictObject({ clientNonce: nonce, voice: voiceSchema.optional() });
function parse<T>(schema: z.ZodType<T>, input: unknown): T { const result = schema.safeParse(input); if (!result.success) fail('invalid_request', 'Invalid audio request.'); return result.data; }
function parseProvider<T>(schema: z.ZodType<T>, input: unknown): T { const result = schema.safeParse(input); if (!result.success) fail('upstream_unavailable', 'Audio provider returned an invalid response.', false); return result.data; }
export interface AudioOptions { env?: Record<string, string | undefined>; fetch?: typeof fetch; timeoutMs?: number }
export interface AudioInfo { mime: string; extension: string; durationMs: number }
export interface AudioServices {
  speech(principal: Principal, input: unknown, provenance?: P.DeliverableProvenance): Promise<P.SpeechResult>;
  transcribe(principal: Principal, input: unknown): Promise<P.Transcription>;
  authorizeReplay(principal: Principal, input: unknown, kind: 'speech' | 'transcription' | 'preview', botId?: string): Promise<void>;
  providerCapabilities(): Pick<P.Capabilities, 'stt' | 'tts'>;
  inventory(): { id: 'stt' | 'tts'; provider: string | null; configured: boolean }[];
}
const audioInstances = new WeakMap<BackendServices, AudioServices>();

/** Sniff original bytes and measure the container, never trust upload MIME/duration. */
export function inspectAudio(input: Uint8Array): AudioInfo {
  if (!input.length) fail('unsupported_media', 'Audio is empty.');
  if (input.length > MAX_BYTES) fail('too_large', 'Audio exceeds 25 MiB.');
  const b = Buffer.from(input.buffer, input.byteOffset, input.byteLength);
  let duration = 0, mime = '', extension = '';
  const bad = () => fail('unsupported_media', 'Audio container is unsupported, truncated or has no measurable audio.');
  if (b.length >= 12 && b.toString('ascii', 0, 4) === 'RIFF' && b.toString('ascii', 8, 12) === 'WAVE') {
    const declared = b.readUInt32LE(4); if (declared !== 0xffffffff && declared + 8 > b.length) bad();
    let rate = 0, size = 0, alignment = 0;
    for (let p = 12; p + 8 <= b.length;) {
      let n = b.readUInt32LE(p + 4); const type = b.toString('ascii', p, p + 4);
      if (n === 0xffffffff && type === 'data') n = b.length - p - 8;
      if (p + 8 + n > b.length) bad();
      if (type === 'fmt ' && n >= 16) {
        const format = b.readUInt16LE(p + 8), channels = b.readUInt16LE(p + 10), sampleRate = b.readUInt32LE(p + 12), bits = b.readUInt16LE(p + 22);
        rate = b.readUInt32LE(p + 16); alignment = b.readUInt16LE(p + 20);
        if (![1, 3, 0xfffe].includes(format) || !channels || channels > 8 || sampleRate < 8000 || sampleRate > 192000 || ![8,16,24,32,64].includes(bits) || alignment !== channels * bits / 8 || rate !== sampleRate * alignment) bad();
      }
      if (type === 'data') size += n;
      p += 8 + n + (n % 2);
    }
    if (!alignment || size % alignment) bad(); duration = size / rate * 1000; mime = 'audio/wav'; extension = 'wav';
  } else if (b.length >= 32 && b.toString('ascii', 0, 4) === 'OggS') {
    let p = 0, samples = 0n, opus = false, preSkip = 0;
    while (p + 27 <= b.length) {
      if (b.toString('ascii', p, p + 4) !== 'OggS') bad(); const count = b[p + 26]!; if (p + 27 + count > b.length) bad();
      let length = 0; for (let i = 0; i < count; i++) length += b[p + 27 + i]!;
      const start = p + 27 + count; if (start + length > b.length) bad();
      if (b.toString('ascii', start, start + 8) === 'OpusHead' && length >= 19) { opus = true; preSkip = b.readUInt16LE(start + 10); }
      const granule = b.readBigUInt64LE(p + 6); if (granule !== 0xffffffffffffffffn && granule > samples) samples = granule;
      p = start + length;
    }
    if (!opus || p !== b.length) bad(); duration = (Number(samples) - preSkip) / 48; mime = 'audio/ogg'; extension = 'ogg';
  } else if (b.length >= 12 && b.toString('ascii', 4, 8) === 'ftyp') {
    let hasAudio = false, hasData = false;
    function boxes(start: number, end: number, depth = 0): void {
      if (depth > 8) bad();
      for (let p = start; p + 8 <= end;) {
        let n = b.readUInt32BE(p), header = 8; const type = b.toString('ascii', p + 4, p + 8);
        if (n === 1) { if (p + 16 > end) bad(); n = Number(b.readBigUInt64BE(p + 8)); header = 16; } else if (!n) n = end - p;
        if (n < header || p + n > end) bad(); const data = p + header;
        if (['moov', 'trak', 'mdia', 'minf', 'stbl'].includes(type)) boxes(data, p + n, depth + 1);
        if (type === 'hdlr' && n >= header + 12 && b.toString('ascii', data + 8, data + 12) === 'soun') hasAudio = true;
        if (type === 'mdat' && n > header) hasData = true;
        if (type === 'mdhd' && n >= header + 24) { const v = b[data]!, scaleAt = data + (v === 1 ? 20 : 12); if (scaleAt + (v === 1 ? 12 : 8) > p + n) bad(); const scale = b.readUInt32BE(scaleAt); const ticks = v === 1 ? Number(b.readBigUInt64BE(scaleAt + 4)) : b.readUInt32BE(scaleAt + 4); if (scale) duration = Math.max(duration, ticks / scale * 1000); }
        p += n;
      }
    }
    boxes(0, b.length); if (!hasAudio || !hasData) bad(); mime = 'audio/mp4'; extension = 'm4a';
  } else if (b.length >= 4 && b.readUInt32BE(0) === 0x1a45dfa3) {
    // EBML IDs retain marker bits; lengths remove them. Walk bounded containers.
    let scale = 1_000_000, ticks = 0, opus = false, vorbis = false, blocks = false, clusterTime = 0, measuredMs = 0;
    function vint(p: number, keep: boolean): { value: number; width: number } { const first = b[p]; if (!first) return bad(); let width = 1, mask = 128; while (!(first & mask)) { mask >>= 1; width++; } if (width > 8 || p + width > b.length) return bad(); let value = keep ? first : first & (mask - 1); for (let i = 1; i < width; i++) value = value * 256 + b[p + i]!; return { value, width }; }
    function ebml(start: number, end: number, depth = 0): void {
      if (depth > 8) bad();
      for (let p = start; p < end;) { const tag = vint(p, true); p += tag.width; const len = vint(p, false); p += len.width; const unknown = len.value === 2 ** (7 * len.width) - 1; const finish = unknown ? end : p + len.value; if (finish > end || finish < p) bad();
        if ([0x18538067, 0x1549a966, 0x1654ae6b, 0xae, 0x1f43b675, 0xa0].includes(tag.value)) ebml(p, finish, depth + 1);
        if (tag.value === 0x2ad7b1) { scale = 0; for (let i = p; i < finish; i++) scale = scale * 256 + b[i]!; }
        if (tag.value === 0x4489) ticks = finish - p === 4 ? b.readFloatBE(p) : finish - p === 8 ? b.readDoubleBE(p) : 0;
        if (tag.value === 0x86) { const codec = b.toString('ascii', p, finish); if (codec === 'A_OPUS') opus = true; if (codec === 'A_VORBIS') vorbis = true; }
        if (tag.value === 0xe7) { clusterTime = 0; for (let i = p; i < finish; i++) clusterTime = clusterTime * 256 + b[i]!; }
        if ([0xa3, 0xa1].includes(tag.value) && finish > p) {
          blocks = true; const track = vint(p, false), timestampAt = p + track.width;
          if (timestampAt + 4 > finish) bad();
          const flags = b[timestampAt + 2]!, packetAt = timestampAt + 3;
          if (!(flags & 6) && opus) {
            const toc = b[packetAt]!, config = toc >> 3;
            const frameMs = config >= 16 ? 2.5 * 2 ** (config & 3) : config >= 12 ? 10 * 2 ** (config & 1) : [10,20,40,60][config & 3]!;
            const count = (toc & 3) === 0 ? 1 : (toc & 3) === 3 ? (b[packetAt + 1] ?? 0) & 63 : 2;
            if (!count || count * frameMs > 120) bad();
            measuredMs = Math.max(measuredMs, (clusterTime + b.readInt16BE(timestampAt)) * scale / 1e6 + count * frameMs);
          }
        }
        p = finish;
      }
    }
    ebml(0, b.length); if ((!opus && !vorbis) || !blocks) bad(); duration = Math.max(ticks * scale / 1e6, measuredMs); mime = 'audio/webm'; extension = 'webm';
  } else {
    let p = 0, frames = 0;
    if (b.toString('ascii', 0, 3) === 'ID3' && b.length >= 10) p = 10 + ((b[6]! & 127) * 2 ** 21 + (b[7]! & 127) * 2 ** 14 + (b[8]! & 127) * 128 + (b[9]! & 127)) + ((b[5]! & 16) ? 10 : 0);
    while (p + 4 <= b.length) {
      if (b.toString('ascii', p, p + 3) === 'TAG' && b.length - p === 128) break;
      const h = b.readUInt32BE(p), version = (h >>> 19) & 3, layer = (h >>> 17) & 3, bi = (h >>> 12) & 15, si = (h >>> 10) & 3;
      if ((h >>> 21) !== 2047 || version === 1 || layer !== 1 || !bi || bi === 15 || si === 3) bad();
      const rate = [44100, 48000, 32000][si]! / (version === 3 ? 1 : version === 2 ? 2 : 4);
      const kbps = (version === 3 ? [0,32,40,48,56,64,80,96,112,128,160,192,224,256,320] : [0,8,16,24,32,40,48,56,64,80,96,112,128,144,160])[bi]!;
      const n = Math.floor((version === 3 ? 144 : 72) * kbps * 1000 / rate) + ((h >>> 9) & 1); if (p + n > b.length) bad();
      duration += (version === 3 ? 1152 : 576) / rate * 1000; frames++; p += n;
    }
    if (!frames || (p !== b.length && b.length - p !== 128)) bad(); mime = 'audio/mpeg'; extension = 'mp3';
  }
  if (!Number.isFinite(duration) || duration <= 0) bad();
  if (duration > MAX_DURATION) fail('too_large', 'Audio duration exceeds ten minutes.');
  return { mime, extension, durationMs: Math.round(duration) };
}

export function pcmWave(pcm: Uint8Array, sampleRate = 24000): Uint8Array {
  if (!pcm.length || pcm.length % 2) fail('upstream_unavailable', 'Speech provider returned invalid audio.');
  const b = Buffer.alloc(44 + pcm.length); b.write('RIFF'); b.writeUInt32LE(36 + pcm.length, 4); b.write('WAVEfmt ', 8); b.writeUInt32LE(16, 16); b.writeUInt16LE(1, 20); b.writeUInt16LE(1, 22); b.writeUInt32LE(sampleRate, 24); b.writeUInt32LE(sampleRate * 2, 28); b.writeUInt16LE(2, 32); b.writeUInt16LE(16, 34); b.write('data', 36); b.writeUInt32LE(pcm.length, 40); b.set(pcm, 44); return b;
}
/** Resample real mono LINEAR16 samples only when the provider's speed range is narrower. */
export function changePcmSpeed(input: Uint8Array, factor: number): Uint8Array {
  if (!input.length || input.length % 2 || !Number.isFinite(factor) || factor <= 0) fail('upstream_unavailable', 'Speech provider returned invalid PCM.');
  if (factor === 1) return input;
  const original = Buffer.from(input.buffer, input.byteOffset, input.byteLength), samples = original.length / 2, length = Math.floor(samples / factor);
  if (length * 2 > MAX_BYTES - 44) fail('too_large', 'Speech audio exceeds 25 MiB.');
  const result = Buffer.alloc(length * 2);
  for (let i = 0; i < length; i++) { const source = i * factor, left = Math.floor(source), fraction = source - left; const a = original.readInt16LE(Math.min(left, samples - 1) * 2), b = original.readInt16LE(Math.min(left + 1, samples - 1) * 2); result.writeInt16LE(Math.round(a + (b - a) * fraction), i * 2); }
  return result;
}
const accountSchema = z.object({ client_email: z.email(), private_key: z.string().min(1), project_id: z.string().min(1).max(128).regex(/^[a-z0-9][a-z0-9:._-]*$/).optional(), token_uri: z.literal('https://oauth2.googleapis.com/token').optional() });
type GoogleAccount = z.infer<typeof accountSchema>;
export function googleAssertion(account: GoogleAccount, now: number): string {
  const encode = (value: unknown) => Buffer.from(JSON.stringify(value)).toString('base64url');
  const seconds = Math.floor(now / 1000), unsigned = `${encode({ alg: 'RS256', typ: 'JWT' })}.${encode({ iss: account.client_email, scope: 'https://www.googleapis.com/auth/cloud-platform', aud: 'https://oauth2.googleapis.com/token', iat: seconds, exp: seconds + 3600 })}`;
  return `${unsigned}.${sign('RSA-SHA256', Buffer.from(unsigned), createPrivateKey(account.private_key)).toString('base64url')}`;
}
/** TTS cannot claim a completed voice artifact when the provider returned only digital silence. */
function waveHasSignal(input: Uint8Array): boolean {
  const b = Buffer.from(input.buffer, input.byteOffset, input.byteLength); let encoding = 0, bits = 0;
  for (let p = 12; p + 8 <= b.length;) {
    const declared = b.readUInt32LE(p + 4), size = Math.min(declared, b.length - p - 8), kind = b.toString('ascii', p, p + 4);
    if (kind === 'fmt ' && size >= 16) { encoding = b.readUInt16LE(p + 8); bits = b.readUInt16LE(p + 22); if (encoding === 0xfffe && size >= 40) encoding = b.readUInt16LE(p + 32); }
    if (kind === 'data' && encoding === 1) { for (let i = p + 8; i < p + 8 + size; i++) if (b[i] !== (bits === 8 ? 128 : 0)) return true; }
    if (kind === 'data' && encoding === 3 && (bits === 32 || bits === 64)) { const width = bits / 8; for (let i = p + 8; i + width <= p + 8 + size; i += width) { const sample = bits === 32 ? b.readFloatLE(i) : b.readDoubleLE(i); if (Number.isFinite(sample) && sample !== 0) return true; } }
    p += 8 + size + size % 2;
  }
  return false;
}

export function createAudioServices(services: BackendServices, overrides?: AudioOptions): AudioServices {
  if (overrides === undefined) { const existing = audioInstances.get(services); if (existing) return existing; }
  const options: AudioOptions = overrides ?? {}, env = options.env ?? process.env, request = options.fetch ?? fetch, timeout = options.timeoutMs ?? 120_000;
  const stt = env.LEMON_BOT_STT_PROVIDER, tts = env.LEMON_BOT_TTS_PROVIDER;
  let google: GoogleAccount | null = null;
  if (tts === 'google' && env.LEMON_BOT_GOOGLE_SERVICE_ACCOUNT_PATH) {
    try { const path = env.LEMON_BOT_GOOGLE_SERVICE_ACCOUNT_PATH; const stat = statSync(path); if (!stat.isFile() || (stat.mode & 0o077) || (process.getuid && stat.uid !== process.getuid())) throw new Error(); google = accountSchema.parse(JSON.parse(readFileSync(path, 'utf8'))); if (createPrivateKey(google.private_key).asymmetricKeyType !== 'rsa') throw new Error(); } catch { google = null; }
  }
  let token: { value: string; expiresAt: number } | null = null;
  let tokenRefresh: Promise<{ value: string; expiresAt: number }> | null = null;
  const capabilities = () => ({ stt: (stt === 'openai' && !!env.LEMON_BOT_OPENAI_API_KEY) || (stt === 'deepgram' && !!env.LEMON_BOT_DEEPGRAM_API_KEY), tts: (tts === 'openai' && !!env.LEMON_BOT_OPENAI_API_KEY) || (tts === 'elevenlabs' && !!env.LEMON_BOT_ELEVENLABS_API_KEY) || (tts === 'google' && !!google) });
  async function upstream(url: string, init: RequestInit, limit = MAX_BYTES, deadline = performance.now() + timeout): Promise<Uint8Array> {
    const remaining = Math.min(timeout, deadline - performance.now()); if (remaining <= 0) fail('upstream_unavailable', 'Audio provider request failed or timed out.', false);
    const controller = new AbortController(), timer = setTimeout(() => controller.abort(), remaining);
    try {
      const response = await request(url, { ...init, redirect: 'error', signal: controller.signal });
      if (!response.ok) { if ((url === 'https://texttospeech.googleapis.com/v1/text:synthesize' || url.startsWith('https://translate.googleapis.com/v3/projects/')) && response.status === 401 && token && new Headers(init.headers).get('Authorization') === `Bearer ${token.value}`) token = null; await response.body?.cancel(); fail('upstream_unavailable', 'Audio provider rejected the request.', false, { provider: url.includes('deepgram') ? 'deepgram' : url.includes('elevenlabs') ? 'elevenlabs' : url.includes('googleapis') ? 'google' : 'openai', status: response.status }); }
      if (!response.body) fail('upstream_unavailable', 'Audio provider returned an empty response.', false);
      const reader = response.body.getReader(), parts: Uint8Array[] = []; let size = 0;
      while (true) { const { value, done } = await reader.read(); if (done) break; size += value.length; if (size > limit) { await reader.cancel(); fail('upstream_unavailable', 'Audio provider response exceeded the permitted size.', false); } parts.push(value); }
      const result = new Uint8Array(size); let offset = 0; for (const part of parts) { result.set(part, offset); offset += part.length; } return result;
    } catch (error) { if (error instanceof ApiError) throw error; fail('upstream_unavailable', 'Audio provider request failed or timed out.', false); } finally { clearTimeout(timer); }
  }
  async function json(url: string, init: RequestInit, limit = 2 * 1024 * 1024, deadline?: number): Promise<unknown> { try { return JSON.parse(new TextDecoder().decode(await upstream(url, init, limit, deadline))); } catch (error) { if (error instanceof ApiError) throw error; fail('upstream_unavailable', 'Audio provider returned invalid JSON.', false); } }
  function scope(principal: Principal, conversationId?: string, sessionId?: string, requireActive = true): string | undefined {
    if (conversationId) services.auth.conversation(principal, conversationId);
    if (!sessionId) return conversationId;
    const session = services.store.get<P.VoiceSession>('voiceSessions', sessionId);
    if (!session || session.userId !== principal.userId) fail('not_found', 'Voice session not found.');
    services.auth.conversation(principal, session.conversationId);
    if (requireActive && session.state !== 'active') fail('conflict', 'Voice session is not active.');
    if (conversationId && session.conversationId !== conversationId) fail('invalid_request', 'Voice session belongs to another conversation.');
    return session.conversationId;
  }
  // Replay authorizes the original receipt; ending a call never authorizes another provider dispatch.
  async function authorizeReplay(principal: Principal, input: unknown, kind: 'speech' | 'transcription' | 'preview', botId?: string): Promise<void> {
    if (!(await services.integrations.effectivePolicy(principal, botId)).productAccess) fail('policy_denied', 'Product access is disabled for this account.');
    if (kind === 'preview') { parse(previewSchema, input); if (!botId) fail('invalid_request', 'Bot required.'); services.auth.bot(principal, botId); return; }
    if (kind === 'transcription') {
      const body = parse(transcriptionSchema, input), attachment = services.auth.attachment(principal, body.attachmentId);
      if (attachment.state !== 'ready') fail('not_found', 'Audio attachment is unavailable.');
      scope(principal, attachment.conversationId ?? undefined, body.voiceSessionId, false);
    } else {
      const body = parse(speechSchema, input); scope(principal, body.conversationId, body.voiceSessionId, false);
    }
  }
  async function transcribe(principal: Principal, input: unknown): Promise<P.Transcription> {
    const body = parse(transcriptionSchema, input), attachment = services.auth.attachment(principal, body.attachmentId);
    if (attachment.state !== 'ready') fail('not_found', 'Audio attachment is unavailable.');
    scope(principal, attachment.conversationId ?? undefined, body.voiceSessionId);
    if (body.voiceSessionId && !attachment.conversationId) fail('invalid_request', 'Voice transcription requires an attachment bound to its conversation.');
    const bytes = await services.attachments.bytes(attachment.id), info = inspectAudio(bytes);
    if (!(await services.integrations.effectivePolicy(principal)).productAccess) fail('policy_denied', 'Product access is disabled for this account.');
    services.auth.attachment(principal, attachment.id); scope(principal, attachment.conversationId ?? undefined, body.voiceSessionId);
    if (!capabilities().stt) fail('capability_unavailable', stt === 'openai' ? 'OpenAI transcription requires LEMON_BOT_OPENAI_API_KEY.' : stt === 'deepgram' ? 'Deepgram transcription requires LEMON_BOT_DEEPGRAM_API_KEY.' : 'Configure LEMON_BOT_STT_PROVIDER as openai or deepgram.');
    let output: P.Transcription;
    if (stt === 'openai') {
      const form = new FormData(); form.set('file', new Blob([Buffer.from(bytes)], { type: info.mime }), `audio.${info.extension}`); form.set('model', 'whisper-1'); form.set('response_format', 'verbose_json'); form.append('timestamp_granularities[]', 'segment'); if (body.language) form.set('language', body.language.split('-')[0]!);
      const data = parseProvider(z.object({ text: z.string().max(100_000), language: z.string().nullable().optional(), duration: z.number().nonnegative(), segments: z.array(z.object({ text: z.string(), start: z.number().nonnegative(), end: z.number().nonnegative() })).optional() }), await json('https://api.openai.com/v1/audio/transcriptions', { method: 'POST', headers: { Authorization: `Bearer ${env.LEMON_BOT_OPENAI_API_KEY}` }, body: form }));
      output = { text: data.text, language: data.language ?? body.language ?? null, durationMs: Math.round(data.duration * 1000), segments: (data.segments ?? []).map(s => ({ text: s.text, startMs: Math.round(s.start * 1000), endMs: Math.round(s.end * 1000) })) };
    } else {
      const query = new URLSearchParams({ model: 'nova-3', smart_format: 'true', ...(body.language ? { language: body.language } : { detect_language: 'true' }) });
      const data = parseProvider(z.object({ metadata: z.object({ duration: z.number().nonnegative() }), results: z.object({ channels: z.array(z.object({ detected_language: z.string().optional(), alternatives: z.array(z.object({ transcript: z.string().max(100_000), words: z.array(z.object({ word: z.string(), punctuated_word: z.string().optional(), start: z.number().nonnegative(), end: z.number().nonnegative() })).optional() })).min(1) })).min(1) }) }), await json(`https://api.deepgram.com/v1/listen?${query}`, { method: 'POST', headers: { Authorization: `Token ${env.LEMON_BOT_DEEPGRAM_API_KEY}`, 'Content-Type': info.mime }, body: Buffer.from(bytes) }));
      const channel = data.results.channels[0]!, result = channel.alternatives[0]!;
      output = { text: result.transcript, language: channel.detected_language ?? body.language ?? null, durationMs: Math.round(data.metadata.duration * 1000), segments: (result.words ?? []).map(w => ({ text: w.punctuated_word ?? w.word, startMs: Math.round(w.start * 1000), endMs: Math.round(w.end * 1000) })) };
    }
    if (!output.durationMs || output.durationMs > MAX_DURATION || output.segments.some(s => s.endMs < s.startMs || s.endMs > MAX_DURATION)) fail('upstream_unavailable', 'Transcription provider returned invalid audio timing.', false);
    if (!(await services.integrations.effectivePolicy(principal)).productAccess) fail('policy_denied', 'Product access is disabled for this account.');
    scope(principal, attachment.conversationId ?? undefined, body.voiceSessionId);
    services.auth.attachment(principal, attachment.id);
    return output;
  }
  async function speech(principal: Principal, input: unknown, provenance?: P.DeliverableProvenance): Promise<P.SpeechResult> {
    const body = parse(speechSchema, input), conversationId = scope(principal, body.conversationId, body.voiceSessionId);
    const botId = provenance?.botId ?? principal.botId ?? undefined;
    const bot = botId ? services.auth.bot(principal, botId) : null;
    if (provenance?.machineId && provenance.machineId !== bot?.machineId) fail('invalid_request', 'Speech provenance does not match the Bot machine.');
    if (!(await services.integrations.effectivePolicy(principal, botId)).productAccess) fail('policy_denied', 'Product access is disabled for this account.');
    scope(principal, conversationId, body.voiceSessionId);
    if (!capabilities().tts) fail('capability_unavailable', tts === 'openai' ? 'OpenAI speech requires LEMON_BOT_OPENAI_API_KEY.' : tts === 'elevenlabs' ? 'ElevenLabs speech requires LEMON_BOT_ELEVENLABS_API_KEY.' : tts === 'google' ? 'Google speech requires LEMON_BOT_GOOGLE_SERVICE_ACCOUNT_PATH with a private valid service-account file.' : 'Configure LEMON_BOT_TTS_PROVIDER as openai, elevenlabs or google.');
    const deadline = performance.now() + timeout;
    let bytes: Uint8Array;
    if (tts === 'openai') {
      const voice = body.voice.voiceId === 'default' ? 'alloy' : body.voice.voiceId;
      const customVoice = /^voice_[A-Za-z0-9_-]+$/.test(voice);
      if (!customVoice && !['alloy', 'ash', 'ballad', 'coral', 'echo', 'fable', 'nova', 'onyx', 'sage', 'shimmer', 'verse', 'marin', 'cedar'].includes(voice)) fail('invalid_request', 'Unsupported OpenAI voice.');
      bytes = await upstream('https://api.openai.com/v1/audio/speech', { method: 'POST', headers: { Authorization: `Bearer ${env.LEMON_BOT_OPENAI_API_KEY}`, 'Content-Type': 'application/json' }, body: JSON.stringify({ model: 'gpt-4o-mini-tts', input: body.text, voice: customVoice ? { id: voice } : voice, speed: body.voice.speed, response_format: 'wav', ...(body.voice.language ? { instructions: `Use ${body.voice.language} pronunciation. Read the supplied text verbatim without translating, adding or omitting content.` } : {}) }) }, MAX_BYTES, deadline);
    } else if (tts === 'elevenlabs') {
      const voice = body.voice.voiceId === 'default' ? '21m00Tcm4TlvDq8ikWAM' : body.voice.voiceId;
      if (!/^[A-Za-z0-9]{1,128}$/.test(voice)) fail('invalid_request', 'Unsupported ElevenLabs voice ID.');
      const providerSpeed = Math.max(0.7, Math.min(1.2, body.voice.speed));
      const pcm = await upstream(`https://api.elevenlabs.io/v1/text-to-speech/${voice}?output_format=pcm_24000`, { method: 'POST', headers: { 'xi-api-key': env.LEMON_BOT_ELEVENLABS_API_KEY!, 'Content-Type': 'application/json' }, body: JSON.stringify({ text: body.text, model_id: 'eleven_multilingual_v2', voice_settings: { speed: providerSpeed }, ...(body.voice.language ? { language_code: body.voice.language.split('-')[0] } : {}) }) }, MAX_BYTES, deadline);
      bytes = pcmWave(changePcmSpeed(pcm, body.voice.speed / providerSpeed));
    } else {
      if (!google) fail('capability_unavailable', 'Google TTS requires a private valid service-account file.');
      if (body.voice.language === null && !google.project_id) fail('capability_unavailable', 'Google automatic-language speech requires project_id in its private service-account file.');
      if (!token || token.expiresAt <= services.now() + 60_000) {
        if (!tokenRefresh) tokenRefresh = json('https://oauth2.googleapis.com/token', { method: 'POST', headers: { 'Content-Type': 'application/x-www-form-urlencoded' }, body: new URLSearchParams({ grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer', assertion: googleAssertion(google, services.now()) }) }, 2 * 1024 * 1024, deadline).then(value => {
          const result = parseProvider(z.object({ access_token: z.string().min(1), expires_in: z.number().int().min(61).max(3600), token_type: z.literal('Bearer') }), value);
          token = { value: result.access_token, expiresAt: services.now() + result.expires_in * 1000 }; return token;
        }).finally(() => { tokenRefresh = null; });
        token = await tokenRefresh;
      }
      const accessToken = token.value, voice = body.voice.voiceId; let languageCode = body.voice.language;
      if (languageCode === null) {
        if (!(await services.integrations.effectivePolicy(principal, botId)).productAccess) fail('policy_denied', 'Product access is disabled for this account.');
        scope(principal, conversationId, body.voiceSessionId);
        let detection: unknown;
        try { detection = await json(`https://translate.googleapis.com/v3/projects/${encodeURIComponent(google.project_id!)}/locations/global:detectLanguage`, { method: 'POST', headers: { Authorization: `Bearer ${accessToken}`, 'Content-Type': 'application/json' }, body: JSON.stringify({ content: body.text, mimeType: 'text/plain' }) }, 2 * 1024 * 1024, deadline); }
        catch (error) { if (error instanceof ApiError && error.details?.status === 403) fail('capability_unavailable', 'Google automatic-language speech requires Cloud Translation API and language-detection permission.'); throw error; }
        const result = parseProvider(z.object({ languages: z.array(z.object({ languageCode: language, confidence: z.number().min(0).max(1).optional() })).min(1) }), detection);
        languageCode = result.languages[0]!.languageCode;
        if (languageCode === 'und') fail('invalid_request', 'Google could not detect the speech language; select an explicit language.');
      }
      if (!/^[A-Za-z0-9-]{1,128}$/.test(voice)) fail('invalid_request', 'Unsupported Google voice ID.');
      const textParts: string[] = []; let part = '', partBytes = 0;
      for (const character of body.text) { const size = Buffer.byteLength(character); if (partBytes + size > 4800) { textParts.push(part); part = ''; partBytes = 0; } part += character; partBytes += size; }
      if (part) textParts.push(part);
      const waves: Buffer[] = []; let totalBytes = 0;
      for (const text of textParts) {
        if (!(await services.integrations.effectivePolicy(principal, botId)).productAccess) fail('policy_denied', 'Product access is disabled for this account.');
        scope(principal, conversationId, body.voiceSessionId);
        const result = parseProvider(z.object({ audioContent: z.string().min(1).max(36 * 1024 * 1024) }), await json('https://texttospeech.googleapis.com/v1/text:synthesize', { method: 'POST', headers: { Authorization: `Bearer ${accessToken}`, 'Content-Type': 'application/json' }, body: JSON.stringify({ input: { text }, voice: { languageCode, ...(voice === 'default' ? {} : { name: voice }) }, audioConfig: { audioEncoding: 'LINEAR16', speakingRate: body.voice.speed, sampleRateHertz: 24000 } }) }, 36 * 1024 * 1024, deadline));
        if (!/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(result.audioContent)) fail('upstream_unavailable', 'Google returned malformed audio.', false);
        const wave = Buffer.from(result.audioContent, 'base64'); totalBytes += wave.length;
        if (totalBytes > MAX_BYTES) fail('upstream_unavailable', 'Speech provider response exceeds 25 MiB.', false);
        try { if (inspectAudio(wave).mime !== 'audio/wav') throw new Error(); } catch { fail('upstream_unavailable', 'Google returned invalid LINEAR16 audio.', false); }
        waves.push(wave);
      }
      if (waves.length === 1) bytes = waves[0]!;
      else {
        const pcm: Buffer[] = [];
        for (const wave of waves) {
          let validFormat = false;
          for (let p = 12; p + 8 <= wave.length;) { const size = wave.readUInt32LE(p + 4), kind = wave.toString('ascii', p, p + 4); if (kind === 'fmt ' && size >= 16) validFormat = wave.readUInt16LE(p + 8) === 1 && wave.readUInt16LE(p + 10) === 1 && wave.readUInt32LE(p + 12) === 24000 && wave.readUInt16LE(p + 22) === 16; if (kind === 'data') pcm.push(wave.subarray(p + 8, p + 8 + size)); p += 8 + size + size % 2; }
          if (!validFormat) fail('upstream_unavailable', 'Google returned incompatible LINEAR16 chunks.', false);
        }
        bytes = pcmWave(Buffer.concat(pcm));
      }
    }
    let info: AudioInfo;
    try { info = inspectAudio(bytes); } catch { fail('upstream_unavailable', 'Speech provider returned invalid or oversized audio.', false); }
    if (info.mime !== 'audio/wav' || !waveHasSignal(bytes)) fail('upstream_unavailable', 'Speech provider returned unsupported audio or silence.', false);
    if (!(await services.integrations.effectivePolicy(principal, botId)).productAccess) fail('policy_denied', 'Product access is disabled for this account.');
    scope(principal, conversationId, body.voiceSessionId);
    const metadata: P.AttachmentUpload & Pick<P.Attachment, 'filename' | 'mime' | 'source' | 'provenance'> = { clientNonce: body.clientNonce, purpose: 'audio', ...(conversationId ? { conversationId } : {}), ...(botId ? { botId } : {}), filename: `speech.${info.extension}`, mime: info.mime, source: 'tts', provenance: { botId: botId ?? null, runId: provenance?.runId ?? null, machineId: provenance?.machineId ?? null, sourceEntryId: provenance?.sourceEntryId ?? null, generatedAtMs: services.now() } };
    const attachment = await services.attachments.create(principal, bytes, metadata);
    return { attachment, download: services.attachments.download(principal, attachment.id) };
  }
  const audio: AudioServices = { speech, transcribe, authorizeReplay, providerCapabilities: capabilities, inventory: () => [{ id: 'stt', provider: stt === 'openai' || stt === 'deepgram' ? stt : null, configured: capabilities().stt }, { id: 'tts', provider: tts === 'openai' || tts === 'elevenlabs' || tts === 'google' ? tts : null, configured: capabilities().tts }] };
  if (overrides === undefined) audioInstances.set(services, audio);
  return audio;
}
export function createAudioRoutes(services: BackendServices, options?: AudioOptions): Route[] {
  const audio = createAudioServices(services, options);
  const user = (principal: Principal | null) => { if (!principal) fail('unauthenticated', 'Authentication required.'); return principal; };
  return [
    { method: 'POST', path: '/v1/audio/transcriptions', auth: 'member', status: 200, authorizeReplay: c => audio.authorizeReplay(user(c.user), c.body, 'transcription'), handler: c => audio.transcribe(user(c.user), c.body) },
    { method: 'POST', path: '/v1/audio/speech', auth: 'member', status: 200, authorizeReplay: c => audio.authorizeReplay(user(c.user), c.body, 'speech'), handler: c => audio.speech(user(c.user), c.body) },
    { method: 'POST', path: '/v1/bots/:id/voice/preview', auth: 'member', status: 200, authorizeReplay: c => audio.authorizeReplay(user(c.user), c.body, 'preview', c.params.id!), handler: c => { const principal = user(c.user), bot = services.auth.bot(principal, c.params.id!), body = parse(previewSchema, c.body); return audio.speech(principal, { clientNonce: body.clientNonce, text: 'Hello, I’m your Lemon Bot teammate. Ready when you are.', voice: body.voice ?? bot.voice }, { botId: bot.id, machineId: null, runId: null, sourceEntryId: null, generatedAtMs: null }); } },
  ];
}
