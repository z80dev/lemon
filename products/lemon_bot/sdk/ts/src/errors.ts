import type { ErrorCode, ErrorEnvelope, JSONObject, JSONValue } from '../../../contracts/protocol.ts';

export interface ErrorContext {
  status?: number;
  clientNonce?: string;
  resourceIds?: string[];
  cause?: unknown;
}

/** An uncertain mutation is not a failed mutation. Reconcile it with GET only. */
export class LemonBotError extends Error {
  readonly code: ErrorCode;
  readonly requestId: string;
  readonly retrySafe: boolean;
  readonly details?: JSONObject;
  readonly outcomeUnknown: boolean;
  readonly status: number;
  readonly clientNonce?: string;
  readonly resourceIds: readonly string[];
  readonly currentRevision?: number;
  readonly currentResource?: JSONValue;

  constructor(error: ErrorEnvelope['error'], context: ErrorContext = {}) {
    super(error.message, { cause: context.cause });
    this.name = 'LemonBotError';
    this.code = error.code;
    this.requestId = error.requestId;
    this.outcomeUnknown = error.code === 'outcome_unknown';
    this.retrySafe = this.outcomeUnknown ? false : error.retrySafe;
    this.details = error.details;
    this.status = context.status ?? 0;
    this.clientNonce = context.clientNonce;
    const ids = error.details?.resourceIds;
    const entryIds = error.details?.entryIds;
    const runIds = error.details?.runIds;
    const runId = error.details?.runId;
    const resourceId = error.details?.resourceId;
    this.resourceIds = [...new Set([
      ...(Array.isArray(ids) ? ids.filter((id): id is string => typeof id === 'string') : []),
      ...(Array.isArray(entryIds) ? entryIds.filter((id): id is string => typeof id === 'string') : []),
      ...(Array.isArray(runIds) ? runIds.filter((id): id is string => typeof id === 'string') : []),
      ...(typeof runId === 'string' ? [runId] : []),
      ...(typeof resourceId === 'string' ? [resourceId] : []),
      ...(context.resourceIds ?? []),
    ])];
    const revision = error.details?.currentRevision;
    if (typeof revision === 'number' && Number.isSafeInteger(revision) && revision > 0) {
      this.currentRevision = revision;
    }
    this.currentResource = error.details?.currentResource;
  }
}

export function localError(code: ErrorCode, message: string, context: ErrorContext = {}): LemonBotError {
  return new LemonBotError({ code, message, requestId: '', retrySafe: code !== 'outcome_unknown' }, context);
}

export function isErrorEnvelope(value: unknown): value is ErrorEnvelope {
  if (!value || typeof value !== 'object' || !('error' in value)) return false;
  const error = value.error;
  return !!error && typeof error === 'object' && 'code' in error && typeof error.code === 'string'
    && 'message' in error && typeof error.message === 'string'
    && 'requestId' in error && typeof error.requestId === 'string'
    && 'retrySafe' in error && typeof error.retrySafe === 'boolean';
}
