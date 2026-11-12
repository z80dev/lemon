use crate::{Artifact, Error, Manifest, Plan, Recipe, Request};
use std::collections::{BTreeMap, BTreeSet};
pub fn topological(
    nodes: &BTreeMap<String, &Artifact>,
    selected: &BTreeSet<String>,
) -> Result<Vec<String>, Error> {
    let mut remaining: BTreeMap<String, usize> = selected
        .iter()
        .map(|id| (id.clone(), nodes[id].deps.len()))
        .collect();
    let mut reverse: BTreeMap<&str, Vec<&str>> = BTreeMap::new();
    for id in selected {
        for dep in &nodes[id].deps {
            reverse.entry(dep).or_default().push(id);
        }
    }
    let mut ready: BTreeSet<String> = remaining
        .iter()
        .filter(|(_, n)| **n == 0)
        .map(|(id, _)| id.clone())
        .collect();
    let mut order = Vec::new();
    while let Some(id) = ready.iter().next().cloned() {
        ready.remove(&id);
        remaining.remove(&id);
        if let Some(users) = reverse.get(id.as_str()) {
            for user in users {
                let count = remaining.get_mut(*user).unwrap();
                *count -= 1;
                if *count == 0 {
                    ready.insert((*user).to_owned());
                }
            }
        }
        order.push(id);
    }
    if let Some(id) = remaining.keys().next() {
        return Err(Error::new("cycle", id.clone()));
    }
    Ok(order)
}
pub fn plan(manifest: &Manifest, request: &Request) -> Result<Plan, Error> {
    let nodes = crate::validation::validate(manifest)?;
    let roots: BTreeSet<String> = request.targets.iter().cloned().collect();
    for root in &roots {
        if !nodes.contains_key(root) {
            return Err(Error::new("unknown-target", root.clone()));
        }
    }
    for id in request.overrides.keys() {
        let node = nodes
            .get(id)
            .ok_or_else(|| Error::new("unknown-override", id.clone()))?;
        if !matches!(node.recipe, Recipe::Source(_)) {
            return Err(Error::new("not-source", id.clone()));
        }
    }
    let mut selected = BTreeSet::new();
    let mut pending: Vec<String> = roots.iter().cloned().collect();
    while let Some(id) = pending.pop() {
        if selected.insert(id.clone()) {
            pending.extend(nodes[&id].deps.iter().cloned());
        }
    }
    Ok(Plan {
        roots: roots.into_iter().collect(),
        order: topological(&nodes, &selected)?,
    })
}
