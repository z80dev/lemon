use crate::{Engine, Error};
pub fn build_text(manifest: &str, request: &str) -> Result<String, Error> {
    let manifest = crate::parser::parse(manifest)?;
    let request = crate::request::parse(request)?;
    let report = Engine::new().build(&manifest, &request)?;
    Ok(crate::render::report(&report))
}
pub fn plan_text(manifest: &str, request: &str) -> Result<String, Error> {
    let manifest = crate::parser::parse(manifest)?;
    let request = crate::request::parse(request)?;
    Ok(crate::planning::plan(&manifest, &request)?.order.join(","))
}
