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
        for change in changes {
            match change {
                Change::Set { prefix, target } => { layer.insert(canonical(prefix)?,Some(target.clone())); }
                Change::Remove { prefix } => { layer.insert(canonical(prefix)?,None); }
            }
        }
        self.layers.push(layer);
        Ok(())
    }
    pub fn resolve(&self, path: &str) -> Result<Option<Resolved>, RouteError> {
        let key = canonical(path)?;
        for (i,layer) in self.layers.iter().enumerate().rev() {
            if let Some(target) = layer.get(&key) {
                return Ok(target.as_ref().map(|target| Resolved { prefix: key.clone(), target: target.clone(), remainder: String::new(), layer:i }));
            }
        }
        Ok(None)
    }
}
