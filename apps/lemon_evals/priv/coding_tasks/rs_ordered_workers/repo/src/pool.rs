use crate::RunError;
pub fn run_ordered<T,R,E,F>(jobs: Vec<T>, workers: usize, work: F) -> Result<Vec<R>, RunError<E>>
where T: Send + 'static, R: Send + 'static, E: Send + 'static,
      F: Fn(T) -> Result<R,E> + Send + Sync + 'static {
    if workers == 0 { return Err(RunError::ZeroWorkers); }
    let mut results = Vec::new();
    for (index, job) in jobs.into_iter().enumerate() {
        results.push(work(job).map_err(|error| RunError::Job { index, error })?);
    }
    Ok(results)
}
