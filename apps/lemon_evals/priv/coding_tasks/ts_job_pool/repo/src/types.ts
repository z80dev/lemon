export type Job<T> = {key: string; run: (signal: AbortSignal) => T | PromiseLike<T>};
export type JobResult<T> = {status: 'fulfilled'; value: T} | {status: 'rejected'; reason: unknown} | {status: 'aborted'; reason: unknown};
export type PoolOptions = {concurrency: number; signal?: AbortSignal};
export type ExportRecord = {id: string; account: string; contents: string};
export type ExportReport = {receipts: string[]; failed: string[]; skipped: string[]};
