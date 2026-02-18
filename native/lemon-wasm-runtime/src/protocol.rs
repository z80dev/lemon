use serde::{Deserialize, Serialize};
use serde_json::Value;

#[derive(Debug, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Request {
    Hello {
        id: String,
        version: Option<u32>,
    },
    Discover {
        id: String,
        paths: Vec<String>,
        defaults: DiscoverDefaults,
    },
    Invoke {
        id: String,
        tool: String,
        params_json: String,
        context_json: Option<String>,
    },
    HostCallResult {
        id: String,
        call_id: String,
        ok: bool,
        output_json: Option<String>,
        error: Option<String>,
    },
    Shutdown {
        id: String,
    },
}

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct DiscoverDefaults {
    pub default_memory_limit: u64,
    pub default_timeout_ms: u64,
    pub default_fuel_limit: u64,
    pub cache_compiled: bool,
    pub cache_dir: Option<String>,
    pub max_tool_invoke_depth: u32,
}

impl Default for DiscoverDefaults {
    fn default() -> Self {
        Self {
            default_memory_limit: 10 * 1024 * 1024,
            default_timeout_ms: 60_000,
            default_fuel_limit: 10_000_000,
            cache_compiled: true,
            cache_dir: None,
            max_tool_invoke_depth: 4,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ToolCapabilitiesSummary {
    pub workspace_read: bool,
    pub http: bool,
    pub tool_invoke: bool,
    pub secrets: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DiscoveredTool {
    pub name: String,
    pub path: String,
    pub description: String,
    pub schema_json: String,
    pub capabilities: ToolCapabilitiesSummary,
    pub warnings: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DiscoverResult {
    pub tools: Vec<DiscoveredTool>,
    pub warnings: Vec<String>,
    pub errors: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct InvokeResult {
    pub output_json: Option<String>,
    pub error: Option<String>,
    pub logs: Vec<RuntimeLog>,
    pub details: Value,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RuntimeLog {
    pub level: String,
    pub message: String,
    pub timestamp_millis: u64,
}

#[derive(Debug, Serialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum OutboundMessage {
    Response {
        id: String,
        ok: bool,
        result: Value,
        error: Option<String>,
    },
    Event {
        event: String,
        request_id: String,
        call_id: String,
        tool: String,
        params_json: String,
    },
}

impl OutboundMessage {
    pub fn response_ok(id: impl Into<String>, result: Value) -> Self {
        Self::Response {
            id: id.into(),
            ok: true,
            result,
            error: None,
        }
    }

    pub fn response_err(id: impl Into<String>, error: impl Into<String>) -> Self {
        Self::Response {
            id: id.into(),
            ok: false,
            result: Value::Null,
            error: Some(error.into()),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{DiscoverDefaults, OutboundMessage, Request};

    #[test]
    fn discover_request_roundtrips() {
        let encoded = serde_json::json!({
            "type": "discover",
            "id": "req_1",
            "paths": ["/tmp/tools"],
            "defaults": DiscoverDefaults::default()
        })
        .to_string();

        let decoded: Request = serde_json::from_str(&encoded).expect("decode request");

        match decoded {
            Request::Discover {
                id,
                paths,
                defaults,
            } => {
                assert_eq!(id, "req_1");
                assert_eq!(paths, vec!["/tmp/tools"]);
                assert_eq!(defaults.default_memory_limit, 10 * 1024 * 1024);
            }
            other => panic!("unexpected request variant: {other:?}"),
        }
    }

    #[test]
    fn response_message_roundtrips() {
        let message = OutboundMessage::response_ok("req_2", serde_json::json!({"ok": true}));

        let encoded = serde_json::to_string(&message).expect("encode response");
        let decoded: serde_json::Value = serde_json::from_str(&encoded).expect("decode response");

        assert_eq!(decoded["type"], "response");
        assert_eq!(decoded["id"], "req_2");
        assert_eq!(decoded["ok"], true);
        assert_eq!(decoded["result"]["ok"], true);
    }
}
