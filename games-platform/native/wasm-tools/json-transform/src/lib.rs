use serde_json::{Map, Value, json};

wit_bindgen::generate!({
    path: "../../lemon-wasm-runtime/wit",
    world: "sandboxed-tool",
});

use exports::near::agent::tool::{Guest, Request, Response};

struct JsonTransformTool;

impl Guest for JsonTransformTool {
    fn execute(req: Request) -> Response {
        match execute_impl(&req.params) {
            Ok(output) => Response {
                output: Some(output),
                error: None,
            },
            Err(error) => Response {
                output: None,
                error: Some(error),
            },
        }
    }

    fn schema() -> String {
        json!({
            "title": "json_transform",
            "type": "object",
            "additionalProperties": false,
            "properties": {
                "input": {
                    "description": "JSON value to transform"
                },
                "input_json": {
                    "type": "string",
                    "description": "JSON string to transform (used if `input` is omitted)"
                },
                "pick": {
                    "type": "array",
                    "items": {"type": "string"},
                    "description": "Optional top-level keys to retain when input is an object"
                },
                "set": {
                    "type": "object",
                    "additionalProperties": true,
                    "description": "Optional top-level fields to set/overwrite when input is an object"
                },
                "pretty": {
                    "type": "boolean",
                    "default": false,
                    "description": "Pretty-print the output JSON"
                }
            },
            "oneOf": [
                {"required": ["input"]},
                {"required": ["input_json"]}
            ]
        })
        .to_string()
    }

    fn description() -> String {
        "Transform JSON values with optional top-level key filtering and key/value overrides"
            .to_string()
    }
}

export!(JsonTransformTool);

fn execute_impl(params_raw: &str) -> Result<String, String> {
    let params: Value =
        serde_json::from_str(params_raw).map_err(|err| format!("invalid params JSON: {err}"))?;

    let mut value = extract_input_value(&params)?;

    if let Some(pick_value) = params.get("pick") {
        apply_pick(&mut value, pick_value)?;
    }

    if let Some(set_value) = params.get("set") {
        apply_set(&mut value, set_value)?;
    }

    let pretty = params
        .get("pretty")
        .and_then(Value::as_bool)
        .unwrap_or(false);

    if pretty {
        serde_json::to_string_pretty(&value)
            .map_err(|err| format!("failed to encode pretty output: {err}"))
    } else {
        serde_json::to_string(&value).map_err(|err| format!("failed to encode output: {err}"))
    }
}

fn extract_input_value(params: &Value) -> Result<Value, String> {
    if let Some(input) = params.get("input") {
        return Ok(input.clone());
    }

    let Some(input_json) = params.get("input_json") else {
        return Err("expected `input` or `input_json`".to_string());
    };

    let Some(input_json) = input_json.as_str() else {
        return Err("`input_json` must be a string".to_string());
    };

    serde_json::from_str(input_json).map_err(|err| format!("invalid `input_json`: {err}"))
}

fn apply_pick(value: &mut Value, pick_value: &Value) -> Result<(), String> {
    let pick_keys = pick_value
        .as_array()
        .ok_or_else(|| "`pick` must be an array of strings".to_string())?;

    let object = value
        .as_object()
        .ok_or_else(|| "`pick` can only be used when input is a JSON object".to_string())?;

    let mut filtered = Map::new();

    for key_value in pick_keys {
        let key = key_value
            .as_str()
            .ok_or_else(|| "`pick` must contain only strings".to_string())?;

        if let Some(existing) = object.get(key) {
            filtered.insert(key.to_string(), existing.clone());
        }
    }

    *value = Value::Object(filtered);

    Ok(())
}

fn apply_set(value: &mut Value, set_value: &Value) -> Result<(), String> {
    let set_object = set_value
        .as_object()
        .ok_or_else(|| "`set` must be an object".to_string())?;

    let object = value
        .as_object_mut()
        .ok_or_else(|| "`set` can only be used when input is a JSON object".to_string())?;

    for (key, set_value) in set_object {
        object.insert(key.clone(), set_value.clone());
    }

    Ok(())
}
