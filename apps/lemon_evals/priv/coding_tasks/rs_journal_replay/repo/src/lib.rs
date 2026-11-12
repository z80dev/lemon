mod engine;
mod record;

pub use engine::Journal;
use std::collections::BTreeMap;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Snapshot {
    pub values: BTreeMap<String, String>,
    pub next_sequence: u64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ErrorKind {
    Format,
    Sequence { expected: u64, actual: u64 },
    NestedTransaction,
    NoTransaction,
    TransactionMismatch,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ReplayError {
    pub line: usize,
    pub kind: ErrorKind,
}

pub fn replay(input: &str) -> Result<Snapshot, ReplayError> {
    let mut journal = Journal::new();
    for (index, line) in input.lines().enumerate() {
        journal.apply_line(line).map_err(|kind| ReplayError { line: index + 1, kind })?;
    }
    Ok(journal.finish())
}
