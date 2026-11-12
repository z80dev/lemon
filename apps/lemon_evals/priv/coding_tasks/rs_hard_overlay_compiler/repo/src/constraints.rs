use crate::{Constraint, Error, Resolved, Schema};
use std::collections::BTreeMap;
pub fn check(schema: &Schema, values: &BTreeMap<String, Resolved>) -> Result<(), Error> {
    for constraint in &schema.constraints {
        match constraint {
            Constraint::Requires { when, path } => {
                if values.contains_key(when) && !values.contains_key(path) {
                    return Err(Error::new("requires", format!("{when}->{path}")));
                }
            }
            Constraint::Exclusive(paths) => {
                let mut present: Vec<&str> = paths
                    .iter()
                    .filter(|path| values.contains_key(*path))
                    .map(String::as_str)
                    .collect();
                present.sort();
                if present.len() > 1 {
                    return Err(Error::new("exclusive", present.join(",")));
                }
            }
        }
    }
    Ok(())
}
