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

    let args = build_args(&params)?;

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

fn build_args(params: &Value) -> Result<Vec<String>, String> {
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

    Ok(args)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn validate_address_accepts_valid() {
        assert!(validate_address("0x1234567890abcdef1234567890abcdef12345678").is_ok());
        assert!(validate_address("0xABCDEF1234567890ABCDEF1234567890ABCDEF12").is_ok());
    }

    #[test]
    fn validate_address_rejects_no_prefix() {
        assert!(validate_address("1234567890abcdef1234567890abcdef12345678").is_err());
    }

    #[test]
    fn validate_address_rejects_wrong_length() {
        assert!(validate_address("0x1234").is_err());
        assert!(validate_address("0x1234567890abcdef1234567890abcdef1234567890").is_err());
    }

    #[test]
    fn validate_address_rejects_non_hex() {
        assert!(validate_address("0xGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGG").is_err());
    }

    #[test]
    fn build_args_minimal() {
        let params = json!({
            "to": "0x1234567890abcdef1234567890abcdef12345678",
            "rpc_url": "https://eth.llamarpc.com"
        });

        let args = build_args(&params).unwrap();
        assert_eq!(
            args,
            vec![
                "send",
                "0x1234567890abcdef1234567890abcdef12345678",
                "--rpc-url",
                "https://eth.llamarpc.com",
                "--private-key",
                "{{SECRET:ETH_PRIVATE_KEY}}"
            ]
        );
    }

    #[test]
    fn build_args_with_function_call() {
        let params = json!({
            "to": "0x1234567890abcdef1234567890abcdef12345678",
            "sig": "transfer(address,uint256)",
            "args": ["0xabcdefabcdefabcdefabcdefabcdefabcdefabcd", "1000"],
            "rpc_url": "https://rpc.example.com",
            "chain": "mainnet"
        });

        let args = build_args(&params).unwrap();
        assert_eq!(args[0], "send");
        assert_eq!(args[2], "transfer(address,uint256)");
        assert_eq!(args[3], "0xabcdefabcdefabcdefabcdefabcdefabcdefabcd");
        assert_eq!(args[4], "1000");
        assert!(args.contains(&"--chain".to_string()));
        assert!(args.contains(&"mainnet".to_string()));
    }

    #[test]
    fn build_args_with_all_options() {
        let params = json!({
            "to": "0x1234567890abcdef1234567890abcdef12345678",
            "rpc_url": "https://rpc.example.com",
            "value": "1ether",
            "gas_limit": "21000",
            "gas_price": "20gwei",
            "nonce": "42",
            "legacy": true,
            "secret_name": "DEPLOYER_KEY"
        });

        let args = build_args(&params).unwrap();
        assert!(args.contains(&"--value".to_string()));
        assert!(args.contains(&"1ether".to_string()));
        assert!(args.contains(&"--gas-limit".to_string()));
        assert!(args.contains(&"21000".to_string()));
        assert!(args.contains(&"--gas-price".to_string()));
        assert!(args.contains(&"20gwei".to_string()));
        assert!(args.contains(&"--nonce".to_string()));
        assert!(args.contains(&"42".to_string()));
        assert!(args.contains(&"--legacy".to_string()));
        assert!(args.contains(&"{{SECRET:DEPLOYER_KEY}}".to_string()));
    }

    #[test]
    fn build_args_rejects_invalid_address() {
        let params = json!({
            "to": "not_an_address",
            "rpc_url": "https://rpc.example.com"
        });
        assert!(build_args(&params).is_err());
    }

    #[test]
    fn build_args_rejects_missing_to() {
        let params = json!({ "rpc_url": "https://rpc.example.com" });
        assert!(build_args(&params).is_err());
    }

    #[test]
    fn build_args_rejects_missing_rpc_url() {
        let params = json!({ "to": "0x1234567890abcdef1234567890abcdef12345678" });
        assert!(build_args(&params).is_err());
    }

    #[test]
    fn schema_is_valid_json() {
        let schema_str = CastSendTool::schema();
        let schema: serde_json::Value = serde_json::from_str(&schema_str).expect("valid JSON");
        assert_eq!(schema["title"], "cast_send");
        assert_eq!(schema["type"], "object");
        assert!(schema["properties"]["to"].is_object());
        assert!(schema["properties"]["rpc_url"].is_object());
    }
}
