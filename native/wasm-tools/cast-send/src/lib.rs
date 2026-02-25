use serde_json::{Value, json};

wit_bindgen::generate!({
    path: "../../lemon-wasm-runtime/wit",
    world: "sandboxed-tool",
});

use exports::near::agent::tool::{Guest, Request, Response};
use near::agent::host;

struct CastSendTool;

impl Guest for CastSendTool {
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
            "title": "cast_send",
            "type": "object",
            "additionalProperties": false,
            "properties": {
                "to": {
                    "type": "string",
                    "description": "Recipient address (0x-prefixed hex)"
                },
                "sig": {
                    "type": "string",
                    "description": "Function signature, e.g. \"transfer(address,uint256)\""
                },
                "args": {
                    "type": "array",
                    "items": { "type": "string" },
                    "description": "Arguments to the function call"
                },
                "value": {
                    "type": "string",
                    "description": "ETH value to send (in wei or with units like '1ether')"
                },
                "rpc_url": {
                    "type": "string",
                    "description": "JSON-RPC endpoint URL"
                },
                "chain": {
                    "type": "string",
                    "description": "Chain name or ID (e.g. 'mainnet', '1', 'sepolia')"
                },
                "gas_limit": {
                    "type": "string",
                    "description": "Gas limit for the transaction"
                },
                "gas_price": {
                    "type": "string",
                    "description": "Gas price (in wei or with units)"
                },
                "nonce": {
                    "type": "string",
                    "description": "Nonce override for the transaction"
                },
                "legacy": {
                    "type": "boolean",
                    "description": "Use legacy (pre-EIP1559) transaction format"
                },
                "secret_name": {
                    "type": "string",
                    "description": "Secret name for the signing private key (default: ETH_PRIVATE_KEY)"
                }
            },
            "required": ["to", "rpc_url"]
        })
        .to_string()
    }

    fn description() -> String {
        "Sign and broadcast an Ethereum transaction using `cast send`. \
         Supports contract calls with function signatures and ETH transfers. \
         The private key is injected securely and never exposed to the tool."
            .to_string()
    }
}

export!(CastSendTool);

fn execute_impl(params_raw: &str) -> Result<String, String> {
    let params: Value =
        serde_json::from_str(params_raw).map_err(|err| format!("invalid params JSON: {err}"))?;

    let to = params["to"]
        .as_str()
        .ok_or("'to' is required and must be a string")?;
    let rpc_url = params["rpc_url"]
        .as_str()
        .ok_or("'rpc_url' is required and must be a string")?;

    validate_address(to)?;

    let mut args: Vec<String> = vec!["send".to_string(), to.to_string()];

    if let Some(sig) = params["sig"].as_str() {
        args.push(sig.to_string());

        if let Some(call_args) = params["args"].as_array() {
            for arg in call_args {
                args.push(
                    arg.as_str()
                        .ok_or("each element in 'args' must be a string")?
                        .to_string(),
                );
            }
        }
    }

    args.push("--rpc-url".to_string());
    args.push(rpc_url.to_string());

    if let Some(value) = params["value"].as_str() {
        args.push("--value".to_string());
        args.push(value.to_string());
    }

    if let Some(chain) = params["chain"].as_str() {
        args.push("--chain".to_string());
        args.push(chain.to_string());
    }

    if let Some(gas_limit) = params["gas_limit"].as_str() {
        args.push("--gas-limit".to_string());
        args.push(gas_limit.to_string());
    }

    if let Some(gas_price) = params["gas_price"].as_str() {
        args.push("--gas-price".to_string());
        args.push(gas_price.to_string());
    }

    if let Some(nonce) = params["nonce"].as_str() {
        args.push("--nonce".to_string());
        args.push(nonce.to_string());
    }

    if params["legacy"].as_bool() == Some(true) {
        args.push("--legacy".to_string());
    }

    let secret_name = params["secret_name"]
        .as_str()
        .unwrap_or("ETH_PRIVATE_KEY");

    args.push("--private-key".to_string());
    args.push(format!("{{{{SECRET:{secret_name}}}}}"));

    let args_json = serde_json::to_string(&args).map_err(|err| format!("args encode: {err}"))?;

    let result = host::exec_command("cast", &args_json, "{}", Some(60_000))
        .map_err(|err| format!("exec failed: {err}"))?;

    if result.exit_code != 0 {
        let stderr = result.stderr.trim();
        return Err(format!(
            "cast send failed (exit {}): {}",
            result.exit_code,
            if stderr.is_empty() {
                &result.stdout
            } else {
                stderr
            }
        ));
    }

    Ok(json!({
        "output": result.stdout.trim(),
        "exit_code": result.exit_code
    })
    .to_string())
}

fn validate_address(addr: &str) -> Result<(), String> {
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
