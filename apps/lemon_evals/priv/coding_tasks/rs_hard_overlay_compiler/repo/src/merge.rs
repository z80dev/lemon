use crate::{Error, Layer, Op, Origin};
use std::collections::BTreeMap;
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum RawValue {
    Scalar(String),
    List(Vec<String>),
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RawEntry {
    pub value: RawValue,
    pub origin: Origin,
    pub contributors: Vec<Origin>,
}
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Merged {
    pub values: BTreeMap<String, RawEntry>,
    pub tombstones: BTreeMap<String, Origin>,
}
pub fn unique(values: &[String]) -> Vec<String> {
    let mut result = values.to_vec();
    result.dedup();
    result
}
pub fn apply(nodes: &BTreeMap<String, &Layer>, order: &[String]) -> Result<Merged, Error> {
    let mut merged = Merged::default();
    for name in order {
        for (operation, op) in nodes[name].operations.iter().enumerate() {
            let origin = Origin {
                layer: name.clone(),
                operation,
            };
            let path = op.path();
            match op {
                Op::Delete { .. } => {
                    merged.values.remove(path);
                    merged.tombstones.insert(path.into(), origin);
                }
                Op::Set { value, .. } => {
                    merged.values.insert(
                        path.into(),
                        RawEntry {
                            value: RawValue::Scalar(value.clone()),
                            origin: origin.clone(),
                            contributors: vec![origin],
                        },
                    );
                }
                Op::SetList { values, .. } => {
                    merged.values.insert(
                        path.into(),
                        RawEntry {
                            value: RawValue::List(unique(values)),
                            origin: origin.clone(),
                            contributors: vec![origin],
                        },
                    );
                }
                Op::Append { values, .. } => {
                    let entry = merged
                        .values
                        .entry(path.into())
                        .or_insert_with(|| RawEntry {
                            value: RawValue::List(vec![]),
                            origin: origin.clone(),
                            contributors: vec![origin],
                        });
                    if let RawValue::List(items) = &mut entry.value {
                        items.extend(values.iter().cloned());
                        items.dedup();
                    } else {
                        return Err(Error::new("operation-type", path));
                    }
                }
                Op::Remove { values, .. } => {
                    let entry = merged
                        .values
                        .get_mut(path)
                        .ok_or_else(|| Error::new("missing-value", path))?;
                    if let RawValue::List(items) = &mut entry.value {
                        items.retain(|item| !values.contains(item));
                    } else {
                        return Err(Error::new("operation-type", path));
                    }
                }
            }
        }
    }
    Ok(merged)
}
