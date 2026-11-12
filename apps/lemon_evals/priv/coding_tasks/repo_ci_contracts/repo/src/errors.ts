export class ApiError extends Error {
  code: string;
  constructor(code: string, message: string) { super(message); this.code = code; }
}
export function invalid(message: string): never { throw new ApiError('invalid', message); }
export function missing(message: string): never { throw new ApiError('missing', message); }
export function conflict(message: string): never { throw new ApiError('conflict', message); }
