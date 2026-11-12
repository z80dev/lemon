use crate::{Error, Layer};
use std::collections::{BTreeMap, BTreeSet};
pub fn validate(layers: &[Layer]) -> Result<BTreeMap<String, &Layer>, Error> {
    let mut nodes = BTreeMap::new();
    for layer in layers {
        if nodes.insert(layer.name.clone(), layer).is_some() {
            return Err(Error::new("duplicate-layer", &layer.name));
        }
    }
    for (name, layer) in &nodes {
        for parent in &layer.parents {
            if !nodes.contains_key(parent) {
                return Err(Error::new("missing-parent", format!("{name}->{parent}")));
            }
        }
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
        active: &mut BTreeSet<String>,
        order: &mut Vec<String>,
    ) -> Result<(), Error> {
        if !active.insert(name.into()) {
            return Err(Error::new("cycle", name));
        }
        for parent in &nodes[name].parents {
            visit(parent, nodes, active, order)?;
        }
        active.remove(name);
        order.push(name.into());
        Ok(())
    }
    let mut order = Vec::new();
    visit(target, nodes, &mut BTreeSet::new(), &mut order)?;
    Ok(order)
}
