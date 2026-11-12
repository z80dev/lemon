use std::collections::BTreeMap;
use crate::{Action, Lookup, PathError, RuleMatch, Scope};
use crate::path::{segments, prefix};

#[derive(Debug, Clone, Default)]
pub struct Index { rules: BTreeMap<(Scope, String), Action> }

impl Index {
    pub fn new() -> Self { Self::default() }
    pub fn len(&self) -> usize { self.rules.len() }
    pub fn is_empty(&self) -> bool { self.rules.is_empty() }

    pub fn set(&mut self, scope: Scope, path: &str, action: Action) -> Result<Option<Action>, PathError> {
        let key = prefix(&segments(path)?);
        Ok(self.rules.insert((scope, key), action))
    }

    pub fn remove(&mut self, scope: Scope, path: &str) -> Result<Option<Action>, PathError> {
        let key = prefix(&segments(path)?);
        Ok(self.rules.remove(&(scope, key)))
    }

    pub fn lookup(&self, tenant: u64, path: &str) -> Result<Lookup, PathError> {
        let query = prefix(&segments(path)?);
        let mut matched: Option<RuleMatch> = None;
        let mut nodes_visited = 0;
        for ((scope, candidate), action) in &self.rules {
            nodes_visited += 1;
            if *scope != Scope::Global && *scope != Scope::Tenant(tenant) { continue; }
            let ancestor = candidate == "/" || query == *candidate ||
                (query.starts_with(candidate) && query.as_bytes().get(candidate.len()) == Some(&b'/'));
            if !ancestor { continue; }
            let better = matched.as_ref().map_or(true, |old| {
                candidate.len() > old.prefix.len() ||
                (candidate.len() == old.prefix.len() && *scope == Scope::Tenant(tenant))
            });
            if better {
                matched = Some(RuleMatch { scope: *scope, prefix: candidate.clone(), action: action.clone() });
            }
        }
        Ok(Lookup { matched, nodes_visited })
    }
}
