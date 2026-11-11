use crate::PathError;

pub(crate) fn segments(path: &str) -> Result<Vec<&str>, PathError> {
    if !path.starts_with('/') { return Err(PathError::NotAbsolute); }
    if path.chars().any(|c| c.is_control() || c == '\\') { return Err(PathError::InvalidCharacter); }
    let mut parts = Vec::new();
    for part in path.split('/') {
        match part {
            ".." => return Err(PathError::ParentSegment),
            "" | "." => (),
            _ => parts.push(part),
        }
    }
    Ok(parts)
}

pub(crate) fn prefix(parts: &[&str]) -> String {
    if parts.is_empty() { "/".to_owned() } else { format!("/{}", parts.join("/")) }
}
