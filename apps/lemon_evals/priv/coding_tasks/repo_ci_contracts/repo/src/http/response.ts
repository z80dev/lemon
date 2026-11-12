import { ApiError } from '../errors.ts';
import type { Response } from '../types.ts';
export function errorResponse(error: unknown): Response {
  if (error instanceof ApiError) {
    const status: Record<string, number> = { invalid: 400, missing: 404, conflict: 400, unauthorized: 401 };
    return { status: status[error.code] ?? 500, body: { error: error.code, message: error.message } };
  }
  return { status: 500, body: { error: 'internal', message: 'internal error' } };
}
