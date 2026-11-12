use crate::{Constraint, Error, Kind, Rule, Schema};
fn integer(text: &str) -> Option<i64> {
    let digits = text.strip_prefix('-').unwrap_or(text);
    if digits.is_empty() || !digits.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    text.parse().ok()
}
fn size(text: &str) -> Option<usize> {
    if text.is_empty() || !text.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    text.parse().ok()
}
pub fn parse(text: &str) -> Result<Schema, Error> {
    let mut schema = Schema::default();
    for (index, line) in text.lines().enumerate() {
        if line.trim().is_empty() || line.starts_with('#') {
            continue;
        }
        let fail = || Error::new("schema-parse", (index + 1).to_string());
        let fields: Vec<&str> = line.split('|').collect();
        match fields.as_slice() {
            ["!requires", when, path] => schema.constraints.push(Constraint::Requires {
                when: (*when).into(),
                path: (*path).into(),
            }),
            ["!exclusive", paths] => {
                schema
                    .constraints
                    .push(Constraint::Exclusive(if paths.is_empty() {
                        vec![]
                    } else {
                        paths.split(',').map(str::to_owned).collect()
                    }))
            }
            [path, kind, presence, visibility] => {
                let parts: Vec<&str> = kind.split(':').collect();
                let kind = match parts.as_slice() {
                    ["text"] => Kind::Text { nonempty: false },
                    ["nonempty"] => Kind::Text { nonempty: true },
                    ["bool"] => Kind::Boolean,
                    ["int", min, max] => Kind::Integer {
                        min: integer(min).ok_or_else(fail)?,
                        max: integer(max).ok_or_else(fail)?,
                    },
                    ["list", min, max] => Kind::List {
                        min: size(min).ok_or_else(fail)?,
                        max: size(max).ok_or_else(fail)?,
                    },
                    _ => return Err(fail()),
                };
                let required = match *presence {
                    "required" => true,
                    "optional" => false,
                    _ => return Err(fail()),
                };
                let secret = match *visibility {
                    "secret" => true,
                    "public" => false,
                    _ => return Err(fail()),
                };
                schema.rules.push(Rule {
                    path: (*path).into(),
                    kind,
                    required,
                    secret,
                });
            }
            _ => return Err(fail()),
        }
    }
    Ok(schema)
}
