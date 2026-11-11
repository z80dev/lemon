import { runJobs } from './pool.ts';
import type { ExportRecord, ExportReport, PoolOptions } from './types.ts';
export async function exportRecords(records: ExportRecord[], write: (record: ExportRecord, signal: AbortSignal) => string | PromiseLike<string>, options: PoolOptions): Promise<ExportReport> {
  const results = await runJobs(records.map(record => ({key: record.account, run: (signal: AbortSignal) => write(record, signal)})), options);
  return {
    receipts: results.flatMap(result => result.status === 'fulfilled' ? [result.value] : []),
    failed: results.flatMap((result, i) => result.status === 'rejected' ? [records[i].id] : []),
    skipped: results.flatMap((result, i) => result.status === 'aborted' ? [records[i].id] : [])
  };
}
