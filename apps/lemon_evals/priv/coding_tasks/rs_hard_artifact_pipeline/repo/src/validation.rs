use crate::{Artifact, Error, Manifest};
use std::collections::BTreeMap;
pub fn validate(manifest: &Manifest) -> Result<BTreeMap<String, &Artifact>, Error> {
    let mut nodes = BTreeMap::new();
    for node in &manifest.artifacts {
        if nodes.insert(node.id.clone(), node).is_some() {
            return Err(Error::new("duplicate", &node.id));
        }
    }
    for node in &manifest.artifacts {
        for dep in &node.deps {
            if !nodes.contains_key(dep) {
                return Err(Error::new(
                    "missing-dependency",
                    format!("{}->{dep}", node.id),
                ));
            }
        }
    }
    Ok(nodes)
}
