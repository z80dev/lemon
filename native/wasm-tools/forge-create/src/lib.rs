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
                    "description": "Secret name for the signing private key (default: ETH_PRIVATE_KEY)"
                }
            },
            "required": ["contract", "rpc_url"]
        })
        .to_string()
    }

    fn description() -> String {
        "Deploy a smart contract using `forge create`. \
         Supports constructor arguments and Etherscan verification. \
         Private keys and API keys are injected securely and never exposed to the tool."
            .to_string()
    }
}

export!(ForgeCreateTool);

fn execute_impl(params_raw: &str) -> Result<String, String> {
    let params: Value =
        serde_json::from_str(params_raw).map_err(|err| format!("invalid params JSON: {err}"))?;

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
