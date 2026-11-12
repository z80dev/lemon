use crate::merge::RawValue;
use crate::{Error, Kind, Rule, Value};
pub fn convert(rule: &Rule, raw: &RawValue) -> Result<Value, Error> {
    let fail = || Error::new("type", &rule.path);
    match (&rule.kind, raw) {
        (Kind::Text { .. }, RawValue::Scalar(value)) => Ok(Value::Text(value.clone())),
        (Kind::Integer { .. }, RawValue::Scalar(value)) => {
            value.parse().map(Value::Integer).map_err(|_| fail())
        }
        (Kind::Boolean, RawValue::Scalar(value)) => match value.to_lowercase().as_str() {
            "true" => Ok(Value::Boolean(true)),
            "false" => Ok(Value::Boolean(false)),
            _ => Err(fail()),
        },
        (Kind::List { .. }, RawValue::List(values)) => Ok(Value::List(values.clone())),
        _ => Err(fail()),
    }
}
