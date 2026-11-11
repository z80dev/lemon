import type { Job, JobResult, PoolOptions } from './types.ts';
export async function runJobs<T>(jobs: Job<T>[], options: PoolOptions): Promise<JobResult<T>[]> {
  if (!Number.isInteger(options.concurrency) || options.concurrency <= 0) throw new RangeError('concurrency');
  if (jobs.length === 0) return [];
  const signal = options.signal ?? new AbortController().signal;
  return new Promise(resolve => {
    const results = new Array<JobResult<T>>(jobs.length);
    const state = jobs.map(() => 'pending');
    const activeKeys = new Set<string>();
    let active = 0;
    let remaining = jobs.length;
    function finish() {
      if (remaining === 0) {
        signal.removeEventListener('abort', onAbort);
        resolve(results);
      }
    }
    function onAbort() {
      for (let i = 0; i < jobs.length; i++) {
        if (state[i] !== 'pending') continue;
        state[i] = 'done';
        results[i] = {status: 'aborted', reason: signal.reason};
        remaining--;
      }
      finish();
    }
    function settle(index: number, result: JobResult<T>) {
      state[index] = 'done';
      results[index] = result;
      active--;
      remaining--;
      activeKeys.delete(jobs[index].key);
      pump();
      finish();
    }
    function pump() {
      if (signal.aborted) { onAbort(); return; }
      while (active < options.concurrency) {
        const index = jobs.findIndex((job, i) => state[i] === 'pending' && !activeKeys.has(job.key));
        if (index < 0) return;
        const job = jobs[index];
        state[index] = 'running';
        active++;
        activeKeys.add(job.key);
        let value: T | PromiseLike<T>;
        try { value = job.run(signal); }
        catch (reason) { value = Promise.reject(reason); }
        Promise.resolve(value).then(
          value => settle(index, {status: 'fulfilled', value}),
          reason => settle(index, {status: 'rejected', reason})
        );
        if (signal.aborted) { onAbort(); return; }
      }
    }
    signal.addEventListener('abort', onAbort, {once: true});
    pump();
  });
}
