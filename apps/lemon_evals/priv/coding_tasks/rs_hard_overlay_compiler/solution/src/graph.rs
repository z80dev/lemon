use crate::{Error, Layer};
use std::collections::{BTreeMap, BTreeSet};
pub fn validate<'a>(layers: &'a [Layer]) -> Result<BTreeMap<String, &'a Layer>, Error> {
    let mut nodes = BTreeMap::new();
    for layer in layers {
        if !crate::identifier::name(&layer.name) {
            return Err(Error::new("invalid-layer", &layer.name));
        }
        if nodes.insert(layer.name.clone(), layer).is_some() {
            return Err(Error::new("duplicate-layer", &layer.name));
        }
    }
    for (name, layer) in &nodes {
        let mut seen = BTreeSet::new();
        for parent in &layer.parents {
            if !nodes.contains_key(parent) {
                return Err(Error::new("missing-parent", format!("{name}->{parent}")));
            }
            if !seen.insert(parent) {
                return Err(Error::new("duplicate-parent", format!("{name}->{parent}")));
            }
        }
    }
    let mut remaining: BTreeMap<String, usize> = nodes
        .iter()
        .map(|(name, node)| (name.clone(), node.parents.len()))
        .collect();
    let mut reverse: BTreeMap<&str, Vec<&str>> = BTreeMap::new();
    for (name, node) in &nodes {
        for parent in &node.parents {
            reverse.entry(parent).or_default().push(name);
        }
    }
    let mut ready: BTreeSet<String> = remaining
        .iter()
        .filter(|(_, n)| **n == 0)
        .map(|(name, _)| name.clone())
        .collect();
    while let Some(name) = ready.iter().next().cloned() {
        ready.remove(&name);
        remaining.remove(&name);
        if let Some(users) = reverse.get(name.as_str()) {
            for user in users {
                let count = remaining.get_mut(*user).unwrap();
                *count -= 1;
                if *count == 0 {
                    ready.insert((*user).into());
                }
            }
        }
    }
    if let Some(name) = remaining.keys().next() {
        return Err(Error::new("cycle", name.clone()));
    }
    Ok(nodes)
}
pub fn linearize(nodes: &BTreeMap<String, &Layer>, target: &str) -> Result<Vec<String>, Error> {
    if !nodes.contains_key(target) {
        return Err(Error::new("unknown-layer", target));
    }
    fn visit(
        name: &str,
        nodes: &BTreeMap<String, &Layer>,
        seen: &mut BTreeSet<String>,
        order: &mut Vec<String>,
    ) {
        if !seen.insert(name.into()) {
            return;
        }
        for parent in &nodes[name].parents {
            visit(parent, nodes, seen, order);
        }
        order.push(name.into());
    }
    let mut order = Vec::new();
    visit(target, nodes, &mut BTreeSet::new(), &mut order);
    Ok(order)
}
