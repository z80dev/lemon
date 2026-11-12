use crate::Error;
pub fn compile_text(
    schema: &str,
    layers: &str,
    targets: &[&str],
    redact: bool,
) -> Result<String, Error> {
    let schema = crate::schema_parser::parse(schema)?;
    let layers = crate::layer_parser::parse(layers)?;
    let mut results = Vec::new();
    for target in targets {
        let result = crate::compile(&schema, &layers, target)?;
        results.push(crate::render::compiled(&result, &schema, redact));
    }
    Ok(results.join(
        "
--
",
    ))
}
