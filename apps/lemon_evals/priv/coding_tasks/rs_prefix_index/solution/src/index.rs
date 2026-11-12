use std::collections::BTreeMap;
use crate::{Action, Lookup, PathError, RuleMatch, Scope};
use crate::node::Node;
use crate::path::{segments, prefix};

#[derive(Debug, Clone, Default)]
pub struct Index {
    roots: BTreeMap<Scope, Node>,
    rules: usize,
}

impl Index {
    pub fn new() -> Self { Self::default() }
    pub fn len(&self) -> usize { self.rules }
    pub fn is_empty(&self) -> bool { self.rules == 0 }

    pub fn set(&mut self, scope: Scope, path: &str, action: Action) -> Result<Option<Action>, PathError> {
        let parts = segments(path)?;
        let old = self.roots.entry(scope).or_default().insert(&parts, action);
        if old.is_none() { self.rules += 1; }
        Ok(old)
    }

    pub fn remove(&mut self, scope: Scope, path: &str) -> Result<Option<Action>, PathError> {
        let parts = segments(path)?;
        let Some(root) = self.roots.get_mut(&scope) else { return Ok(None); };
        let old = root.remove(&parts);
        if old.is_some() { self.rules -= 1; }
        if root.empty() { self.roots.remove(&scope); }
        Ok(old)
    }

    pub fn lookup(&self, tenant: u64, path: &str) -> Result<Lookup, PathError> {
        let parts = segments(path)?;
        let mut best: Option<(usize, Scope, &Action)> = None;
        let mut nodes_visited = 0;
        for scope in [Scope::Global, Scope::Tenant(tenant)] {
            let Some(mut node) = self.roots.get(&scope) else { continue; };
            nodes_visited += 1;
            if let Some(action) = &node.action {
                if best.as_ref().map_or(true, |(depth, _, _)| *depth == 0) {
                    best = Some((0, scope, action));
                }
            }
            for (index, part) in parts.iter().enumerate() {
                nodes_visited += 1;
                let Some(child) = node.children.get(*part) else { break; };
                node = child;
                let depth = index + 1;
                if let Some(action) = &node.action {
                    if best.as_ref().map_or(true, |(old_depth, _, _)| depth >= *old_depth) {
                        best = Some((depth, scope, action));
                    }
                }
            }
        }
        let matched = best.map(|(depth, scope, action)| RuleMatch {
            scope, prefix: prefix(&parts[..depth]), action: action.clone(),
        });
        Ok(Lookup { matched, nodes_visited })
    }
}
