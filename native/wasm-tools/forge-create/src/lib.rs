use serde_json::{Value, json};

wit_bindgen::generate!({
    path: "../../lemon-wasm-runtime/wit",
    world: "sandboxed-tool",
});

use exports::near::agent::tool::{Guest, Request, Response};
use near::agent::host;

struct ForgeCreateTool;

impl Guest for ForgeCreateTool {
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
            "title": "forge_create",
            "type": "object",
            "additionalProperties": false,
            "properties": {
                "contract": {
                    "type": "string",
                    "description": "Contract path and name (e.g. 'src/Counter.sol:Counter')"
                },
                "constructor_args": {
                    "type": "array",
                    "items": { "type": "string" },
                    "description": "Constructor arguments"
                },
                "constructor_args_path": {
                    "type": "string",
                    "description": "Path to a file with ABI-encoded constructor args"
                },
                "rpc_url": {
                    "type": "string",
                    "description": "JSON-RPC endpoint URL"
                },
                "chain": {
                    "type": "string",
                    "description": "Chain name or ID"
                },
                "verify": {
                    "type": "boolean",
                    "description": "Verify the contract on Etherscan after deployment"
                },
                "etherscan_api_key_secret": {
                    "type": "string",
                    "description": "Secret name for the Etherscan API key (used with --verify)"
                },
                "extra_args": {
                    "type": "array",
                    "items": { "type": "string" },
                    "description": "Additional raw flags to pass to forge create"
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
            "required": ["contract", "rpc_url"]
        })
        .to_string()
    }

    fn description() -> String {
        "Deploy a smart contract using `forge create`. \
         Supports constructor arguments and Etherscan verification. \
         Signing via raw private key secret or Foundry keystore account. \
         Credentials are injected securely and never exposed to the tool."
            .to_string()
    }
}

export!(ForgeCreateTool);

fn build_args(params: &Value) -> Result<Vec<String>, String> {
    let contract = params["contract"]
        .as_str()
        .ok_or("'contract' is required and must be a string")?;
    let rpc_url = params["rpc_url"]
        .as_str()
        .ok_or("'rpc_url' is required and must be a string")?;

    let mut args: Vec<String> = vec!["create".to_string(), contract.to_string()];

    if let Some(constructor_args) = params["constructor_args"].as_array() {
        args.push("--constructor-args".to_string());
        for arg in constructor_args {
            args.push(
                arg.as_str()
                    .ok_or("each element in 'constructor_args' must be a string")?
                    .to_string(),
            );
        }
    }

    if let Some(constructor_args_path) = params["constructor_args_path"].as_str() {
        args.push("--constructor-args-path".to_string());
        args.push(constructor_args_path.to_string());
    }

    args.push("--rpc-url".to_string());
    args.push(rpc_url.to_string());

    if let Some(chain) = params["chain"].as_str() {
        args.push("--chain".to_string());
        args.push(chain.to_string());
    }

    if params["verify"].as_bool() == Some(true) {
        args.push("--verify".to_string());

        if let Some(etherscan_secret) = params["etherscan_api_key_secret"].as_str() {
            args.push("--etherscan-api-key".to_string());
            args.push(format!("{{{{SECRET:{etherscan_secret}}}}}"));
        }
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

    if let Some(extra) = params["extra_args"].as_array() {
        for arg in extra {
            args.push(
                arg.as_str()
                    .ok_or("each element in 'extra_args' must be a string")?
                    .to_string(),
            );
        }
    }

    Ok(args)
}

fn execute_impl(params_raw: &str) -> Result<String, String> {
    let params: Value =
        serde_json::from_str(params_raw).map_err(|err| format!("invalid params JSON: {err}"))?;

    let args = build_args(&params)?;

    let args_json = serde_json::to_string(&args).map_err(|err| format!("args encode: {err}"))?;

    let result = host::exec_command("forge", &args_json, "{}", Some(120_000))
        .map_err(|err| format!("exec failed: {err}"))?;

    if result.exit_code != 0 {
        let stderr = result.stderr.trim();
        return Err(format!(
            "forge create failed (exit {}): {}",
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

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn build_args_minimal() {
        let params = json!({
            "contract": "src/Counter.sol:Counter",
            "rpc_url": "https://eth.llamarpc.com"
        });

        let args = build_args(&params).unwrap();
        assert_eq!(args[0], "create");
        assert_eq!(args[1], "src/Counter.sol:Counter");
        assert!(args.contains(&"--rpc-url".to_string()));
        assert!(args.contains(&"--account".to_string()));
        assert!(args.contains(&"{{SECRET:KEYSTORE_NAME}}".to_string()));
        assert!(args.contains(&"--password".to_string()));
        assert!(args.contains(&"{{SECRET:KEYSTORE_PASSWORD}}".to_string()));
    }

    #[test]
    fn build_args_with_constructor_args() {
        let params = json!({
            "contract": "src/Token.sol:Token",
            "constructor_args": ["MyToken", "MTK", "1000000"],
            "rpc_url": "https://rpc.example.com"
        });

        let args = build_args(&params).unwrap();
        assert!(args.contains(&"--constructor-args".to_string()));
        assert!(args.contains(&"MyToken".to_string()));
        assert!(args.contains(&"MTK".to_string()));
        assert!(args.contains(&"1000000".to_string()));
    }

    #[test]
    fn build_args_with_constructor_args_path() {
        let params = json!({
            "contract": "src/Token.sol:Token",
            "constructor_args_path": "args.txt",
            "rpc_url": "https://rpc.example.com"
        });

        let args = build_args(&params).unwrap();
        assert!(args.contains(&"--constructor-args-path".to_string()));
        assert!(args.contains(&"args.txt".to_string()));
    }

    #[test]
    fn build_args_with_verify() {
        let params = json!({
            "contract": "src/Counter.sol:Counter",
            "rpc_url": "https://rpc.example.com",
            "verify": true,
            "etherscan_api_key_secret": "MY_ETHERSCAN_KEY",
            "chain": "mainnet"
        });

        let args = build_args(&params).unwrap();
        assert!(args.contains(&"--verify".to_string()));
        assert!(args.contains(&"--etherscan-api-key".to_string()));
        assert!(args.contains(&"{{SECRET:MY_ETHERSCAN_KEY}}".to_string()));
        assert!(args.contains(&"--chain".to_string()));
    }

    #[test]
    fn build_args_with_extra_args() {
        let params = json!({
            "contract": "src/Counter.sol:Counter",
            "rpc_url": "https://rpc.example.com",
            "extra_args": ["--via-ir"]
        });

        let args = build_args(&params).unwrap();
        assert!(args.contains(&"--via-ir".to_string()));
    }

    #[test]
    fn build_args_uses_keystore_by_default() {
        let params = json!({
            "contract": "src/Counter.sol:Counter",
            "rpc_url": "https://rpc.example.com"
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
            "contract": "src/Counter.sol:Counter",
            "rpc_url": "https://rpc.example.com",
            "use_keystore": false,
            "secret_name": "DEPLOYER_KEY"
        });

        let args = build_args(&params).unwrap();
        assert!(args.contains(&"--private-key".to_string()));
        assert!(args.contains(&"{{SECRET:DEPLOYER_KEY}}".to_string()));
        assert!(!args.contains(&"--account".to_string()));
    }

    #[test]
    fn build_args_rejects_missing_contract() {
        let params = json!({ "rpc_url": "https://rpc.example.com" });
        assert!(build_args(&params).is_err());
    }

    #[test]
    fn build_args_rejects_missing_rpc_url() {
        let params = json!({ "contract": "src/Counter.sol:Counter" });
        assert!(build_args(&params).is_err());
    }

    #[test]
    fn schema_is_valid_json() {
        let schema_str = ForgeCreateTool::schema();
        let schema: serde_json::Value = serde_json::from_str(&schema_str).expect("valid JSON");
        assert_eq!(schema["title"], "forge_create");
    }
}
