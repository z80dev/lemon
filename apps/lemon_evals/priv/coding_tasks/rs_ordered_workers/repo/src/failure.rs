#[derive(Debug, PartialEq)]
pub enum RunError<E> {
    ZeroWorkers,
    Job { index: usize, error: E },
    Panic { index: usize },
}
