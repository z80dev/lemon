use crate::{Artifact, Error, Manifest, Recipe};
use std::collections::{BTreeMap, BTreeSet};
pub fn validate(manifest: &Manifest) -> Result<BTreeMap<String, &Artifact>, Error> {
    let mut nodes = BTreeMap::new();
    for node in &manifest.artifacts {
        if !crate::identifier::valid(&node.id) {
            return Err(Error::new("invalid-id", &node.id));
        }
        if nodes.insert(node.id.clone(), node).is_some() {
            return Err(Error::new("duplicate", &node.id));
        }
    }
    for (id, node) in &nodes {
        let mut seen = BTreeSet::new();
        for dep in &node.deps {
            if !nodes.contains_key(dep) {
                return Err(Error::new("missing-dependency", format!("{id}->{dep}")));
            }
            if !seen.insert(dep) {
                return Err(Error::new("duplicate-dependency", format!("{id}->{dep}")));
            }
        }
        let valid = match &node.recipe {
            Recipe::Source(_) => node.deps.is_empty(),
            Recipe::Join(_) => true,
            Recipe::Replace { from, .. } => node.deps.len() == 1 && !from.is_empty(),
            Recipe::Slice { start, end } => node.deps.len() == 1 && start <= end,
            Recipe::Fail(_) => true,
        };
        if !valid {
            return Err(Error::new("invalid-recipe", id.clone()));
        }
    }
    let all: BTreeSet<String> = nodes.keys().cloned().collect();
    crate::planning::topological(&nodes, &all)?;
    Ok(nodes)
}
