use crate::ErrorKind;

#[derive(Clone, Copy)]
pub(crate) enum Operation<'a> {
    Begin(&'a str),
    Put(&'a str, &'a str),
    Delete(&'a str),
    Commit(&'a str),
    Rollback(&'a str),
}

fn token(s: &str) -> bool {
    !s.is_empty() && s.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
}

pub(crate) fn parse(line: &str) -> Result<(u64, Operation<'_>), ErrorKind> {
    if line.contains(['\r', '\n']) { return Err(ErrorKind::Format); }
    let fields: Vec<_> = line.split('|').collect();
    let number = fields[0];
    if number.is_empty() || number.starts_with('0') || !number.bytes().all(|b| b.is_ascii_digit()) {
        return Err(ErrorKind::Format);
    }
    let sequence = number.parse::<u64>().map_err(|_| ErrorKind::Format)?;
    if sequence == u64::MAX { return Err(ErrorKind::Format); }
    let op = match fields.as_slice() {
        [_, "BEGIN", id] if token(id) => Operation::Begin(id),
        [_, "PUT", key, value] if token(key)  => Operation::Put(key, value),
        [_, "DELETE", key] if token(key) => Operation::Delete(key),
        [_, "COMMIT", id] if token(id) => Operation::Commit(id),
        [_, "ROLLBACK", id] if token(id) => Operation::Rollback(id),
        _ => return Err(ErrorKind::Format),
    };
    Ok((sequence, op))
}
