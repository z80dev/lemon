use serde_json::{Value, json};

wit_bindgen::generate!({
    path: "../../lemon-wasm-runtime/wit",
    world: "sandboxed-tool",
});

use exports::near::agent::tool::{Guest, Request, Response};
use near::agent::host;

struct CastWalletAddressTool;

impl Guest for CastWalletAddressTool {
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
            "title": "cast_wallet_address",
            "type": "object",
            "additionalProperties": false,
            "properties": {
                "secret_name": {
                    "type": "string",
                    "description": "Secret name for the signing private key (default: ETH_PRIVATE_KEY). Used only when use_keystore is false."
                },
                "use_keystore": {
                    "type": "boolean",
                    "description": "Use Foundry keystore account lookup with KEYSTORE_NAME and KEYSTORE_PASSWORD secrets (default: true)."
                }
            }
        })
        .to_string()
    }

    fn description() -> String {
        "Return an Ethereum address using `cast wallet address` from either a Foundry keystore account \
         or a private key secret. Credentials are injected securely and never exposed to the tool."
            .to_string()
    }
}

export!(CastWalletAddressTool);

fn build_args(params: &Value) -> Vec<String> {
    let mut args: Vec<String> = vec!["wallet".to_string(), "address".to_string()];

    if params["use_keystore"].as_bool().unwrap_or(true) {
        args.push("--account".to_string());
        args.push("{{SECRET:KEYSTORE_NAME}}".to_string());
        args.push("--password".to_string());
        args.push("{{SECRET:KEYSTORE_PASSWORD}}".to_string());
    } else {
        let secret_name = params["secret_name"].as_str().unwrap_or("ETH_PRIVATE_KEY");
        args.push("--private-key".to_string());
        args.push(format!("{{{{SECRET:{secret_name}}}}}"));
    }

    args
}

fn execute_impl(params_raw: &str) -> Result<String, String> {
    let params: Value =
        serde_json::from_str(params_raw).map_err(|err| format!("invalid params JSON: {err}"))?;

    let args = build_args(&params);

    let args_json = serde_json::to_string(&args).map_err(|err| format!("args encode: {err}"))?;

    let result = host::exec_command("cast", &args_json, "{}", Some(30_000))
        .map_err(|err| format!("exec failed: {err}"))?;

    if result.exit_code != 0 {
        let stderr = result.stderr.trim();
        return Err(format!(
            "cast wallet address failed (exit {}): {}",
            result.exit_code,
            if stderr.is_empty() {
                &result.stdout
            } else {
                stderr
            }
        ));
    }

    Ok(json!({
        "address": result.stdout.trim(),
        "exit_code": result.exit_code
    })
    .to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn build_args_uses_keystore_by_default() {
        let params = json!({});
        let args = build_args(&params);
        assert_eq!(
            args,
            vec![
                "wallet",
                "address",
                "--account",
                "{{SECRET:KEYSTORE_NAME}}",
                "--password",
                "{{SECRET:KEYSTORE_PASSWORD}}"
            ]
        );
    }

    #[test]
    fn build_args_can_use_private_key_mode() {
        let params = json!({
            "use_keystore": false,
            "secret_name": "DEPLOYER_KEY"
        });
        let args = build_args(&params);
        assert_eq!(
            args,
            vec![
                "wallet",
                "address",
                "--private-key",
                "{{SECRET:DEPLOYER_KEY}}"
            ]
        );
    }

    #[test]
    fn build_args_private_key_mode_uses_default_secret_name() {
        let params = json!({
            "use_keystore": false
        });
        let args = build_args(&params);
        assert_eq!(
            args,
            vec![
                "wallet",
                "address",
                "--private-key",
                "{{SECRET:ETH_PRIVATE_KEY}}"
            ]
        );
    }

    #[test]
    fn schema_is_valid_json() {
        let schema_str = CastWalletAddressTool::schema();
        let schema: serde_json::Value = serde_json::from_str(&schema_str).expect("valid JSON");
        assert_eq!(schema["title"], "cast_wallet_address");
        assert!(schema["properties"]["secret_name"].is_object());
        assert!(schema["properties"]["use_keystore"].is_object());
    }
}
