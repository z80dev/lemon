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
                    "description": "Secret name for the signing private key (default: ETH_PRIVATE_KEY)"
                }
            },
            "required": ["message"]
        })
        .to_string()
    }

    fn description() -> String {
        "Sign a message or EIP-712 typed data using `cast wallet sign`. \
         The private key is injected securely and never exposed to the tool."
            .to_string()
    }
}

export!(CastWalletSignTool);

fn execute_impl(params_raw: &str) -> Result<String, String> {
    let params: Value =
        serde_json::from_str(params_raw).map_err(|err| format!("invalid params JSON: {err}"))?;

    let message = params["message"]
        .as_str()
        .ok_or("'message' is required and must be a string")?;

    let secret_name = params["secret_name"]
        .as_str()
        .unwrap_or("ETH_PRIVATE_KEY");

    let mut args: Vec<String> = vec!["wallet".to_string(), "sign".to_string()];

    if params["typed_data"].as_bool() == Some(true) {
        args.push("--data".to_string());
    }

    if params["no_hash"].as_bool() == Some(true) {
        args.push("--no-hash".to_string());
    }

    args.push("--private-key".to_string());
    args.push(format!("{{{{SECRET:{secret_name}}}}}"));

    args.push(message.to_string());

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
