use serde_json::{Value, json};
use wasm_tools_common::{
    append_string_array, execute_command_tool, required_string, validate_address,
};

wit_bindgen::generate!({
    path: "../../lemon-wasm-runtime/wit",
    world: "sandboxed-tool",
});

use exports::near::agent::tool::{Guest, Request, Response};

struct CastCallTool;

impl Guest for CastCallTool {
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
            "title": "cast_call",
            "type": "object",
            "additionalProperties": false,
            "properties": {
                "to": {
                    "type": "string",
                    "description": "Contract address to call (0x-prefixed hex)"
                },
                "sig": {
                    "type": "string",
                    "description": "Function signature, e.g. \"balanceOf(address)\""
                },
                "args": {
                    "type": "array",
                    "items": { "type": "string" },
                    "description": "Arguments to the function call"
                },
                "rpc_url": {
                    "type": "string",
                    "description": "JSON-RPC endpoint URL"
                },
                "chain": {
                    "type": "string",
                    "description": "Chain name or ID (e.g. 'mainnet', '1', 'sepolia')"
                },
                "block": {
                    "type": "string",
                    "description": "Block number or tag (e.g. 'latest', 'pending', a number)"
                },
                "decode": {
                    "type": "boolean",
                    "description": "Attempt to ABI-decode the return value"
                }
            },
            "required": ["to", "sig", "rpc_url"]
        })
        .to_string()
    }

    fn description() -> String {
        "Read-only call to an Ethereum smart contract using `cast call`. \
         No private key is needed. Returns the raw or ABI-decoded return value."
            .to_string()
    }
}

export!(CastCallTool);

fn execute_impl(params_raw: &str) -> Result<String, String> {
    execute_command_tool(params_raw, build_args, "cast", 30_000, "cast call", "output")
}

fn build_args(params: &Value) -> Result<Vec<String>, String> {
    let to = required_string(params, "to")?;
    let sig = required_string(params, "sig")?;
    let rpc_url = required_string(params, "rpc_url")?;

    validate_address(to)?;

    let mut args: Vec<String> = vec!["call".to_string(), to.to_string(), sig.to_string()];

    append_string_array(&mut args, params, "args")?;

    args.push("--rpc-url".to_string());
    args.push(rpc_url.to_string());

    if let Some(chain) = params["chain"].as_str() {
        args.push("--chain".to_string());
        args.push(chain.to_string());
    }

    if let Some(block) = params["block"].as_str() {
        args.push("--block".to_string());
        args.push(block.to_string());
    }

    Ok(args)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn build_args_minimal() {
        let params = json!({
            "to": "0x1234567890abcdef1234567890abcdef12345678",
            "sig": "balanceOf(address)",
            "rpc_url": "https://eth.llamarpc.com"
        });

        let args = build_args(&params).unwrap();
        assert_eq!(
            args,
            vec![
                "call",
                "0x1234567890abcdef1234567890abcdef12345678",
                "balanceOf(address)",
                "--rpc-url",
                "https://eth.llamarpc.com"
            ]
        );
    }

    #[test]
    fn build_args_with_args_and_block() {
        let params = json!({
            "to": "0x1234567890abcdef1234567890abcdef12345678",
            "sig": "balanceOf(address)",
            "args": ["0xabcdefabcdefabcdefabcdefabcdefabcdefabcd"],
            "rpc_url": "https://rpc.example.com",
            "chain": "mainnet",
            "block": "latest"
        });

        let args = build_args(&params).unwrap();
        assert!(args.contains(&"0xabcdefabcdefabcdefabcdefabcdefabcdefabcd".to_string()));
        assert!(args.contains(&"--chain".to_string()));
        assert!(args.contains(&"--block".to_string()));
        assert!(args.contains(&"latest".to_string()));
    }

    #[test]
    fn build_args_no_private_key_included() {
        let params = json!({
            "to": "0x1234567890abcdef1234567890abcdef12345678",
            "sig": "totalSupply()",
            "rpc_url": "https://rpc.example.com"
        });

        let args = build_args(&params).unwrap();
        // cast_call is read-only, no --private-key
        assert!(!args.iter().any(|a| a.contains("private-key")));
        assert!(!args.iter().any(|a| a.contains("SECRET")));
    }

    #[test]
    fn build_args_rejects_missing_sig() {
        let params = json!({
            "to": "0x1234567890abcdef1234567890abcdef12345678",
            "rpc_url": "https://rpc.example.com"
        });
        assert!(build_args(&params).is_err());
    }

    #[test]
    fn schema_is_valid_json() {
        let schema_str = CastCallTool::schema();
        let schema: serde_json::Value = serde_json::from_str(&schema_str).expect("valid JSON");
        assert_eq!(schema["title"], "cast_call");
        assert!(schema["required"].as_array().unwrap().contains(&json!("to")));
        assert!(schema["required"].as_array().unwrap().contains(&json!("sig")));
        assert!(schema["required"].as_array().unwrap().contains(&json!("rpc_url")));
    }
}
