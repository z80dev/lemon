import type { ErrorCode, ErrorEnvelope, JSONObject } from '../../../contracts/protocol';
export class ApiError extends Error {
  constructor(public code: ErrorCode, message: string, public retrySafe = true, public details?: JSONObject) { super(message); this.name = 'ApiError'; }
}
export function fail(code: ErrorCode, message: string, retrySafe = true, details?: JSONObject): never { throw new ApiError(code, message, retrySafe, details); }
export const statusFor: Record<ErrorCode, number> = { invalid_request:400, unauthenticated:401, forbidden:403, policy_denied:403, not_found:404, conflict:409, nonce_conflict:409, revision_conflict:409, confirmation_required:409, outcome_unknown:409, expired:410, cursor_expired:410, too_large:413, unsupported_media:415, rate_limited:429, machine_offline:503, upstream_unavailable:503, capability_unavailable:503, internal_error:500 };
export function errorEnvelope(error: unknown, requestId: string): ErrorEnvelope {
  const known = error instanceof ApiError ? error : new ApiError('internal_error', 'An unexpected backend error occurred.', false);
  return { error: { code: known.code, message: known.message.slice(0, 512), requestId, retrySafe: known.retrySafe, ...(known.details ? { details: known.details } : {}) } };
}
