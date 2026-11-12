use crate::{Compiled, Error, Schema};
pub fn compile_text(schema: &str, layers: &str, target: &str) -> Result<(Schema, Compiled), Error> {
    let schema = crate::schema_parser::parse(schema)?;
    let layers = crate::layer_parser::parse(layers)?;
    let result = crate::compile(&schema, &layers, target)?;
    Ok((schema, result))
}
pub fn render_text(
    schema: &str,
    layers: &str,
    target: &str,
    redact: bool,
) -> Result<String, Error> {
    let (schema, result) = compile_text(schema, layers, target)?;
    Ok(crate::render::compiled(&result, &schema, redact))
}
