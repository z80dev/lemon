use serde_json::{Value, json};

wit_bindgen::generate!({
    path: "../../lemon-wasm-runtime/wit",
    world: "sandboxed-tool",
});

use exports::near::agent::tool::{Guest, Request, Response};
use near::agent::host;

struct ForgeScriptTool;

impl Guest for ForgeScriptTool {
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
            "title": "forge_script",
            "type": "object",
            "additionalProperties": false,
            "properties": {
                "script": {
                    "type": "string",
                    "description": "Path to the Solidity script (e.g. 'script/Deploy.s.sol')"
                },
                "sig": {
                    "type": "string",
                    "description": "Function signature to run (default: 'run()')"
                },
                "args": {
                    "type": "array",
                    "items": { "type": "string" },
                    "description": "Arguments to the script function"
                },
                "rpc_url": {
                    "type": "string",
                    "description": "JSON-RPC endpoint URL"
                },
                "chain": {
                    "type": "string",
                    "description": "Chain name or ID"
                },
                "broadcast": {
                    "type": "boolean",
                    "description": "Broadcast transactions on-chain (default: false, dry-run)"
                },
                "verify": {
                    "type": "boolean",
                    "description": "Verify contracts on Etherscan after deployment"
                },
                "etherscan_api_key_secret": {
                    "type": "string",
                    "description": "Secret name for the Etherscan API key (used with --verify)"
                },
                "extra_args": {
                    "type": "array",
                    "items": { "type": "string" },
                    "description": "Additional raw flags to pass to forge script"
                },
                "secret_name": {
                    "type": "string",
                    "description": "Secret name for the signing private key (default: ETH_PRIVATE_KEY)"
                }
            },
            "required": ["script", "rpc_url"]
        })
        .to_string()
    }

    fn description() -> String {
        "Run a Forge deployment/interaction script using `forge script`. \
         Supports dry-run and broadcast modes. Private keys and API keys are \
         injected securely and never exposed to the tool."
            .to_string()
    }
}

export!(ForgeScriptTool);

fn build_args(params: &Value) -> Result<Vec<String>, String> {
    let script = params["script"]
        .as_str()
        .ok_or("'script' is required and must be a string")?;
    let rpc_url = params["rpc_url"]
        .as_str()
        .ok_or("'rpc_url' is required and must be a string")?;

    let mut args: Vec<String> = vec!["script".to_string(), script.to_string()];

    if let Some(sig) = params["sig"].as_str() {
        args.push("--sig".to_string());
        args.push(sig.to_string());
    }

    if let Some(script_args) = params["args"].as_array() {
        for arg in script_args {
            args.push(
                arg.as_str()
                    .ok_or("each element in 'args' must be a string")?
                    .to_string(),
            );
        }
    }

    args.push("--rpc-url".to_string());
    args.push(rpc_url.to_string());

    if let Some(chain) = params["chain"].as_str() {
        args.push("--chain".to_string());
        args.push(chain.to_string());
    }

    if params["broadcast"].as_bool() == Some(true) {
        args.push("--broadcast".to_string());
    }

    if params["verify"].as_bool() == Some(true) {
        args.push("--verify".to_string());

        if let Some(etherscan_secret) = params["etherscan_api_key_secret"].as_str() {
            args.push("--etherscan-api-key".to_string());
            args.push(format!("{{{{SECRET:{etherscan_secret}}}}}"));
        }
    }

    let secret_name = params["secret_name"]
        .as_str()
        .unwrap_or("ETH_PRIVATE_KEY");

    args.push("--private-key".to_string());
    args.push(format!("{{{{SECRET:{secret_name}}}}}"));

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
            "forge script failed (exit {}): {}",
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
            "script": "script/Deploy.s.sol",
            "rpc_url": "https://eth.llamarpc.com"
        });

        let args = build_args(&params).unwrap();
        assert_eq!(args[0], "script");
        assert_eq!(args[1], "script/Deploy.s.sol");
        assert!(args.contains(&"--rpc-url".to_string()));
        assert!(args.contains(&"--private-key".to_string()));
        assert!(args.contains(&"{{SECRET:ETH_PRIVATE_KEY}}".to_string()));
        // No --broadcast by default
        assert!(!args.contains(&"--broadcast".to_string()));
    }

    #[test]
    fn build_args_with_broadcast_and_verify() {
        let params = json!({
            "script": "script/Deploy.s.sol",
            "rpc_url": "https://rpc.example.com",
            "broadcast": true,
            "verify": true,
            "etherscan_api_key_secret": "ETHERSCAN_KEY",
            "chain": "sepolia"
        });

        let args = build_args(&params).unwrap();
        assert!(args.contains(&"--broadcast".to_string()));
        assert!(args.contains(&"--verify".to_string()));
        assert!(args.contains(&"--etherscan-api-key".to_string()));
        assert!(args.contains(&"{{SECRET:ETHERSCAN_KEY}}".to_string()));
        assert!(args.contains(&"--chain".to_string()));
        assert!(args.contains(&"sepolia".to_string()));
    }

    #[test]
    fn build_args_with_sig_and_extra_args() {
        let params = json!({
            "script": "script/Deploy.s.sol",
            "rpc_url": "https://rpc.example.com",
            "sig": "deploy(uint256)",
            "args": ["42"],
            "extra_args": ["--via-ir", "--optimize"]
        });

        let args = build_args(&params).unwrap();
        assert!(args.contains(&"--sig".to_string()));
        assert!(args.contains(&"deploy(uint256)".to_string()));
        assert!(args.contains(&"42".to_string()));
        assert!(args.contains(&"--via-ir".to_string()));
        assert!(args.contains(&"--optimize".to_string()));
    }

    #[test]
    fn build_args_verify_without_etherscan_key() {
        let params = json!({
            "script": "script/Deploy.s.sol",
            "rpc_url": "https://rpc.example.com",
            "verify": true
        });

        let args = build_args(&params).unwrap();
        assert!(args.contains(&"--verify".to_string()));
        // No --etherscan-api-key when secret not provided
        assert!(!args.contains(&"--etherscan-api-key".to_string()));
    }

    #[test]
    fn build_args_rejects_missing_script() {
        let params = json!({ "rpc_url": "https://rpc.example.com" });
        assert!(build_args(&params).is_err());
    }

    #[test]
    fn build_args_rejects_missing_rpc_url() {
        let params = json!({ "script": "script/Deploy.s.sol" });
        assert!(build_args(&params).is_err());
    }

    #[test]
    fn schema_is_valid_json() {
        let schema_str = ForgeScriptTool::schema();
        let schema: serde_json::Value = serde_json::from_str(&schema_str).expect("valid JSON");
        assert_eq!(schema["title"], "forge_script");
    }
}
