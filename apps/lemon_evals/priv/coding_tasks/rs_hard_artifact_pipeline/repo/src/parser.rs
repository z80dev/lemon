use crate::{Artifact, Error, Manifest, Recipe};
pub fn parse(text: &str) -> Result<Manifest, Error> {
    let mut artifacts = Vec::new();
    for (index, line) in text.lines().enumerate() {
        if line.trim().is_empty() || line.starts_with('#') {
            continue;
        }
        let fail = || Error::new("parse", (index + 1).to_string());
        let fields: Vec<&str> = line.split('|').collect();
        if fields.len() != 3 {
            return Err(fail());
        }
        let (tag, value) = fields[1].split_once(':').ok_or_else(fail)?;
        let recipe = match tag {
            "source" => Recipe::Source(value.into()),
            "join" => Recipe::Join(value.into()),
            "replace" => {
                let (from, to) = value.split_once("=>").ok_or_else(fail)?;
                Recipe::Replace {
                    from: from.into(),
                    to: to.into(),
                }
            }
            "slice" => {
                let (start, end) = value.split_once(':').ok_or_else(fail)?;
                if start.is_empty()
                    || end.is_empty()
                    || !start.bytes().all(|b| b.is_ascii_digit())
                    || !end.bytes().all(|b| b.is_ascii_digit())
                {
                    return Err(fail());
                }
                Recipe::Slice {
                    start: start.parse().map_err(|_| fail())?,
                    end: end.parse().map_err(|_| fail())?,
                }
            }
            "fail" => Recipe::Fail(value.into()),
            _ => return Err(fail()),
        };
        artifacts.push(Artifact {
            id: fields[0].into(),
            recipe,
            deps: if fields[2].is_empty() {
                vec![]
            } else {
                fields[2].split(',').map(str::to_owned).collect()
            },
        });
    }
    Ok(Manifest { artifacts })
}
