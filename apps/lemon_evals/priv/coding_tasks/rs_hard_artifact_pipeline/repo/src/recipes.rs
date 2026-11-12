use crate::{Artifact, Error, Recipe, Request};
pub fn execute(node: &Artifact, request: &Request, inputs: &[&str]) -> Result<String, Error> {
    match &node.recipe {
        Recipe::Source(value) => Ok(request.overrides.get(&node.id).unwrap_or(value).clone()),
        Recipe::Join(separator) => Ok(inputs.join(separator)),
        Recipe::Replace { from, to } => Ok(inputs[0].replacen(from, to, 1)),
        Recipe::Slice { start, end } => {
            let bytes = inputs[0].as_bytes();
            if start > end || *end > bytes.len() {
                return Err(Error::new("range", &node.id));
            }
            Ok(String::from_utf8_lossy(&bytes[*start..*end]).into_owned())
        }
        Recipe::Fail(message) => Err(Error::new("execution", format!("{}:{message}", node.id))),
    }
}
