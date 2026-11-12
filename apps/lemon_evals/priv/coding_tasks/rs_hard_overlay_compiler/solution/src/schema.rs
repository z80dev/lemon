use crate::{Constraint, Error, Kind, Rule, Schema};
use std::collections::{BTreeMap, BTreeSet};
pub fn index(schema: &Schema) -> Result<BTreeMap<String, &Rule>, Error> {
    let mut rules = BTreeMap::new();
    for rule in &schema.rules {
        if !crate::identifier::path(&rule.path) {
            return Err(Error::new("invalid-path", &rule.path));
        }
        if rules.insert(rule.path.clone(), rule).is_some() {
            return Err(Error::new("duplicate-rule", &rule.path));
        }
        let valid = match rule.kind {
            Kind::Integer { min, max } => min <= max,
            Kind::List { min, max } => min <= max,
            _ => true,
        };
        if !valid {
            return Err(Error::new("invalid-rule", &rule.path));
        }
    }
    for (index, constraint) in schema.constraints.iter().enumerate() {
        let valid = match constraint {
            Constraint::Requires { when, path } => {
                rules.contains_key(when) && rules.contains_key(path)
            }
            Constraint::Exclusive(paths) => {
                paths.len() >= 2
                    && paths.iter().collect::<BTreeSet<_>>().len() == paths.len()
                    && paths.iter().all(|path| rules.contains_key(path))
            }
        };
        if !valid {
            return Err(Error::new("invalid-constraint", index.to_string()));
        }
    }
    Ok(rules)
}
