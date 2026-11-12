use crate::{Compiled, Value};
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Change {
    pub path: String,
    pub before: Option<Value>,
    pub after: Option<Value>,
}
pub fn between(before: &Compiled, after: &Compiled) -> Vec<Change> {
    let paths: std::collections::BTreeSet<&String> =
        before.values.keys().chain(after.values.keys()).collect();
    paths
        .into_iter()
        .filter_map(|path| {
            let a = before.values.get(path).map(|value| &value.value);
            let b = after.values.get(path).map(|value| &value.value);
            (a != b).then(|| Change {
                path: path.clone(),
                before: a.cloned(),
                after: b.cloned(),
            })
        })
        .collect()
}
