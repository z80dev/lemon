use crate::{Artifact, Recipe, Request};
use std::collections::BTreeMap;
pub fn key(node: &Artifact, request: &Request, keys: &BTreeMap<String, String>) -> String {
    let mut parts = vec![node.id.clone()];
    match &node.recipe {
        Recipe::Source(text) => {
            parts.push("source".into());
            parts.push(request.overrides.get(&node.id).unwrap_or(text).clone());
        }
        Recipe::Join(sep) => {
            parts.push("join".into());
            parts.push(sep.clone());
        }
        Recipe::Replace { from, to } => {
            parts.extend(["replace".into(), from.clone(), to.clone()]);
        }
        Recipe::Slice { start, end } => {
            parts.extend(["slice".into(), start.to_string(), end.to_string()]);
        }
        Recipe::Fail(message) => {
            parts.extend(["fail".into(), message.clone()]);
        }
    }
    for dep in &node.deps {
        parts.push(dep.clone());
        parts.push(keys[dep].clone());
    }
    crate::digest::fields(&parts)
}
