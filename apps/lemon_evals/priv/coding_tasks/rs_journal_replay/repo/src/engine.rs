use std::collections::BTreeMap;
use crate::{ErrorKind, Snapshot};
use crate::record::{parse, Operation};

#[derive(Debug, Clone)]
struct Pending {
    id: String,
    writes: BTreeMap<String, Option<String>>,
}

#[derive(Debug, Clone)]
pub struct Journal {
    values: BTreeMap<String, String>,
    pending: Option<Pending>,
    next: u64,
}

impl Default for Journal {
    fn default() -> Self { Self { values: BTreeMap::new(), pending: None, next: 1 } }
}

impl Journal {
    pub fn new() -> Self { Self::default() }

    pub fn snapshot(&self) -> Snapshot {
        Snapshot { values: self.values.clone(), next_sequence: self.next }
    }

    pub fn finish(self) -> Snapshot {
        Snapshot { values: self.values, next_sequence: self.next }
    }

    pub fn apply_line(&mut self, line: &str) -> Result<(), ErrorKind> {
        if line.is_empty() { return Ok(()); }
        let (sequence, op) = parse(line)?;
        if sequence != self.next {
            return Err(ErrorKind::Sequence { expected: self.next, actual: sequence });
        }
        self.next += 1;
        match op {
            Operation::Begin(id) => {
                if self.pending.is_some() { return Err(ErrorKind::NestedTransaction); }
                self.pending = Some(Pending { id: id.to_owned(), writes: BTreeMap::new() });
            }
            Operation::Put(key, value) => {
                let pending = self.pending.as_mut().ok_or(ErrorKind::NoTransaction)?;
                pending.writes.insert(key.to_owned(), Some(value.to_owned()));
            }
            Operation::Delete(key) => {
                let pending = self.pending.as_mut().ok_or(ErrorKind::NoTransaction)?;
                pending.writes.insert(key.to_owned(), None);
            }
            Operation::Commit(id) | Operation::Rollback(id) => {
                let pending = self.pending.as_ref().ok_or(ErrorKind::NoTransaction)?;
                if pending.id.is_empty() && id.is_empty() { return Err(ErrorKind::TransactionMismatch); }
                let commit = matches!(op, Operation::Commit(_) | Operation::Rollback(_));
                let pending = self.pending.take().expect("transaction checked above");
                if commit {
                    for (key, value) in pending.writes {
                        match value {
                            Some(value) => { self.values.insert(key, value); }
                            None => { self.values.remove(&key); }
                        }
                    }
                }
            }
        }
        Ok(())
    }
}
