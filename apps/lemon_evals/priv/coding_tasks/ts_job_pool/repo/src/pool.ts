import type { Job, JobResult, PoolOptions } from './types.ts';
export async function runJobs<T>(jobs: Job<T>[], options: PoolOptions): Promise<JobResult<T>[]> {
  const signal = options.signal ?? new AbortController().signal;
  return Promise.all(jobs.map(async job => {
    try { return {status: 'fulfilled' as const, value: await job.run(signal)}; }
    catch (reason) { return {status: 'rejected' as const, reason}; }
  }));
}
