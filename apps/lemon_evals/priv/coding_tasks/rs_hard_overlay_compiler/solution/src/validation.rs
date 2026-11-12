use crate::{Error, Kind, Layer, Op, Rule};
use std::collections::BTreeMap;
pub fn operations(
    nodes: &BTreeMap<String, &Layer>,
    rules: &BTreeMap<String, &Rule>,
) -> Result<(), Error> {
    for layer in nodes.values() {
        for op in &layer.operations {
            let path = op.path();
            if !crate::identifier::path(path) {
                return Err(Error::new("invalid-path", path));
            }
            if matches!(op, Op::Delete { .. }) {
                if !rules.keys().any(|key| crate::identifier::within(key, path)) {
                    return Err(Error::new("unknown-path", path));
                }
                continue;
            }
            let rule = rules
                .get(path)
                .ok_or_else(|| Error::new("unknown-path", path))?;
            let list = matches!(rule.kind, Kind::List { .. });
            if matches!(op, Op::Set { .. }) == list {
                return Err(Error::new("operation-type", path));
            }
        }
    }
    Ok(())
}
