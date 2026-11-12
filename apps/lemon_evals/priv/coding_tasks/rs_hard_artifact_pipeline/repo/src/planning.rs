use crate::{Artifact, Error, Manifest, Plan, Request};
use std::collections::{BTreeMap, BTreeSet};
pub fn topological(
    nodes: &BTreeMap<String, &Artifact>,
    selected: &BTreeSet<String>,
) -> Result<Vec<String>, Error> {
    fn visit(
        id: &str,
        nodes: &BTreeMap<String, &Artifact>,
        seen: &mut BTreeSet<String>,
        order: &mut Vec<String>,
    ) {
        if !seen.insert(id.into()) {
            return;
        }
        for dep in &nodes[id].deps {
            visit(dep, nodes, seen, order);
        }
        order.push(id.into());
    }
    let mut seen = BTreeSet::new();
    let mut order = Vec::new();
    for id in selected {
        visit(id, nodes, &mut seen, &mut order);
    }
    Ok(order)
}
pub fn plan(manifest: &Manifest, request: &Request) -> Result<Plan, Error> {
    let nodes = crate::validation::validate(manifest)?;
    let mut selected = BTreeSet::new();
    fn collect(id: &str, nodes: &BTreeMap<String, &Artifact>, selected: &mut BTreeSet<String>) {
        if selected.insert(id.into()) {
            for dep in &nodes[id].deps {
                collect(dep, nodes, selected);
            }
        }
    }
    for id in &request.targets {
        if !nodes.contains_key(id) {
            return Err(Error::new("unknown-target", id));
        }
        collect(id, &nodes, &mut selected);
    }
    Ok(Plan {
        roots: request.targets.clone(),
        order: topological(&nodes, &selected)?,
    })
}
