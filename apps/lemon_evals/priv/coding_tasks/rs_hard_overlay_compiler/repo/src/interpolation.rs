use crate::merge::{Merged, RawValue};
use crate::{Error, Rule};
use std::collections::BTreeMap;
pub type Expanded = BTreeMap<String, (RawValue, Vec<String>)>;
pub fn expand<'a>(
    merged: &'a Merged,
    _rules: &'a BTreeMap<String, &'a Rule>,
) -> Result<Expanded, Error> {
    let mut expanded = BTreeMap::new();
    for (path, entry) in &merged.values {
        let mut references = Vec::new();
        let substitute = |text: &str, references: &mut Vec<String>| {
            let mut result = text.to_owned();
            for (key, source) in &merged.values {
                if let RawValue::Scalar(value) = &source.value {
                    let marker = format!("${{{key}}}");
                    if result.contains(&marker) {
                        result = result.replace(&marker, value);
                        references.push(key.clone());
                    }
                }
            }
            result
        };
        let value = match &entry.value {
            RawValue::Scalar(value) => RawValue::Scalar(substitute(value, &mut references)),
            RawValue::List(values) => RawValue::List(
                values
                    .iter()
                    .map(|value| substitute(value, &mut references))
                    .collect(),
            ),
        };
        expanded.insert(path.clone(), (value, references));
    }
    Ok(expanded)
}
