use crate::{Error, Layer, Op};
fn items(text: &str) -> Vec<String> {
    if text.is_empty() {
        vec![]
    } else {
        text.split(',').map(str::to_owned).collect()
    }
}
pub fn parse(text: &str) -> Result<Vec<Layer>, Error> {
    let mut layers: Vec<Layer> = Vec::new();
    let mut parents_seen = false;
    for (index, line) in text.lines().enumerate() {
        if line.trim().is_empty() || line.starts_with('#') {
            continue;
        }
        let fail = || Error::new("layer-parse", (index + 1).to_string());
        if line.starts_with('[') && line.ends_with(']') {
            layers.push(Layer {
                name: line[1..line.len() - 1].into(),
                parents: vec![],
                operations: vec![],
            });
            parents_seen = false;
            continue;
        }
        let layer = layers.last_mut().ok_or_else(fail)?;
        if let Some(parents) = line.strip_prefix("parents=") {
            if parents_seen || !layer.operations.is_empty() {
                return Err(fail());
            }
            parents_seen = true;
            layer.parents = items(parents);
            continue;
        }
        let fields: Vec<&str> = line.split('|').collect();
        let op = match fields.as_slice() {
            ["set", path, value] => Op::Set {
                path: (*path).into(),
                value: (*value).into(),
            },
            ["list", path, values] => Op::SetList {
                path: (*path).into(),
                values: items(values),
            },
            ["append", path, values] => Op::Append {
                path: (*path).into(),
                values: items(values),
            },
            ["remove", path, values] => Op::Remove {
                path: (*path).into(),
                values: items(values),
            },
            ["delete", path] => Op::Delete {
                path: (*path).into(),
            },
            _ => return Err(fail()),
        };
        layer.operations.push(op);
    }
    Ok(layers)
}
