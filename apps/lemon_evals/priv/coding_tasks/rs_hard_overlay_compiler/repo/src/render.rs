use crate::{Compiled, Schema, Value};
pub fn value(value: &Value) -> (&'static str, String) {
    match value {
        Value::Text(text) => ("text", text.clone()),
        Value::Integer(n) => ("int", n.to_string()),
        Value::Boolean(b) => ("bool", b.to_string()),
        Value::List(items) => ("list", items.join(",")),
    }
}
pub fn compiled(compiled: &Compiled, schema: &Schema, redact: bool) -> String {
    let mut lines = vec![format!("layers={}", compiled.layers.join(","))];
    for (path, resolved) in &compiled.values {
        let (kind, text) = value(&resolved.value);
        let text = if redact
            && schema
                .rules
                .iter()
                .any(|rule| rule.path == *path && rule.secret)
        {
            "[REDACTED]".into()
        } else {
            text
        };
        lines.push(format!(
            "value|{path}|{kind}|{text}|{}:{}|refs={}",
            resolved.origin.layer,
            resolved.origin.operation,
            resolved.references.join(",")
        ));
    }
    for (path, origin) in &compiled.tombstones {
        lines.push(format!(
            "deleted|{path}|{}:{}",
            origin.layer, origin.operation
        ));
    }
    lines.join(
        "
",
    )
}
