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
    let mut fields = line.split('|');
    let number = fields.next().ok_or(ErrorKind::Format)?;
    if number.is_empty() || number.starts_with('0') || !number.bytes().all(|b| b.is_ascii_digit()) {
        return Err(ErrorKind::Format);
    }
    let sequence = number.parse::<u64>().map_err(|_| ErrorKind::Format)?;
    if sequence == u64::MAX { return Err(ErrorKind::Format); }
    let operation = fields.next().ok_or(ErrorKind::Format)?;
    let key = fields.next().ok_or(ErrorKind::Format)?;
    let value = fields.next();
    if fields.next().is_some() { return Err(ErrorKind::Format); }
    let op = match (operation, key, value) {
        ("BEGIN", id, None) if token(id) => Operation::Begin(id),
        ("PUT", key, Some(value)) if token(key) && !value.is_empty() => Operation::Put(key, value),
        ("DELETE", key, None) if token(key) => Operation::Delete(key),
        ("COMMIT", id, None) if token(id) => Operation::Commit(id),
        ("ROLLBACK", id, None) if token(id) => Operation::Rollback(id),
        _ => return Err(ErrorKind::Format),
    };
    Ok((sequence, op))
}
