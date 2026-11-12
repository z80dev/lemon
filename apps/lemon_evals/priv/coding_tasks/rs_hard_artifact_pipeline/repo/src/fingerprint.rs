use crate::{Artifact, Recipe, Request};
use std::collections::BTreeMap;
pub fn key(node: &Artifact, request: &Request, _keys: &BTreeMap<String, String>) -> String {
    let content = match &node.recipe {
        Recipe::Source(text) => request.overrides.get(&node.id).unwrap_or(text).clone(),
        Recipe::Join(separator) => separator.clone(),
        Recipe::Replace { from, to } => format!("{from}=>{to}"),
        Recipe::Slice { start, end } => format!("{start}:{end}"),
        Recipe::Fail(message) => message.clone(),
    };
    crate::digest::hash(format!("{}:{content}", node.id).as_bytes())
}
