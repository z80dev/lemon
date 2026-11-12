use crate::{Artifact, Error, Recipe, Request};
pub fn execute(node: &Artifact, request: &Request, inputs: &[&str]) -> Result<String, Error> {
    match &node.recipe {
        Recipe::Source(value) => Ok(request.overrides.get(&node.id).unwrap_or(value).clone()),
        Recipe::Join(separator) => Ok(inputs.join(separator)),
        Recipe::Replace { from, to } => Ok(inputs[0].replace(from, to)),
        Recipe::Slice { start, end } => {
            let chars: Vec<char> = inputs[0].chars().collect();
            if *end > chars.len() {
                return Err(Error::new("range", &node.id));
            }
            Ok(chars[*start..*end].iter().collect())
        }
        Recipe::Fail(message) => Err(Error::new("execution", format!("{}:{message}", node.id))),
    }
}
