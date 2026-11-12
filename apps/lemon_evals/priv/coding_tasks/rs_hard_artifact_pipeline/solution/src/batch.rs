use crate::{Engine, Error};
pub fn build_text(manifest: &str, requests: &[&str]) -> Result<String, Error> {
    let manifest = crate::parser::parse(manifest)?;
    let mut engine = Engine::new();
    let mut reports = Vec::new();
    for text in requests {
        let request = crate::request::parse(text)?;
        reports.push(crate::render::report(&engine.build(&manifest, &request)?));
    }
    Ok(reports.join(
        "
--
",
    ))
}
