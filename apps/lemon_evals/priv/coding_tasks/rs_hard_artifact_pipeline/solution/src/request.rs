use crate::{Error, Request};
pub fn parse(text: &str) -> Result<Request, Error> {
    let mut request = Request::default();
    for (index, line) in text.lines().enumerate() {
        if line.trim().is_empty() || line.starts_with('#') {
            continue;
        }
        let fail = || Error::new("request-parse", (index + 1).to_string());
        if let Some(id) = line.strip_prefix("target=") {
            request.targets.push(id.into());
        } else if let Some(value) = line.strip_prefix("override=") {
            let (id, value) = value.split_once('=').ok_or_else(fail)?;
            if request.overrides.insert(id.into(), value.into()).is_some() {
                return Err(fail());
            }
        } else {
            return Err(fail());
        }
    }
    Ok(request)
}
