use crate::RunError;
use std::{collections::VecDeque, panic::{catch_unwind, AssertUnwindSafe}, sync::{Arc, Mutex, mpsc}, thread};
pub fn run_ordered<T,R,E,F>(jobs: Vec<T>, workers: usize, work: F) -> Result<Vec<R>, RunError<E>>
where T: Send + 'static, R: Send + 'static, E: Send + 'static,
      F: Fn(T) -> Result<R,E> + Send + Sync + 'static {
    if workers == 0 { return Err(RunError::ZeroWorkers); }
    let count = jobs.len();
    if count == 0 { return Ok(Vec::new()); }
    let queue = Arc::new(Mutex::new(jobs.into_iter().enumerate().collect::<VecDeque<_>>()));
    let work = Arc::new(work);
    let (tx, rx) = mpsc::channel();
    let mut handles = Vec::with_capacity(workers.min(count));
    for _ in 0..workers.min(count) {
        let queue = Arc::clone(&queue);
        let work = Arc::clone(&work);
        let tx = tx.clone();
        handles.push(thread::spawn(move || loop {
            let job = queue.lock().unwrap().pop_front();
            let Some((index, job)) = job else { break };
            let result = match catch_unwind(AssertUnwindSafe(|| work(job))) {
                Ok(Ok(value)) => Ok(value),
                Ok(Err(error)) => Err(RunError::Job { index, error }),
                Err(_) => Err(RunError::Panic { index }),
            };
            if tx.send((index,result)).is_err() { break; }
        }));
    }
    drop(tx);
    let mut ordered: Vec<Option<Result<R,RunError<E>>>> = (0..count).map(|_|None).collect();
    for (index,result) in rx { ordered[index] = Some(result); }
    for handle in handles { handle.join().expect("worker bookkeeping panicked"); }
    let mut output = Vec::with_capacity(count);
    for result in ordered { output.push(result.expect("worker omitted a result")?); }
    Ok(output)
}
