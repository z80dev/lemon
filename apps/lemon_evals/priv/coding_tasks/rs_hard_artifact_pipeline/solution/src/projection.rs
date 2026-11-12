use crate::{Error, Report};
use std::collections::BTreeMap;
pub fn outputs(report: &Report, ids: &[String]) -> Result<BTreeMap<String, String>, Error> {
    let mut selected = BTreeMap::new();
    for id in ids {
        let value = report
            .outputs
            .get(id)
            .ok_or_else(|| Error::new("not-output", id.clone()))?;
        selected.insert(id.clone(), value.clone());
    }
    Ok(selected)
}
