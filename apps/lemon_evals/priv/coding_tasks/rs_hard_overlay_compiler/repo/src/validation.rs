use crate::{Error, Layer, Op, Rule};
use std::collections::BTreeMap;
pub fn operations(
    nodes: &BTreeMap<String, &Layer>,
    rules: &BTreeMap<String, &Rule>,
) -> Result<(), Error> {
    for layer in nodes.values() {
        for op in &layer.operations {
            if !matches!(op, Op::Delete { .. }) && !rules.contains_key(op.path()) {
                return Err(Error::new("unknown-path", op.path()));
            }
        }
    }
    Ok(())
}
