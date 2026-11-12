use crate::{Compiled, Error};
pub fn path(compiled: &Compiled, path: &str) -> Result<String, Error> {
    let value = compiled
        .values
        .get(path)
        .ok_or_else(|| Error::new("not-found", path))?;
    let contributors: Vec<String> = value
        .contributors
        .iter()
        .map(|origin| format!("{}:{}", origin.layer, origin.operation))
        .collect();
    Ok(format!(
        "origin={}:{};contributors={};references={}",
        value.origin.layer,
        value.origin.operation,
        contributors.join(","),
        value.references.join(",")
    ))
}
