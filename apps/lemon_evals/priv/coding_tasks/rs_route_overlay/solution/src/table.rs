use std::collections::BTreeMap;
use crate::{Change, Resolved, RouteError};
use crate::path::canonical;
#[derive(Default)]
pub struct RouteTable { layers: Vec<BTreeMap<String, Option<String>>> }
impl RouteTable {
    pub fn new() -> Self { Self::default() }
    pub fn depth(&self) -> usize { self.layers.len() }
    pub fn pop_layer(&mut self) -> bool { self.layers.pop().is_some() }
    pub fn apply_layer(&mut self, changes: &[Change]) -> Result<(), RouteError> {
        let mut layer = BTreeMap::new();
        for (index, change) in changes.iter().enumerate() {
            match change {
                Change::Set { prefix, target } => {
                    let key = canonical(prefix)?;
                    if target.is_empty() { return Err(RouteError::EmptyTarget { index }); }
                    layer.insert(key, Some(target.clone()));
                }
                Change::Remove { prefix } => { layer.insert(canonical(prefix)?, None); }
            }
        }
        self.layers.push(layer);
        Ok(())
    }
    pub fn resolve(&self, path: &str) -> Result<Option<Resolved>, RouteError> {
        let key = canonical(path)?;
        let mut seen = std::collections::BTreeSet::new();
        let mut best: Option<Resolved> = None;
        for (i,layer) in self.layers.iter().enumerate().rev() {
            for (prefix,target) in layer {
                if !seen.insert(prefix.as_str()) { continue; }
                let Some(target) = target else { continue };
                let matched = prefix == "/" || key == *prefix || key.strip_prefix(prefix).is_some_and(|s| s.starts_with('/'));
                if matched && best.as_ref().is_none_or(|b| prefix.len() > b.prefix.len()) {
                    let remainder = if prefix == "/" { &key[1..] } else { key[prefix.len()..].trim_start_matches('/') };
                    best = Some(Resolved { prefix: prefix.clone(),target:target.clone(),remainder:remainder.into(),layer:i });
                }
            }
        }
        Ok(best)
    }
}
