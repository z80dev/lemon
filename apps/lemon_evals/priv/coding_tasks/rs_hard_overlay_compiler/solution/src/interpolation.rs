use crate::merge::{Merged, RawValue};
use crate::{Error, Rule};
use std::collections::{BTreeMap, BTreeSet};
pub type Expanded = BTreeMap<String, (RawValue, Vec<String>)>;
struct Resolver<'a> {
    merged: &'a Merged,
    rules: &'a BTreeMap<String, &'a Rule>,
    done: Expanded,
    visiting: BTreeSet<String>,
}
impl Resolver<'_> {
    fn text(
        &mut self,
        path: &str,
        input: &str,
        references: &mut BTreeSet<String>,
    ) -> Result<String, Error> {
        let mut output = String::new();
        let mut rest = input;
        while !rest.is_empty() {
            if let Some(tail) = rest.strip_prefix("$$") {
                output.push('$');
                rest = tail;
            } else if let Some(tail) = rest.strip_prefix("${") {
                let end = tail
                    .find('}')
                    .ok_or_else(|| Error::new("interpolation", path))?;
                let reference = &tail[..end];
                if !self.merged.values.contains_key(reference) {
                    return Err(Error::new("reference", format!("{path}->{reference}")));
                }
                if !self.rules[path].secret && self.rules[reference].secret {
                    return Err(Error::new("secret-flow", format!("{path}->{reference}")));
                }
                let (value, nested) = self.resolve(reference)?;
                match value {
                    RawValue::Scalar(value) => output.push_str(&value),
                    RawValue::List(_) => {
                        return Err(Error::new("reference-type", format!("{path}->{reference}")))
                    }
                }
                references.insert(reference.into());
                references.extend(nested);
                rest = &tail[end + 1..];
            } else {
                let ch = rest.chars().next().unwrap();
                output.push(ch);
                rest = &rest[ch.len_utf8()..];
            }
        }
        Ok(output)
    }
    fn resolve(&mut self, path: &str) -> Result<(RawValue, Vec<String>), Error> {
        if let Some(value) = self.done.get(path) {
            return Ok(value.clone());
        }
        if !self.visiting.insert(path.into()) {
            return Err(Error::new("interpolation-cycle", path));
        }
        let raw = self.merged.values[path].value.clone();
        let mut references = BTreeSet::new();
        let value = match raw {
            RawValue::Scalar(value) => {
                RawValue::Scalar(self.text(path, &value, &mut references)?)
            }
            RawValue::List(items) => {
                let values: Vec<String> = items
                    .iter()
                    .map(|value| self.text(path, value, &mut references))
                    .collect::<Result<_, _>>()?;
                RawValue::List(crate::merge::unique(&values))
            }
        };
        self.visiting.remove(path);
        let result = (value, references.into_iter().collect());
        self.done.insert(path.into(), result.clone());
        Ok(result)
    }
}
pub fn expand<'a>(
    merged: &'a Merged,
    rules: &'a BTreeMap<String, &'a Rule>,
) -> Result<Expanded, Error> {
    let mut resolver = Resolver {
        merged,
        rules,
        done: BTreeMap::new(),
        visiting: BTreeSet::new(),
    };
    for path in merged.values.keys() {
        resolver.resolve(path)?;
    }
    Ok(resolver.done)
}
