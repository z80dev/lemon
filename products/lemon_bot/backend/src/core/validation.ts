import { z } from 'zod';
import { fail } from './errors';
export { z };
export const id = z.string().min(1).max(128).regex(/^[^/\u0000-\u0020]+$/);
export const nonce = z.string().min(16).max(128).regex(/^[A-Za-z0-9_-]+$/);
export const mutation = z.object({ clientNonce: nonce }).strict();
export const update = mutation.extend({ revision: z.number().int().positive().max(Number.MAX_SAFE_INTEGER) });
export const confirm = update.extend({ confirmationToken: z.string().min(16).max(512), confirmName: z.string().min(1).max(1024) });
export const voice = z.object({ voiceId:z.string().min(1).max(128), speed:z.number().min(0.5).max(2), language:z.string().min(2).max(64).nullable() }).strict();
export function parse<T>(schema: z.ZodType<T>, input: unknown): T { const result = schema.safeParse(input); if (!result.success) fail('invalid_request', 'Request has invalid or unsupported fields.'); return result.data; }
export function principal<T>(value: T | null): T { if (value === null) fail('unauthenticated', 'Sign in to continue.'); return value; }
export function boundedText(max: number, min = 0) { return z.string().min(min).max(max); }
export function queryObject(query: URLSearchParams): Record<string, string> { const value: Record<string,string> = {}; for (const [key,item] of query) { if (key in value) fail('invalid_request', 'Query parameters must not repeat.'); value[key] = item; } return value; }
