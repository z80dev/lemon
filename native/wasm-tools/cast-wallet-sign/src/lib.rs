use serde_json::{Value, json};

wit_bindgen::generate!({
    path: "../../lemon-wasm-runtime/wit",
    world: "sandboxed-tool",
});

use exports::near::agent::tool::{Guest, Request, Response};
use near::agent::host;

struct CastWalletSignTool;

impl Guest for CastWalletSignTool {
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
            "title": "cast_wallet_sign",
            "type": "object",
            "additionalProperties": false,
            "properties": {
                "message": {
                    "type": "string",
                    "description": "The message to sign"
                },
                "typed_data": {
                    "type": "boolean",
                    "description": "Treat message as EIP-712 typed data JSON"
                },
                "no_hash": {
                    "type": "boolean",
                    "description": "Do not hash the message before signing (use raw 32-byte input)"
                },
                "secret_name": {
                    "type": "string",
                    "description": "Secret name for the signing private key (default: ETH_PRIVATE_KEY). Used only when use_keystore is false."
                },
                "use_keystore": {
                    "type": "boolean",
                    "description": "Use Foundry keystore signing with KEYSTORE_NAME and KEYSTORE_PASSWORD secrets (default: true)."
                }
            },
            "required": ["message"]
        })
        .to_string()
    }

    fn description() -> String {
        "Sign a message or EIP-712 typed data using `cast wallet sign`. \
         Signing via raw private key secret or Foundry keystore account. \
         Credentials are injected securely and never exposed to the tool."
            .to_string()
    }
}

export!(CastWalletSignTool);

fn build_args(params: &Value) -> Result<Vec<String>, String> {
    let message = params["message"]
        .as_str()
        .ok_or("'message' is required and must be a string")?;

    let mut args: Vec<String> = vec!["wallet".to_string(), "sign".to_string()];

    if params["typed_data"].as_bool() == Some(true) {
        args.push("--data".to_string());
    }

    if params["no_hash"].as_bool() == Some(true) {
        args.push("--no-hash".to_string());
    }

    if params["use_keystore"].as_bool().unwrap_or(true) {
        args.push("--account".to_string());
        args.push("{{SECRET:KEYSTORE_NAME}}".to_string());
        args.push("--password".to_string());
        args.push("{{SECRET:KEYSTORE_PASSWORD}}".to_string());
    } else {
        let secret_name = params["secret_name"]
            .as_str()
            .unwrap_or("ETH_PRIVATE_KEY");
        args.push("--private-key".to_string());
        args.push(format!("{{{{SECRET:{secret_name}}}}}"));
    }

    args.push(message.to_string());

    Ok(args)
}

fn execute_impl(params_raw: &str) -> Result<String, String> {
    let params: Value =
        serde_json::from_str(params_raw).map_err(|err| format!("invalid params JSON: {err}"))?;

    let args = build_args(&params)?;

    let args_json = serde_json::to_string(&args).map_err(|err| format!("args encode: {err}"))?;

    let result = host::exec_command("cast", &args_json, "{}", Some(30_000))
        .map_err(|err| format!("exec failed: {err}"))?;

    if result.exit_code != 0 {
        let stderr = result.stderr.trim();
        return Err(format!(
            "cast wallet sign failed (exit {}): {}",
            result.exit_code,
            if stderr.is_empty() {
                &result.stdout
            } else {
                stderr
            }
        ));
    }

    Ok(json!({
        "signature": result.stdout.trim(),
        "exit_code": result.exit_code
    })
    .to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn build_args_simple_message() {
        let params = json!({ "message": "Hello, world!" });
        let args = build_args(&params).unwrap();
        assert_eq!(
            args,
            vec![
                "wallet",
                "sign",
                "--account",
                "{{SECRET:KEYSTORE_NAME}}",
                "--password",
                "{{SECRET:KEYSTORE_PASSWORD}}",
                "Hello, world!"
            ]
        );
    }

    #[test]
    fn build_args_typed_data() {
        let params = json!({ "message": "{\"types\":{}}", "typed_data": true });
        let args = build_args(&params).unwrap();
        assert!(args.contains(&"--data".to_string()));
    }

    #[test]
    fn build_args_no_hash() {
        let params = json!({ "message": "raw32bytes", "no_hash": true });
        let args = build_args(&params).unwrap();
        assert!(args.contains(&"--no-hash".to_string()));
    }

    #[test]
    fn build_args_custom_secret() {
        let params =
            json!({ "message": "test", "use_keystore": false, "secret_name": "SIGNER_KEY" });
        let args = build_args(&params).unwrap();
        assert!(args.contains(&"{{SECRET:SIGNER_KEY}}".to_string()));
        assert!(!args.iter().any(|a| a.contains("ETH_PRIVATE_KEY")));
    }

    #[test]
    fn build_args_uses_keystore_by_default() {
        let params = json!({
            "message": "test"
        });
        let args = build_args(&params).unwrap();
        assert!(args.contains(&"--account".to_string()));
        assert!(args.contains(&"{{SECRET:KEYSTORE_NAME}}".to_string()));
        assert!(args.contains(&"--password".to_string()));
        assert!(args.contains(&"{{SECRET:KEYSTORE_PASSWORD}}".to_string()));
        assert!(!args.contains(&"--private-key".to_string()));
    }

    #[test]
    fn build_args_can_use_private_key_mode() {
        let params = json!({
            "message": "test",
            "use_keystore": false,
            "secret_name": "SIGNER_KEY"
        });
        let args = build_args(&params).unwrap();
        assert!(args.contains(&"--private-key".to_string()));
        assert!(args.contains(&"{{SECRET:SIGNER_KEY}}".to_string()));
        assert!(!args.contains(&"--account".to_string()));
    }

    #[test]
    fn build_args_rejects_missing_message() {
        let params = json!({});
        assert!(build_args(&params).is_err());
    }

    #[test]
    fn schema_is_valid_json() {
        let schema_str = CastWalletSignTool::schema();
        let schema: serde_json::Value = serde_json::from_str(&schema_str).expect("valid JSON");
        assert_eq!(schema["title"], "cast_wallet_sign");
        assert!(schema["required"].as_array().unwrap().contains(&json!("message")));
        assert!(schema["properties"]["use_keystore"].is_object());
    }
}
