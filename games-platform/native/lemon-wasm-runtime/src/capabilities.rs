use std::collections::HashMap;
use std::path::Path;

use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use url::Url;

use crate::protocol::ToolCapabilitiesSummary;

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct CapabilitiesFile {
    #[serde(default)]
    pub http: Option<HttpCapabilitySchema>,
    #[serde(default)]
    pub secrets: Option<SecretsCapabilitySchema>,
    #[serde(default)]
    pub tool_invoke: Option<ToolInvokeCapabilitySchema>,
    #[serde(default)]
    pub workspace: Option<WorkspaceCapabilitySchema>,
    #[serde(default)]
    pub auth: Option<AuthCapabilitySchema>,
    #[serde(default)]
    pub exec: Option<ExecCapabilitySchema>,
}

impl CapabilitiesFile {
    pub fn from_json_file(path: &Path) -> Result<Self> {
        let raw = std::fs::read_to_string(path)
            .with_context(|| format!("failed to read capabilities file {}", path.display()))?;
        let parsed: Self = serde_json::from_str(&raw)
            .with_context(|| format!("failed to parse capabilities file {}", path.display()))?;
        Ok(parsed)
    }

    pub fn summary(&self) -> ToolCapabilitiesSummary {
        ToolCapabilitiesSummary {
            workspace_read: self.workspace.is_some(),
            http: self.http.is_some(),
            tool_invoke: self.tool_invoke.is_some(),
            secrets: self.secrets.is_some(),
            auth: self.auth.is_some(),
            exec: self.exec.is_some(),
        }
    }

    pub fn secret_allowed(&self, name: &str) -> bool {
        match &self.secrets {
            Some(secrets) => secrets
                .allowed_names
                .iter()
                .any(|pattern| match_pattern(pattern, name)),
            None => false,
        }
    }

    pub fn workspace_read_allowed(&self, path: &str) -> bool {
        if path.is_empty() || path.starts_with('/') || path.contains("..") || path.contains('\0') {
            return false;
        }

        match &self.workspace {
            Some(workspace) => {
                if workspace.allowed_prefixes.is_empty() {
                    true
                } else {
                    workspace
                        .allowed_prefixes
                        .iter()
                        .any(|prefix| path.starts_with(prefix))
                }
            }
            None => false,
        }
    }

    pub fn resolve_tool_alias(&self, alias: &str) -> Option<String> {
        self.tool_invoke
            .as_ref()
            .and_then(|cap| cap.aliases.get(alias).cloned())
    }

    pub fn tool_invoke_limit(&self) -> u32 {
        self.tool_invoke
            .as_ref()
            .and_then(|cap| cap.rate_limit.as_ref())
            .map(|rate| rate.requests_per_minute)
            .filter(|limit| *limit > 0)
            .unwrap_or(20)
    }

    pub fn http_limit(&self) -> u32 {
        self.http
            .as_ref()
            .and_then(|cap| cap.rate_limit.as_ref())
            .map(|rate| rate.requests_per_minute)
            .filter(|limit| *limit > 0)
            .unwrap_or(50)
    }

    pub fn http_allowed(&self, method: &str, url: &str) -> bool {
        let Some(http) = &self.http else {
            return false;
        };

        let parsed = match Url::parse(url) {
            Ok(parsed) => parsed,
            Err(_) => return false,
        };

        let host = match parsed.host_str() {
            Some(host) => host,
            None => return false,
        };

        let path = parsed.path();
        let method = method.to_ascii_uppercase();

        http.allowlist.iter().any(|pattern| {
            host_matches_pattern(host, &pattern.host)
                && pattern
                    .path_prefix
                    .as_ref()
                    .map(|prefix| path.starts_with(prefix))
                    .unwrap_or(true)
                && (pattern.methods.is_empty()
                    || pattern
                        .methods
                        .iter()
                        .any(|allowed| allowed.eq_ignore_ascii_case(&method)))
        })
    }

    pub fn http_config(&self) -> Option<&HttpCapabilitySchema> {
        self.http.as_ref()
    }

    pub fn auth_config(&self) -> Option<&AuthCapabilitySchema> {
        self.auth.as_ref()
    }

    pub fn exec_config(&self) -> Option<&ExecCapabilitySchema> {
        self.exec.as_ref()
    }

    pub fn exec_allowed(&self, program: &str, args: &[String]) -> Result<(), String> {
        let exec = self
            .exec
            .as_ref()
            .ok_or_else(|| "exec capability not granted".to_string())?;

        let subcommand = args.first().map(String::as_str).unwrap_or("");

        let entry = exec
            .allowlist
            .iter()
            .find(|entry| entry.program == program)
            .ok_or_else(|| format!("program '{}' not in exec allowlist", program))?;

        if !entry.allowed_subcommands.is_empty()
            && !entry
                .allowed_subcommands
                .iter()
                .any(|allowed| allowed == subcommand)
        {
            return Err(format!(
                "subcommand '{}' not allowed for program '{}'",
                subcommand, program
            ));
        }

        for arg in args {
            if entry.blocked_flags.iter().any(|blocked| arg == blocked) {
                return Err(format!("blocked flag '{}' for program '{}'", arg, program));
            }
        }

        Ok(())
    }

    pub fn exec_limit(&self) -> u32 {
        self.exec
            .as_ref()
            .and_then(|cap| cap.rate_limit.as_ref())
            .map(|rate| rate.requests_per_minute)
            .filter(|limit| *limit > 0)
            .unwrap_or(10)
    }
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct HttpCapabilitySchema {
    #[serde(default)]
    pub allowlist: Vec<EndpointPatternSchema>,
    #[serde(default)]
    pub credentials: HashMap<String, CredentialMappingSchema>,
    #[serde(default)]
    pub rate_limit: Option<RateLimitSchema>,
    #[serde(default)]
    pub max_request_bytes: Option<usize>,
    #[serde(default)]
    pub max_response_bytes: Option<usize>,
    #[serde(default)]
    pub timeout_secs: Option<u64>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct EndpointPatternSchema {
    pub host: String,
    #[serde(default)]
    pub path_prefix: Option<String>,
    #[serde(default)]
    pub methods: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CredentialMappingSchema {
    pub secret_name: String,
    pub location: CredentialLocationSchema,
    #[serde(default)]
    pub host_patterns: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum CredentialLocationSchema {
    Bearer,
    Basic {
        username: String,
    },
    Header {
        name: String,
        #[serde(default)]
        prefix: Option<String>,
    },
    QueryParam {
        name: String,
    },
    UrlPath {
        placeholder: String,
    },
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RateLimitSchema {
    #[serde(default = "default_requests_per_minute")]
    pub requests_per_minute: u32,
    #[serde(default = "default_requests_per_hour")]
    pub requests_per_hour: u32,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct SecretsCapabilitySchema {
    #[serde(default)]
    pub allowed_names: Vec<String>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct ToolInvokeCapabilitySchema {
    #[serde(default)]
    pub aliases: HashMap<String, String>,
    #[serde(default)]
    pub rate_limit: Option<RateLimitSchema>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct WorkspaceCapabilitySchema {
    #[serde(default)]
    pub allowed_prefixes: Vec<String>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct ExecCapabilitySchema {
    #[serde(default)]
    pub allowlist: Vec<ExecAllowlistEntry>,
    #[serde(default)]
    pub credentials: HashMap<String, ExecCredentialMapping>,
    #[serde(default)]
    pub rate_limit: Option<RateLimitSchema>,
    #[serde(default)]
    pub timeout_secs: Option<u64>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ExecAllowlistEntry {
    pub program: String,
    #[serde(default)]
    pub allowed_subcommands: Vec<String>,
    #[serde(default)]
    pub blocked_flags: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ExecCredentialMapping {
    pub secret_name: String,
    pub injection: ExecCredentialInjection,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ExecCredentialInjection {
    Arg { flag: String },
    Env { var: String },
    File { path_template: String },
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct AuthCapabilitySchema {
    pub secret_name: String,
    #[serde(default)]
    pub display_name: Option<String>,
    #[serde(default)]
    pub oauth: Option<OAuthConfigSchema>,
    #[serde(default)]
    pub instructions: Option<String>,
    #[serde(default)]
    pub setup_url: Option<String>,
    #[serde(default)]
    pub token_hint: Option<String>,
    #[serde(default)]
    pub env_var: Option<String>,
    #[serde(default)]
    pub provider: Option<String>,
    #[serde(default)]
    pub validation_endpoint: Option<ValidationEndpointSchema>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct OAuthConfigSchema {
    pub authorization_url: String,
    pub token_url: String,
    #[serde(default)]
    pub client_id: Option<String>,
    #[serde(default)]
    pub client_id_env: Option<String>,
    #[serde(default)]
    pub client_secret: Option<String>,
    #[serde(default)]
    pub client_secret_env: Option<String>,
    #[serde(default)]
    pub scopes: Vec<String>,
    #[serde(default = "default_true")]
    pub use_pkce: bool,
    #[serde(default)]
    pub extra_params: HashMap<String, String>,
    #[serde(default = "default_access_token_field")]
    pub access_token_field: String,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct ValidationEndpointSchema {
    pub url: String,
    #[serde(default = "default_method")]
    pub method: String,
    #[serde(default = "default_success_status")]
    pub success_status: u16,
}

fn default_requests_per_minute() -> u32 {
    60
}

fn default_requests_per_hour() -> u32 {
    1000
}

fn default_true() -> bool {
    true
}

fn default_access_token_field() -> String {
    "access_token".to_string()
}

fn default_method() -> String {
    "GET".to_string()
}

fn default_success_status() -> u16 {
    200
}

pub fn host_matches_pattern(host: &str, pattern: &str) -> bool {
    if host.eq_ignore_ascii_case(pattern) {
        return true;
    }

    if let Some(suffix) = pattern.strip_prefix("*.") {
        if host.eq_ignore_ascii_case(suffix) {
            return false;
        }

        let host_lower = host.to_ascii_lowercase();
        let suffix_lower = suffix.to_ascii_lowercase();
        return host_lower.ends_with(&format!(".{}", suffix_lower));
    }

    false
}

fn match_pattern(pattern: &str, value: &str) -> bool {
    if pattern == value {
        return true;
    }

    if let Some(prefix) = pattern.strip_suffix('*') {
        return value.starts_with(prefix);
    }

    false
}

#[cfg(test)]
mod tests {
    use pretty_assertions::assert_eq;

    use super::{CapabilitiesFile, host_matches_pattern};

    #[test]
    fn wildcard_hosts_match() {
        assert!(host_matches_pattern("api.example.com", "*.example.com"));
        assert!(!host_matches_pattern("example.com", "*.example.com"));
        assert!(!host_matches_pattern("api.example.com", "example.com"));
    }

    #[test]
    fn secrets_wildcards_work() {
        let caps = CapabilitiesFile {
            secrets: Some(super::SecretsCapabilitySchema {
                allowed_names: vec!["openai_*".to_string(), "anthropic_api_key".to_string()],
            }),
            ..Default::default()
        };

        assert!(caps.secret_allowed("openai_api_key"));
        assert!(caps.secret_allowed("anthropic_api_key"));
        assert!(!caps.secret_allowed("other"));
    }

    #[test]
    fn workspace_path_checks() {
        let caps = CapabilitiesFile {
            workspace: Some(super::WorkspaceCapabilitySchema {
                allowed_prefixes: vec!["docs/".to_string()],
            }),
            ..Default::default()
        };

        assert!(caps.workspace_read_allowed("docs/readme.md"));
        assert!(!caps.workspace_read_allowed("src/main.rs"));
        assert!(!caps.workspace_read_allowed("../etc/passwd"));
        assert!(!caps.workspace_read_allowed("/tmp/a"));
    }

    #[test]
    fn http_allowlist_checks() {
        let caps = CapabilitiesFile {
            http: Some(super::HttpCapabilitySchema {
                allowlist: vec![super::EndpointPatternSchema {
                    host: "api.example.com".to_string(),
                    path_prefix: Some("/v1/".to_string()),
                    methods: vec!["GET".to_string(), "POST".to_string()],
                }],
                ..Default::default()
            }),
            ..Default::default()
        };

        assert!(caps.http_allowed("GET", "https://api.example.com/v1/users"));
        assert!(caps.http_allowed("post", "https://api.example.com/v1/users"));
        assert!(!caps.http_allowed("DELETE", "https://api.example.com/v1/users"));
        assert!(!caps.http_allowed("GET", "https://api.example.com/v2/users"));
    }

    #[test]
    fn summary_marks_enabled_capabilities() {
        let caps = CapabilitiesFile {
            workspace: Some(Default::default()),
            http: Some(Default::default()),
            tool_invoke: None,
            secrets: Some(Default::default()),
            auth: Some(Default::default()),
            exec: None,
        };

        let summary = caps.summary();
        assert_eq!(summary.workspace_read, true);
        assert_eq!(summary.http, true);
        assert_eq!(summary.tool_invoke, false);
        assert_eq!(summary.secrets, true);
        assert_eq!(summary.auth, true);
        assert_eq!(summary.exec, false);
    }

    #[test]
    fn exec_allowlist_validates_program_and_subcommand() {
        let caps = CapabilitiesFile {
            exec: Some(super::ExecCapabilitySchema {
                allowlist: vec![super::ExecAllowlistEntry {
                    program: "cast".to_string(),
                    allowed_subcommands: vec!["send".to_string(), "call".to_string()],
                    blocked_flags: vec!["--interactive".to_string()],
                }],
                ..Default::default()
            }),
            ..Default::default()
        };

        assert!(caps
            .exec_allowed("cast", &["send".to_string(), "--rpc-url".to_string()])
            .is_ok());
        assert!(caps
            .exec_allowed("cast", &["call".to_string()])
            .is_ok());
        assert!(caps
            .exec_allowed("cast", &["deploy".to_string()])
            .is_err());
        assert!(caps
            .exec_allowed("forge", &["build".to_string()])
            .is_err());
        assert!(caps
            .exec_allowed(
                "cast",
                &["send".to_string(), "--interactive".to_string()]
            )
            .is_err());
    }

    #[test]
    fn parses_exec_capability_schema() {
        let parsed: CapabilitiesFile = serde_json::from_str(
            r#"{
                "exec": {
                    "allowlist": [
                        {
                            "program": "cast",
                            "allowed_subcommands": ["send", "call"],
                            "blocked_flags": ["--interactive"]
                        }
                    ],
                    "credentials": {
                        "signing_key": {
                            "secret_name": "ETH_PRIVATE_KEY",
                            "injection": { "type": "arg", "flag": "--private-key" }
                        }
                    },
                    "rate_limit": { "requests_per_minute": 10 }
                }
            }"#,
        )
        .expect("exec should parse");

        let exec = parsed.exec.expect("exec section");
        assert_eq!(exec.allowlist.len(), 1);
        assert_eq!(exec.allowlist[0].program, "cast");
        assert_eq!(exec.credentials.len(), 1);
        assert_eq!(
            exec.credentials["signing_key"].secret_name,
            "ETH_PRIVATE_KEY"
        );
        assert_eq!(exec.rate_limit.unwrap().requests_per_minute, 10);
    }

    #[test]
    fn parses_auth_schema() {
        let parsed: CapabilitiesFile = serde_json::from_str(
            r#"{
                "auth": {
                    "secret_name": "github_token",
                    "display_name": "GitHub",
                    "instructions": "Create a personal access token",
                    "setup_url": "https://github.com/settings/tokens",
                    "env_var": "GITHUB_TOKEN",
                    "oauth": {
                        "authorization_url": "https://github.com/login/oauth/authorize",
                        "token_url": "https://github.com/login/oauth/access_token",
                        "client_id": "abc123"
                    }
                }
            }"#,
        )
        .expect("auth should parse");

        let auth = parsed.auth.expect("auth section");
        assert_eq!(auth.secret_name, "github_token");
        assert_eq!(auth.display_name.as_deref(), Some("GitHub"));
        assert_eq!(auth.env_var.as_deref(), Some("GITHUB_TOKEN"));
        assert_eq!(
            auth.oauth
                .expect("oauth section")
                .access_token_field
                .as_str(),
            "access_token"
        );
    }
}
