use crate::{Compiled, Error, Layer, Resolved, Schema};
pub fn compile(schema: &Schema, layers: &[Layer], target: &str) -> Result<Compiled, Error> {
    let rules = crate::schema::index(schema)?;
    let nodes = crate::graph::validate(layers)?;
    crate::validation::operations(&nodes, &rules)?;
    let order = crate::graph::linearize(&nodes, target)?;
    let merged = crate::merge::apply(&nodes, &order)?;
    for (path, rule) in &rules {
        if rule.required && !merged.values.contains_key(path) {
            return Err(Error::new("required", path.clone()));
        }
    }
    let expanded = crate::interpolation::expand(&merged, &rules)?;
    let mut values = std::collections::BTreeMap::new();
    for (path, (raw, references)) in expanded {
        let entry = &merged.values[&path];
        values.insert(
            path.clone(),
            Resolved {
                value: crate::typing::convert(rules[&path], &raw)?,
                origin: entry.origin.clone(),
                contributors: entry.contributors.clone(),
                references,
            },
        );
    }
    crate::constraints::check(schema, &values)?;
    Ok(Compiled {
        layers: order,
        values,
        tombstones: merged.tombstones,
    })
}
