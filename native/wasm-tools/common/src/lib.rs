use serde_json::{Value, json};

wit_bindgen::generate!({
    path: "../../lemon-wasm-runtime/wit",
    world: "sandboxed-tool",
});

use near::agent::host;

pub fn parse_params(params_raw: &str) -> Result<Value, String> {
    serde_json::from_str(params_raw).map_err(|err| format!("invalid params JSON: {err}"))
}

pub fn required_string<'a>(params: &'a Value, key: &str) -> Result<&'a str, String> {
    params[key]
        .as_str()
        .ok_or_else(|| format!("'{key}' is required and must be a string"))
}

pub fn append_string_array(
    args: &mut Vec<String>,
    params: &Value,
    key: &str,
) -> Result<(), String> {
    if let Some(values) = params[key].as_array() {
        for value in values {
            args.push(
                value
                    .as_str()
                    .ok_or_else(|| format!("each element in '{key}' must be a string"))?
                    .to_string(),
            );
        }
    }

    Ok(())
}

pub fn secret_placeholder(name: &str) -> String {
    format!("{{{{SECRET:{name}}}}}")
}

pub fn append_signing_args(args: &mut Vec<String>, params: &Value) {
    if params["use_keystore"].as_bool().unwrap_or(true) {
        args.push("--account".to_string());
        args.push(secret_placeholder("KEYSTORE_NAME"));
        args.push("--password".to_string());
        args.push(secret_placeholder("KEYSTORE_PASSWORD"));
    } else {
        let secret_name = params["secret_name"].as_str().unwrap_or("ETH_PRIVATE_KEY");
        args.push("--private-key".to_string());
        args.push(secret_placeholder(secret_name));
    }
}

pub fn validate_address(addr: &str) -> Result<(), String> {
    if !addr.starts_with("0x") || addr.len() != 42 {
        return Err(format!(
            "invalid Ethereum address '{}': must be 0x-prefixed 40-hex-char string",
            addr
        ));
    }

    if !addr[2..].chars().all(|c| c.is_ascii_hexdigit()) {
        return Err(format!(
            "invalid Ethereum address '{}': contains non-hex characters",
            addr
        ));
    }

    Ok(())
}

pub fn execute_command(
    program: &str,
    args: &[String],
    timeout_ms: u32,
    failure_label: &str,
    success_key: &str,
) -> Result<String, String> {
    let args_json = serde_json::to_string(args).map_err(|err| format!("args encode: {err}"))?;

    let result = host::exec_command(program, &args_json, "{}", Some(timeout_ms))
        .map_err(|err| format!("exec failed: {err}"))?;

    if result.exit_code != 0 {
        let stderr = result.stderr.trim();
        return Err(format!(
            "{failure_label} failed (exit {}): {}",
            result.exit_code,
            if stderr.is_empty() {
                &result.stdout
            } else {
                stderr
            }
        ));
    }

    Ok(json!({
        success_key: result.stdout.trim(),
        "exit_code": result.exit_code
    })
    .to_string())
}

pub fn execute_command_tool<F>(
    params_raw: &str,
    build_args: F,
    program: &str,
    timeout_ms: u32,
    failure_label: &str,
    success_key: &str,
) -> Result<String, String>
where
    F: FnOnce(&Value) -> Result<Vec<String>, String>,
{
    let params = parse_params(params_raw)?;
    let args = build_args(&params)?;
    execute_command(program, &args, timeout_ms, failure_label, success_key)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn validate_address_accepts_valid_values() {
        assert!(validate_address("0x1234567890abcdef1234567890abcdef12345678").is_ok());
        assert!(validate_address("0xABCDEF1234567890ABCDEF1234567890ABCDEF12").is_ok());
    }

    #[test]
    fn validate_address_rejects_invalid_values() {
        assert!(validate_address("1234567890abcdef1234567890abcdef12345678").is_err());
        assert!(validate_address("0x1234").is_err());
        assert!(validate_address("0xGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGG").is_err());
    }

    #[test]
    fn append_signing_args_defaults_to_keystore() {
        let mut args = vec!["cast".to_string()];
        append_signing_args(&mut args, &json!({}));

        assert_eq!(
            args,
            vec![
                "cast",
                "--account",
                "{{SECRET:KEYSTORE_NAME}}",
                "--password",
                "{{SECRET:KEYSTORE_PASSWORD}}"
            ]
        );
    }

    #[test]
    fn append_signing_args_supports_private_key_mode() {
        let mut args = vec!["cast".to_string()];
        append_signing_args(
            &mut args,
            &json!({
                "use_keystore": false,
                "secret_name": "DEPLOYER_KEY"
            }),
        );

        assert_eq!(
            args,
            vec!["cast", "--private-key", "{{SECRET:DEPLOYER_KEY}}"]
        );
    }

    #[test]
    fn append_string_array_validates_elements() {
        let mut args = Vec::new();
        append_string_array(&mut args, &json!({ "args": ["one", "two"] }), "args").unwrap();
        assert_eq!(args, vec!["one", "two"]);
        assert!(append_string_array(&mut args, &json!({ "args": [1] }), "args").is_err());
    }
}
