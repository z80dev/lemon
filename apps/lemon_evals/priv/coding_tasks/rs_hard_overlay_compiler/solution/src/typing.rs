use crate::merge::RawValue;
use crate::{Error, Kind, Rule, Value};
pub fn convert(rule: &Rule, raw: &RawValue) -> Result<Value, Error> {
    let fail = || Error::new("type", &rule.path);
    match (&rule.kind, raw) {
        (Kind::Text { nonempty }, RawValue::Scalar(value)) => {
            if *nonempty && value.is_empty() {
                return Err(fail());
            }
            Ok(Value::Text(value.clone()))
        }
        (Kind::Integer { min, max }, RawValue::Scalar(value)) => {
            let digits = value.strip_prefix('-').unwrap_or(value);
            if digits.is_empty() || !digits.bytes().all(|byte| byte.is_ascii_digit()) {
                return Err(fail());
            }
            let parsed: i64 = value.parse().map_err(|_| fail())?;
            if parsed < *min || parsed > *max {
                return Err(fail());
            }
            Ok(Value::Integer(parsed))
        }
        (Kind::Boolean, RawValue::Scalar(value)) => match value.as_str() {
            "true" => Ok(Value::Boolean(true)),
            "false" => Ok(Value::Boolean(false)),
            _ => Err(fail()),
        },
        (Kind::List { min, max }, RawValue::List(values)) => {
            if values.len() < *min || values.len() > *max {
                return Err(fail());
            }
            Ok(Value::List(values.clone()))
        }
        _ => Err(fail()),
    }
}
