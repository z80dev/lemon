# Ordered document workers

This crate runs owned jobs through a shared transformation and restores submission order.
The public API at crate root is:
```rust
pub fn run_ordered<T,R,E,F>(jobs: Vec<T>, workers: usize, work: F)
    -> Result<Vec<R>, RunError<E>>
where T: Send + 'static, R: Send + 'static, E: Send + 'static,
      F: Fn(T) -> Result<R,E> + Send + Sync + 'static;
```
`RunError<E>` derives Debug and PartialEq where E does, with variants
`ZeroWorkers`, `Job { index: usize, error: E }`, `Panic { index: usize }`.
Inputs/results/errors need not implement Clone, Copy or Default.

- workers == 0 returns ZeroWorkers, even for empty jobs; never call work in that case.
- Empty jobs with positive workers return Ok(empty).
- Positive workers runs every input exactly once, even after another job returns Err or panics.
  A job panic is caught and represented as Panic, without killing the worker or escaping the API.
  No errors/panic payloads are stringified or substituted for the original typed E.
- Limit simultaneous work calls to workers. When there are at least workers independent jobs
  blocked in work, all workers calls must be able to start without waiting for an earlier job
  to finish. For fewer jobs, all jobs must similarly be able to start. No serialized work lock.
- All work and all spawned threads finish before return, on success and failure alike.
- Success returns results in original input order, not completion order.
- If any jobs fail (Err or panic), return the failure with the smallest original zero-based input
  index, regardless of completion order or failure kind. Still run the rest and join all workers.
- Use only std, no unsafe. Thread creation/resource exhaustion is outside the input contract;
  tests use modest worker counts. Very large requested counts with few jobs should create
  no more workers than jobs.

Run `cargo test --offline`. No timing throughput comparisons are necessary; use channels and
explicit gates to coordinate independent tasks.

Shutdown drains the job queue, catches each job panic, collects indexed results, then joins every worker before selecting the earliest failure.
