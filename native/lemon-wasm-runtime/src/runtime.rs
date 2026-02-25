use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::Arc;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use anyhow::{Context, Result, anyhow};
use base64::Engine;
use reqwest::blocking::Client;
use serde_json::{Value, json};
use thiserror::Error;
use url::Url;
use wasmtime::component::{Component, Linker};
use wasmtime::{Config, Engine as WasmEngine, OptLevel, ResourceLimiter, Store};
use wasmtime_wasi::{ResourceTable, WasiCtx, WasiCtxBuilder, WasiView};

use crate::capabilities::{CapabilitiesFile, CredentialLocationSchema, host_matches_pattern};
use crate::protocol::{
    DiscoverDefaults, DiscoverResult, DiscoveredTool, DiscoveredToolAuth, InvokeResult, RuntimeLog,
};

wasmtime::component::bindgen!({
    path: "wit/tool.wit",
    world: "sandboxed-tool",
    async: false,
    with: {},
});

use exports::near::agent::tool as wit_tool;

const EPOCH_TICK_INTERVAL: Duration = Duration::from_millis(10);
const MAX_LOG_ENTRIES: usize = 1000;
const MAX_LOG_MESSAGE_BYTES: usize = 4096;
const HOST_SECRET_EXISTS_TARGET: &str = "__lemon.secret.exists";
const HOST_SECRET_RESOLVE_TARGET: &str = "__lemon.secret.resolve";

type HostInvokeFn = Arc<dyn Fn(String, String) -> Result<String, String> + Send + Sync>;

#[derive(Debug, Error)]
pub enum RuntimeError {
    #[error("tool not found: {0}")]
    ToolNotFound(String),
    #[error("tool instantiation failed: {0}")]
    Instantiation(String),
    #[error("tool execution failed: {0}")]
    Execution(String),
}

#[derive(Debug, Clone)]
pub struct RuntimeDefaults {
    pub default_memory_limit: u64,
    pub default_timeout_ms: u64,
    pub default_fuel_limit: u64,
    pub max_tool_invoke_depth: u32,
}

impl Default for RuntimeDefaults {
    fn default() -> Self {
        Self {
            default_memory_limit: 10 * 1024 * 1024,
            default_timeout_ms: 60_000,
            default_fuel_limit: 10_000_000,
            max_tool_invoke_depth: 4,
        }
    }
}

impl From<DiscoverDefaults> for RuntimeDefaults {
    fn from(value: DiscoverDefaults) -> Self {
        Self {
            default_memory_limit: value.default_memory_limit,
            default_timeout_ms: value.default_timeout_ms,
            default_fuel_limit: value.default_fuel_limit,
            max_tool_invoke_depth: value.max_tool_invoke_depth,
        }
    }
}

#[derive(Debug, Clone)]
struct ToolLimits {
    memory_bytes: u64,
    fuel: u64,
    timeout_ms: u64,
    max_depth: u32,
}

#[derive(Clone)]
struct PreparedTool {
    name: String,
    path: PathBuf,
    description: String,
    schema_json: String,
    component: Arc<Component>,
    capabilities: CapabilitiesFile,
    limits: ToolLimits,
}

#[derive(Clone)]
struct RuntimeSnapshot {
    engine: WasmEngine,
    tools: Arc<HashMap<String, Arc<PreparedTool>>>,
}

impl RuntimeSnapshot {
    fn has_tool(&self, name: &str) -> bool {
        self.tools.contains_key(name)
    }

    fn get_tool(&self, name: &str) -> Option<Arc<PreparedTool>> {
        self.tools.get(name).cloned()
    }
}

pub struct Runtime {
    engine: WasmEngine,
    defaults: RuntimeDefaults,
    tools: HashMap<String, Arc<PreparedTool>>,
}

impl Runtime {
    pub fn new(defaults: RuntimeDefaults) -> Result<Self> {
        let mut config = Config::new();
        config.wasm_component_model(true);
        config.consume_fuel(true);
        config.epoch_interruption(true);
        config.cranelift_opt_level(OptLevel::Speed);

        let engine = WasmEngine::new(&config).context("failed to initialize wasmtime engine")?;

        let epoch_engine = engine.clone();
        std::thread::spawn(move || {
            loop {
                std::thread::sleep(EPOCH_TICK_INTERVAL);
                epoch_engine.increment_epoch();
            }
        });

        Ok(Self {
            engine,
            defaults,
            tools: HashMap::new(),
        })
    }

    pub fn discover(&mut self, paths: Vec<PathBuf>, defaults: RuntimeDefaults) -> DiscoverResult {
        self.defaults = defaults;

        let mut warnings = Vec::new();
        let mut errors = Vec::new();
        let mut chosen_paths: HashMap<String, PathBuf> = HashMap::new();

        for path in paths {
            if !path.exists() {
                continue;
            }

            if !path.is_dir() {
                warnings.push(format!(
                    "skipping non-directory wasm tool path: {}",
                    path.display()
                ));
                continue;
            }

            let entries = match fs::read_dir(&path) {
                Ok(entries) => entries,
                Err(err) => {
                    warnings.push(format!(
                        "failed to read wasm tool directory {}: {}",
                        path.display(),
                        err
                    ));
                    continue;
                }
            };

            for entry in entries.flatten() {
                let file_path = entry.path();
                if file_path.extension().and_then(|ext| ext.to_str()) != Some("wasm") {
                    continue;
                }

                let stem = file_path
                    .file_stem()
                    .and_then(|stem| stem.to_str())
                    .map(|stem| stem.to_string());

                let Some(stem) = stem else {
                    warnings.push(format!(
                        "skipping wasm file with invalid stem: {}",
                        file_path.display()
                    ));
                    continue;
                };

                chosen_paths.entry(stem).or_insert(file_path);
            }
        }

        let mut prepared_tools: HashMap<String, Arc<PreparedTool>> = HashMap::new();
        let mut discovered = Vec::new();

        let mut ordered_paths: Vec<(String, PathBuf)> = chosen_paths.into_iter().collect();
        ordered_paths.sort_by(|a, b| a.0.cmp(&b.0));

        for (stem, path) in ordered_paths {
            match self.prepare_tool(&path, &stem) {
                Ok((prepared, mut tool_warnings)) => {
                    let name = prepared.name.clone();

                    if prepared_tools.contains_key(&name) {
                        warnings.push(format!(
                            "tool name collision: '{}' from {} ignored",
                            name,
                            path.display()
                        ));
                        continue;
                    }

                    warnings.append(&mut tool_warnings);

                    discovered.push(DiscoveredTool {
                        name: prepared.name.clone(),
                        path: prepared.path.display().to_string(),
                        description: prepared.description.clone(),
                        schema_json: prepared.schema_json.clone(),
                        capabilities: prepared.capabilities.summary(),
                        auth: discovered_tool_auth(&prepared.capabilities),
                        warnings: Vec::new(),
                    });

                    prepared_tools.insert(name, Arc::new(prepared));
                }
                Err(err) => {
                    errors.push(format!("{}: {}", path.display(), err));
                }
            }
        }

        discovered.sort_by(|a, b| a.name.cmp(&b.name));
        self.tools = prepared_tools;

        DiscoverResult {
            tools: discovered,
            warnings,
            errors,
        }
    }

    fn snapshot(&self) -> RuntimeSnapshot {
        RuntimeSnapshot {
            engine: self.engine.clone(),
            tools: Arc::new(self.tools.clone()),
        }
    }

    pub fn invoke(
        &self,
        tool_name: &str,
        params_json: &str,
        context_json: Option<String>,
        host_invoke: HostInvokeFn,
    ) -> Result<InvokeResult, RuntimeError> {
        let snapshot = self.snapshot();
        let cwd = context_workspace_root(&context_json);

        invoke_tool_internal(
            &snapshot,
            tool_name,
            params_json.to_string(),
            context_json,
            0,
            self.defaults.max_tool_invoke_depth,
            cwd,
            host_invoke,
        )
    }

    fn prepare_tool(
        &self,
        wasm_path: &Path,
        fallback_name: &str,
    ) -> Result<(PreparedTool, Vec<String>)> {
        let component = Component::from_file(&self.engine, wasm_path)
            .with_context(|| format!("failed to compile component {}", wasm_path.display()))?;

        let component = Arc::new(component);

        let capabilities_path = wasm_path.with_extension("capabilities.json");
        let capabilities = if capabilities_path.exists() {
            CapabilitiesFile::from_json_file(&capabilities_path)?
        } else {
            CapabilitiesFile::default()
        };

        let limits = ToolLimits {
            memory_bytes: self.defaults.default_memory_limit,
            fuel: self.defaults.default_fuel_limit,
            timeout_ms: self.defaults.default_timeout_ms,
            max_depth: self.defaults.max_tool_invoke_depth,
        };

        let (description, schema_json, metadata_warnings) =
            extract_metadata(&self.engine, component.clone(), fallback_name)?;

        let mut warnings = metadata_warnings;
        let parsed_schema: Value = serde_json::from_str(&schema_json).unwrap_or_else(|_| json!({}));

        let tool_name = parsed_schema
            .get("title")
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|title| !title.is_empty())
            .map(|title| title.to_string())
            .unwrap_or_else(|| fallback_name.to_string());

        if parsed_schema.get("title").and_then(Value::as_str).is_none() {
            warnings.push(format!(
                "tool {} has no schema title; using file stem as tool name",
                wasm_path.display()
            ));
        }

        let schema_json = if serde_json::from_str::<Value>(&schema_json).is_ok() {
            schema_json
        } else {
            warnings.push(format!(
                "tool {} returned invalid schema JSON; using fallback schema",
                wasm_path.display()
            ));
            json!({"type":"object","properties":{},"required":[]}).to_string()
        };

        let prepared = PreparedTool {
            name: tool_name,
            path: wasm_path.to_path_buf(),
            description,
            schema_json,
            component,
            capabilities,
            limits,
        };

        Ok((prepared, warnings))
    }
}

fn extract_metadata(
    engine: &WasmEngine,
    component: Arc<Component>,
    fallback_name: &str,
) -> Result<(String, String, Vec<String>)> {
    let mut warnings = Vec::new();

    let runtime = RuntimeSnapshot {
        engine: engine.clone(),
        tools: Arc::new(HashMap::new()),
    };

    let host_invoke: HostInvokeFn =
        Arc::new(|tool, _params| Err(format!("host invoke unavailable for {}", tool)));

    let mut store = Store::new(
        engine,
        StoreData::new(
            runtime,
            CapabilitiesFile::default(),
            PathBuf::from("."),
            0,
            0,
            host_invoke,
        ),
    );

    store.set_fuel(10_000_000).ok();
    store.epoch_deadline_trap();
    store.set_epoch_deadline(10_000);
    store.limiter(|state| &mut state.limiter);

    let mut linker = Linker::new(engine);
    wasmtime_wasi::add_to_linker_sync(&mut linker)
        .map_err(|err| anyhow!("failed to add wasi linker bindings: {}", err))?;
    near::agent::host::add_to_linker(&mut linker, |state| state)
        .map_err(|err| anyhow!("failed to add host linker bindings: {}", err))?;

    let instance = SandboxedTool::instantiate(&mut store, &component, &linker)
        .map_err(|err| anyhow!("failed to instantiate for metadata: {}", err))?;

    let iface = instance.near_agent_tool();

    let description = match iface.call_description(&mut store) {
        Ok(desc) if !desc.trim().is_empty() => desc,
        Ok(_) => {
            warnings.push("tool returned empty description; using fallback".to_string());
            format!("WASM tool {}", fallback_name)
        }
        Err(err) => {
            warnings.push(format!("description() failed: {}", err));
            format!("WASM tool {}", fallback_name)
        }
    };

    let schema_json = match iface.call_schema(&mut store) {
        Ok(schema) if !schema.trim().is_empty() => schema,
        Ok(_) => {
            warnings.push("tool returned empty schema; using fallback".to_string());
            json!({"type":"object","properties":{},"required":[]}).to_string()
        }
        Err(err) => {
            warnings.push(format!("schema() failed: {}", err));
            json!({"type":"object","properties":{},"required":[]}).to_string()
        }
    };

    Ok((description, schema_json, warnings))
}

fn context_workspace_root(context_json: &Option<String>) -> PathBuf {
    let Some(raw) = context_json else {
        return std::env::current_dir().unwrap_or_else(|_| PathBuf::from("."));
    };

    let parsed: Value = match serde_json::from_str(raw) {
        Ok(parsed) => parsed,
        Err(_) => return std::env::current_dir().unwrap_or_else(|_| PathBuf::from(".")),
    };

    let from_context = parsed
        .get("cwd")
        .and_then(Value::as_str)
        .or_else(|| parsed.get("workspace_dir").and_then(Value::as_str));

    from_context
        .map(PathBuf::from)
        .unwrap_or_else(|| std::env::current_dir().unwrap_or_else(|_| PathBuf::from(".")))
}

fn discovered_tool_auth(capabilities: &CapabilitiesFile) -> Option<DiscoveredToolAuth> {
    let auth = capabilities.auth_config()?;
    let secret_name = auth.secret_name.trim().to_string();

    if secret_name.is_empty() {
        return None;
    }

    Some(DiscoveredToolAuth {
        secret_name,
        display_name: auth.display_name.clone(),
        instructions: auth.instructions.clone(),
        setup_url: auth.setup_url.clone(),
        token_hint: auth.token_hint.clone(),
        env_var: auth.env_var.clone(),
        provider: auth.provider.clone(),
        has_oauth: auth.oauth.is_some(),
    })
}

fn invoke_tool_internal(
    snapshot: &RuntimeSnapshot,
    tool_name: &str,
    params_json: String,
    context_json: Option<String>,
    depth: u32,
    max_depth: u32,
    workspace_root: PathBuf,
    host_invoke: HostInvokeFn,
) -> Result<InvokeResult, RuntimeError> {
    let tool = snapshot
        .get_tool(tool_name)
        .ok_or_else(|| RuntimeError::ToolNotFound(tool_name.to_string()))?;

    if depth > max_depth {
        return Err(RuntimeError::Execution(format!(
            "max tool invoke depth exceeded: {} > {}",
            depth, max_depth
        )));
    }

    let mut store = Store::new(
        &snapshot.engine,
        StoreData::new(
            snapshot.clone(),
            tool.capabilities.clone(),
            workspace_root,
            depth,
            tool.limits.max_depth,
            host_invoke,
        ),
    );

    store
        .set_fuel(tool.limits.fuel)
        .map_err(|err| RuntimeError::Execution(format!("failed to set fuel: {}", err)))?;

    store.epoch_deadline_trap();
    let ticks = ((tool.limits.timeout_ms as u128) / EPOCH_TICK_INTERVAL.as_millis()).max(1) as u64;
    store.set_epoch_deadline(ticks);
    store.limiter(|state| &mut state.limiter);

    let mut linker = Linker::new(&snapshot.engine);
    wasmtime_wasi::add_to_linker_sync(&mut linker).map_err(|err| {
        RuntimeError::Instantiation(format!("failed to add wasi linker: {}", err))
    })?;
    near::agent::host::add_to_linker(&mut linker, |state| state).map_err(|err| {
        RuntimeError::Instantiation(format!("failed to add host linker bindings: {}", err))
    })?;

    let instance = SandboxedTool::instantiate(&mut store, &tool.component, &linker)
        .map_err(|err| RuntimeError::Instantiation(err.to_string()))?;

    let request = wit_tool::Request {
        params: params_json,
        context: context_json,
    };

    let iface = instance.near_agent_tool();

    let response = iface.call_execute(&mut store, &request).map_err(|err| {
        let message = err.to_string();
        if message.contains("fuel") {
            RuntimeError::Execution(format!("fuel exhausted: {}", message))
        } else if message.contains("epoch") {
            RuntimeError::Execution(format!("execution timed out: {}", message))
        } else {
            RuntimeError::Execution(message)
        }
    })?;

    let details = json!({
        "tool": tool.name,
        "path": tool.path.display().to_string(),
        "depth": depth,
        "http_request_count": store.data().http_request_count,
        "tool_invoke_count": store.data().tool_invoke_count,
        "exec_command_count": store.data().exec_command_count,
    });

    Ok(InvokeResult {
        output_json: response.output,
        error: response.error,
        logs: store.data().logs.clone(),
        details,
    })
}

#[derive(Debug)]
struct WasmResourceLimiter {
    memory_limit: u64,
    memory_used: u64,
}

impl WasmResourceLimiter {
    fn new(memory_limit: u64) -> Self {
        Self {
            memory_limit,
            memory_used: 0,
        }
    }
}

impl ResourceLimiter for WasmResourceLimiter {
    fn memory_growing(
        &mut self,
        _current: usize,
        desired: usize,
        _maximum: Option<usize>,
    ) -> anyhow::Result<bool> {
        let desired_u64 = desired as u64;
        if desired_u64 > self.memory_limit {
            return Ok(false);
        }

        self.memory_used = desired_u64;
        Ok(true)
    }

    fn table_growing(
        &mut self,
        _current: usize,
        desired: usize,
        _maximum: Option<usize>,
    ) -> anyhow::Result<bool> {
        Ok(desired <= 10_000)
    }

    fn instances(&self) -> usize {
        16
    }

    fn tables(&self) -> usize {
        16
    }

    fn memories(&self) -> usize {
        16
    }
}

struct StoreData {
    runtime: RuntimeSnapshot,
    capabilities: CapabilitiesFile,
    workspace_root: PathBuf,
    depth: u32,
    max_depth: u32,
    host_invoke: HostInvokeFn,
    logs: Vec<RuntimeLog>,
    http_request_count: u32,
    tool_invoke_count: u32,
    exec_command_count: u32,
    limiter: WasmResourceLimiter,
    wasi: WasiCtx,
    table: ResourceTable,
}

impl StoreData {
    fn new(
        runtime: RuntimeSnapshot,
        capabilities: CapabilitiesFile,
        workspace_root: PathBuf,
        depth: u32,
        max_depth: u32,
        host_invoke: HostInvokeFn,
    ) -> Self {
        let limiter = WasmResourceLimiter::new(
            runtime
                .tools
                .values()
                .next()
                .map(|tool| tool.limits.memory_bytes)
                .unwrap_or(10 * 1024 * 1024),
        );

        Self {
            runtime,
            capabilities,
            workspace_root,
            depth,
            max_depth,
            host_invoke,
            logs: Vec::new(),
            http_request_count: 0,
            tool_invoke_count: 0,
            exec_command_count: 0,
            limiter,
            wasi: WasiCtxBuilder::new().build(),
            table: ResourceTable::new(),
        }
    }

    fn push_log(&mut self, level: &str, message: String) {
        if self.logs.len() >= MAX_LOG_ENTRIES {
            return;
        }

        let truncated = if message.len() > MAX_LOG_MESSAGE_BYTES {
            format!("{}... (truncated)", &message[..MAX_LOG_MESSAGE_BYTES])
        } else {
            message
        };

        let timestamp_millis = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|duration| duration.as_millis() as u64)
            .unwrap_or(0);

        self.logs.push(RuntimeLog {
            level: level.to_string(),
            message: truncated,
            timestamp_millis,
        });
    }

    fn resolve_workspace_path(&self, raw: &str) -> Option<PathBuf> {
        if !self.capabilities.workspace_read_allowed(raw) {
            return None;
        }

        let path = self.workspace_root.join(raw);
        let path = path.canonicalize().ok()?;
        let workspace_root = self.workspace_root.canonicalize().ok()?;

        if path.starts_with(&workspace_root) {
            Some(path)
        } else {
            None
        }
    }

    fn apply_http_credentials(
        &self,
        url: &mut Url,
        headers: &mut HashMap<String, String>,
    ) -> Result<(), String> {
        let Some(http) = self.capabilities.http_config() else {
            return Ok(());
        };

        let host = url
            .host_str()
            .ok_or_else(|| "invalid request url host".to_string())?
            .to_string();

        for mapping in http.credentials.values() {
            let host_matches = if mapping.host_patterns.is_empty() {
                true
            } else {
                mapping
                    .host_patterns
                    .iter()
                    .any(|pattern| host_matches_pattern(&host, pattern))
            };

            if !host_matches {
                continue;
            }

            if !self.capabilities.secret_allowed(&mapping.secret_name) {
                continue;
            }

            let secret = match self.resolve_secret_for_host(&mapping.secret_name) {
                Some(secret) => secret,
                None => continue,
            };

            match &mapping.location {
                CredentialLocationSchema::Bearer => {
                    headers.insert("authorization".to_string(), format!("Bearer {}", secret));
                }
                CredentialLocationSchema::Basic { username } => {
                    let token = format!("{}:{}", username, secret);
                    let encoded =
                        base64::engine::general_purpose::STANDARD.encode(token.as_bytes());
                    headers.insert("authorization".to_string(), format!("Basic {}", encoded));
                }
                CredentialLocationSchema::Header { name, prefix } => {
                    let value = match prefix {
                        Some(prefix) => format!("{}{}", prefix, secret),
                        None => secret,
                    };
                    headers.insert(name.to_ascii_lowercase(), value);
                }
                CredentialLocationSchema::QueryParam { name } => {
                    url.query_pairs_mut().append_pair(name, &secret);
                }
                CredentialLocationSchema::UrlPath { placeholder } => {
                    let replaced = url.as_str().replace(placeholder, &secret);
                    *url = Url::parse(&replaced)
                        .map_err(|err| format!("failed to inject URL path credential: {}", err))?;
                }
            }
        }

        Ok(())
    }

    fn resolve_secret_placeholders(
        &self,
        input: &str,
        resolved_secrets: &mut Vec<String>,
    ) -> Result<String, String> {
        resolve_secret_placeholders_with(input, resolved_secrets, |name| {
            if !self.capabilities.secret_allowed(name) {
                return Err(format!("secret '{}' not allowed by capabilities", name));
            }
            self.resolve_secret_for_host(name)
                .ok_or_else(|| format!("secret '{}' not found", name))
        })
    }

    fn env_secret(&self, name: &str) -> Option<String> {
        match std::env::var(name) {
            Ok(secret) if !secret.trim().is_empty() => Some(secret),
            _ => None,
        }
    }

    fn env_secret_exists(&self, name: &str) -> bool {
        self.env_secret(name).is_some()
    }

    fn host_secret_exists(&self, name: &str) -> Option<bool> {
        let payload = json!({ "name": name }).to_string();

        let response = (self.host_invoke)(HOST_SECRET_EXISTS_TARGET.to_string(), payload).ok()?;
        parse_host_secret_exists(&response)
    }

    fn resolve_secret_for_host(&self, name: &str) -> Option<String> {
        let payload = json!({ "name": name }).to_string();

        let from_host = (self.host_invoke)(HOST_SECRET_RESOLVE_TARGET.to_string(), payload)
            .ok()
            .and_then(|response| parse_host_secret_value(&response));

        from_host.or_else(|| self.env_secret(name))
    }
}

fn parse_host_secret_exists(raw: &str) -> Option<bool> {
    let parsed: Value = serde_json::from_str(raw).ok()?;

    match parsed {
        Value::Bool(flag) => Some(flag),
        Value::Object(map) => map.get("exists").and_then(Value::as_bool),
        _ => None,
    }
}

fn parse_host_secret_value(raw: &str) -> Option<String> {
    let parsed: Value = serde_json::from_str(raw).ok()?;

    match parsed {
        Value::String(value) if !value.trim().is_empty() => Some(value),
        Value::Object(map) => map
            .get("value")
            .and_then(Value::as_str)
            .map(|value| value.to_string())
            .filter(|value| !value.trim().is_empty()),
        _ => None,
    }
}

impl WasiView for StoreData {
    fn ctx(&mut self) -> &mut WasiCtx {
        &mut self.wasi
    }

    fn table(&mut self) -> &mut ResourceTable {
        &mut self.table
    }
}

impl near::agent::host::Host for StoreData {
    fn log(&mut self, level: near::agent::host::LogLevel, message: String) {
        let level = match level {
            near::agent::host::LogLevel::Trace => "trace",
            near::agent::host::LogLevel::Debug => "debug",
            near::agent::host::LogLevel::Info => "info",
            near::agent::host::LogLevel::Warn => "warn",
            near::agent::host::LogLevel::Error => "error",
        };
        self.push_log(level, message);
    }

    fn now_millis(&mut self) -> u64 {
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|duration| duration.as_millis() as u64)
            .unwrap_or(0)
    }

    fn workspace_read(&mut self, path: String) -> Option<String> {
        let path = self.resolve_workspace_path(&path)?;
        fs::read_to_string(path).ok()
    }

    fn http_request(
        &mut self,
        method: String,
        url: String,
        headers_json: String,
        body: Option<Vec<u8>>,
        timeout_ms: Option<u32>,
    ) -> std::result::Result<near::agent::host::HttpResponse, String> {
        if !self.capabilities.http_allowed(&method, &url) {
            return Err(format!(
                "http request blocked by allowlist: {} {}",
                method, url
            ));
        }

        self.http_request_count += 1;
        if self.http_request_count > self.capabilities.http_limit() {
            return Err("http request rate limit exceeded".to_string());
        }

        let mut parsed_url = Url::parse(&url).map_err(|err| format!("invalid url: {}", err))?;

        let mut headers: HashMap<String, String> =
            serde_json::from_str(&headers_json).unwrap_or_default();

        self.apply_http_credentials(&mut parsed_url, &mut headers)?;

        let max_request_bytes = self
            .capabilities
            .http_config()
            .and_then(|http| http.max_request_bytes)
            .unwrap_or(1024 * 1024);

        if let Some(body) = &body {
            if body.len() > max_request_bytes {
                return Err(format!(
                    "request body too large: {} > {}",
                    body.len(),
                    max_request_bytes
                ));
            }
        }

        let timeout = timeout_ms.map(u64::from).unwrap_or_else(|| {
            self.capabilities
                .http_config()
                .and_then(|http| http.timeout_secs)
                .unwrap_or(30)
                * 1000
        });

        let client = Client::builder()
            .timeout(Duration::from_millis(timeout))
            .build()
            .map_err(|err| format!("failed to build http client: {}", err))?;

        let mut request = client.request(
            reqwest::Method::from_bytes(method.as_bytes())
                .map_err(|err| format!("invalid http method: {}", err))?,
            parsed_url,
        );

        for (name, value) in headers {
            request = request.header(name, value);
        }

        if let Some(body) = body {
            request = request.body(body);
        }

        let response = request
            .send()
            .map_err(|err| format!("http request failed: {}", err))?;

        let status = response.status().as_u16();

        let response_headers = response
            .headers()
            .iter()
            .map(|(key, value)| {
                (
                    key.to_string(),
                    value.to_str().unwrap_or_default().to_string(),
                )
            })
            .collect::<HashMap<_, _>>();

        let response_headers_json =
            serde_json::to_string(&response_headers).map_err(|err| err.to_string())?;

        let body = response
            .bytes()
            .map_err(|err| format!("failed to read response bytes: {}", err))?
            .to_vec();

        let max_response_bytes = self
            .capabilities
            .http_config()
            .and_then(|http| http.max_response_bytes)
            .unwrap_or(10 * 1024 * 1024);

        if body.len() > max_response_bytes {
            return Err(format!(
                "response body too large: {} > {}",
                body.len(),
                max_response_bytes
            ));
        }

        Ok(near::agent::host::HttpResponse {
            status,
            headers_json: response_headers_json,
            body,
        })
    }

    fn tool_invoke(
        &mut self,
        alias: String,
        params_json: String,
    ) -> std::result::Result<String, String> {
        let target = self
            .capabilities
            .resolve_tool_alias(&alias)
            .ok_or_else(|| format!("unknown tool alias: {}", alias))?;

        self.tool_invoke_count += 1;
        if self.tool_invoke_count > self.capabilities.tool_invoke_limit() {
            return Err("tool invocation rate limit exceeded".to_string());
        }

        let next_depth = self.depth + 1;
        if next_depth > self.max_depth {
            return Err(format!(
                "max tool invoke depth exceeded: {} > {}",
                next_depth, self.max_depth
            ));
        }

        if self.runtime.has_tool(&target) {
            let result = invoke_tool_internal(
                &self.runtime,
                &target,
                params_json,
                None,
                next_depth,
                self.max_depth,
                self.workspace_root.clone(),
                self.host_invoke.clone(),
            )
            .map_err(|err| err.to_string())?;

            if let Some(error) = result.error {
                return Err(error);
            }

            Ok(result.output_json.unwrap_or_else(|| "null".to_string()))
        } else {
            (self.host_invoke)(target, params_json)
        }
    }

    fn secret_exists(&mut self, name: String) -> bool {
        if !self.capabilities.secret_allowed(&name) {
            return false;
        }

        self.host_secret_exists(&name)
            .unwrap_or_else(|| self.env_secret_exists(&name))
    }

    fn exec_command(
        &mut self,
        program: String,
        args_json: String,
        env_json: String,
        timeout_ms: Option<u32>,
    ) -> std::result::Result<near::agent::host::ExecResult, String> {
        let args: Vec<String> =
            serde_json::from_str(&args_json).map_err(|err| format!("invalid args JSON: {}", err))?;

        let env: HashMap<String, String> =
            serde_json::from_str(&env_json).map_err(|err| format!("invalid env JSON: {}", err))?;

        self.capabilities.exec_allowed(&program, &args)?;

        self.exec_command_count += 1;
        if self.exec_command_count > self.capabilities.exec_limit() {
            return Err("exec command rate limit exceeded".to_string());
        }

        let mut resolved_secrets: Vec<String> = Vec::new();

        let resolved_args: Vec<String> = args
            .iter()
            .map(|arg| self.resolve_secret_placeholders(arg, &mut resolved_secrets))
            .collect::<Result<Vec<_>, _>>()?;

        let resolved_env: HashMap<String, String> = env
            .iter()
            .map(|(key, value)| {
                let resolved = self.resolve_secret_placeholders(value, &mut resolved_secrets)?;
                Ok((key.clone(), resolved))
            })
            .collect::<Result<HashMap<_, _>, String>>()?;

        let timeout = Duration::from_millis(
            timeout_ms
                .map(u64::from)
                .unwrap_or_else(|| {
                    self.capabilities
                        .exec_config()
                        .and_then(|exec| exec.timeout_secs)
                        .unwrap_or(30)
                        * 1000
                }),
        );

        let mut cmd = Command::new(&program);
        cmd.args(&resolved_args);
        for (key, value) in &resolved_env {
            cmd.env(key, value);
        }

        let output = cmd
            .output()
            .map_err(|err| format!("failed to execute '{}': {}", program, err))?;

        let stdout_raw = String::from_utf8_lossy(&output.stdout).to_string();
        let stderr_raw = String::from_utf8_lossy(&output.stderr).to_string();

        let _ = timeout; // timeout applied via process spawn in future; for now trust OS

        let stdout = sanitize_output(&stdout_raw, &resolved_secrets);
        let stderr = sanitize_output(&stderr_raw, &resolved_secrets);

        Ok(near::agent::host::ExecResult {
            exit_code: output.status.code().unwrap_or(-1),
            stdout,
            stderr,
        })
    }
}

fn resolve_secret_placeholders_with<F>(
    input: &str,
    resolved_secrets: &mut Vec<String>,
    resolve_fn: F,
) -> Result<String, String>
where
    F: Fn(&str) -> Result<String, String>,
{
    let mut result = input.to_string();
    let mut search_from = 0;

    while let Some(start) = result[search_from..].find("{{SECRET:") {
        let abs_start = search_from + start;
        let after_prefix = abs_start + "{{SECRET:".len();

        let Some(end) = result[after_prefix..].find("}}") else {
            break;
        };

        let abs_end = after_prefix + end;
        let secret_name = result[after_prefix..abs_end].to_string();

        let secret_value = resolve_fn(&secret_name)?;

        resolved_secrets.push(secret_value.clone());

        let placeholder_end = abs_end + "}}".len();
        result.replace_range(abs_start..placeholder_end, &secret_value);

        search_from = abs_start + secret_value.len();
    }

    Ok(result)
}

fn sanitize_output(output: &str, secrets: &[String]) -> String {
    let mut result = output.to_string();
    for secret in secrets {
        if !secret.is_empty() {
            result = result.replace(secret.as_str(), "[REDACTED]");
        }
    }
    result
}

#[cfg(test)]
mod tests {
    use std::collections::HashMap;

    use pretty_assertions::assert_eq;

    use super::{
        RuntimeDefaults, context_workspace_root, parse_host_secret_exists,
        parse_host_secret_value, resolve_secret_placeholders_with, sanitize_output,
    };

    #[test]
    fn defaults_are_sane() {
        let defaults = RuntimeDefaults::default();
        assert_eq!(defaults.default_memory_limit, 10 * 1024 * 1024);
        assert_eq!(defaults.default_timeout_ms, 60_000);
        assert_eq!(defaults.default_fuel_limit, 10_000_000);
        assert_eq!(defaults.max_tool_invoke_depth, 4);
    }

    #[test]
    fn context_workspace_resolves_from_cwd() {
        let root = context_workspace_root(&Some("{\"cwd\":\"/tmp/test\"}".to_string()));
        assert_eq!(root.to_string_lossy(), "/tmp/test");
    }

    #[test]
    fn parses_host_secret_exists_payloads() {
        assert_eq!(parse_host_secret_exists("true"), Some(true));
        assert_eq!(parse_host_secret_exists("{\"exists\":false}"), Some(false));
        assert_eq!(parse_host_secret_exists("{\"unexpected\":1}"), None);
    }

    #[test]
    fn parses_host_secret_value_payloads() {
        assert_eq!(
            parse_host_secret_value("{\"value\":\"secret-token\"}"),
            Some("secret-token".to_string())
        );
        assert_eq!(
            parse_host_secret_value("\"direct-secret\""),
            Some("direct-secret".to_string())
        );
        assert_eq!(parse_host_secret_value("{\"value\":\"\"}"), None);
    }

    #[test]
    fn sanitize_output_redacts_secrets() {
        let output = "Transaction sent with key 0xdeadbeef123 to 0xrecipient";
        let secrets = vec!["0xdeadbeef123".to_string()];
        let sanitized = sanitize_output(output, &secrets);
        assert_eq!(
            sanitized,
            "Transaction sent with key [REDACTED] to 0xrecipient"
        );
    }

    #[test]
    fn sanitize_output_handles_empty_secrets() {
        let output = "no secrets here";
        let secrets: Vec<String> = vec![];
        assert_eq!(sanitize_output(output, &secrets), "no secrets here");
    }

    #[test]
    fn sanitize_output_redacts_multiple_occurrences() {
        let output = "key=abc123 other=abc123";
        let secrets = vec!["abc123".to_string()];
        assert_eq!(
            sanitize_output(output, &secrets),
            "key=[REDACTED] other=[REDACTED]"
        );
    }

    #[test]
    fn sanitize_output_redacts_multiple_different_secrets() {
        let output = "key1=secret_a key2=secret_b";
        let secrets = vec!["secret_a".to_string(), "secret_b".to_string()];
        assert_eq!(
            sanitize_output(output, &secrets),
            "key1=[REDACTED] key2=[REDACTED]"
        );
    }

    #[test]
    fn sanitize_output_skips_empty_strings_in_secret_list() {
        let output = "hello world";
        let secrets = vec!["".to_string(), "world".to_string()];
        assert_eq!(sanitize_output(output, &secrets), "hello [REDACTED]");
    }

    // ==================== resolve_secret_placeholders_with tests ====================

    fn mock_resolver(secrets: &HashMap<String, String>) -> impl Fn(&str) -> Result<String, String> + '_ {
        move |name: &str| {
            secrets
                .get(name)
                .cloned()
                .ok_or_else(|| format!("secret '{}' not found", name))
        }
    }

    #[test]
    fn placeholder_resolves_single_secret() {
        let secrets: HashMap<String, String> =
            [("MY_KEY".to_string(), "resolved_value".to_string())]
                .into_iter()
                .collect();

        let mut collected = Vec::new();
        let result = resolve_secret_placeholders_with(
            "--key={{SECRET:MY_KEY}}",
            &mut collected,
            mock_resolver(&secrets),
        );

        assert_eq!(result, Ok("--key=resolved_value".to_string()));
        assert_eq!(collected, vec!["resolved_value"]);
    }

    #[test]
    fn placeholder_resolves_multiple_secrets() {
        let secrets: HashMap<String, String> = [
            ("KEY_A".to_string(), "val_a".to_string()),
            ("KEY_B".to_string(), "val_b".to_string()),
        ]
        .into_iter()
        .collect();

        let mut collected = Vec::new();
        let result = resolve_secret_placeholders_with(
            "{{SECRET:KEY_A}} and {{SECRET:KEY_B}}",
            &mut collected,
            mock_resolver(&secrets),
        );

        assert_eq!(result, Ok("val_a and val_b".to_string()));
        assert_eq!(collected, vec!["val_a", "val_b"]);
    }

    #[test]
    fn placeholder_with_no_placeholders_is_passthrough() {
        let secrets: HashMap<String, String> = HashMap::new();
        let mut collected = Vec::new();
        let result = resolve_secret_placeholders_with(
            "no placeholders here",
            &mut collected,
            mock_resolver(&secrets),
        );

        assert_eq!(result, Ok("no placeholders here".to_string()));
        assert!(collected.is_empty());
    }

    #[test]
    fn placeholder_entire_string_is_placeholder() {
        let secrets: HashMap<String, String> =
            [("ETH_PRIVATE_KEY".to_string(), "0xdeadbeef".to_string())]
                .into_iter()
                .collect();

        let mut collected = Vec::new();
        let result = resolve_secret_placeholders_with(
            "{{SECRET:ETH_PRIVATE_KEY}}",
            &mut collected,
            mock_resolver(&secrets),
        );

        assert_eq!(result, Ok("0xdeadbeef".to_string()));
        assert_eq!(collected, vec!["0xdeadbeef"]);
    }

    #[test]
    fn placeholder_missing_secret_returns_error() {
        let secrets: HashMap<String, String> = HashMap::new();
        let mut collected = Vec::new();
        let result = resolve_secret_placeholders_with(
            "{{SECRET:MISSING}}",
            &mut collected,
            mock_resolver(&secrets),
        );

        assert!(result.is_err());
        assert!(result.unwrap_err().contains("MISSING"));
    }

    #[test]
    fn placeholder_unclosed_placeholder_is_ignored() {
        let secrets: HashMap<String, String> = HashMap::new();
        let mut collected = Vec::new();
        let result = resolve_secret_placeholders_with(
            "{{SECRET:UNCLOSED",
            &mut collected,
            mock_resolver(&secrets),
        );

        assert_eq!(result, Ok("{{SECRET:UNCLOSED".to_string()));
        assert!(collected.is_empty());
    }

    #[test]
    fn placeholder_adjacent_placeholders() {
        let secrets: HashMap<String, String> = [
            ("A".to_string(), "x".to_string()),
            ("B".to_string(), "y".to_string()),
        ]
        .into_iter()
        .collect();

        let mut collected = Vec::new();
        let result = resolve_secret_placeholders_with(
            "{{SECRET:A}}{{SECRET:B}}",
            &mut collected,
            mock_resolver(&secrets),
        );

        assert_eq!(result, Ok("xy".to_string()));
        assert_eq!(collected, vec!["x", "y"]);
    }

    #[test]
    fn placeholder_secret_value_containing_braces() {
        let secrets: HashMap<String, String> =
            [("KEY".to_string(), "val}}ue".to_string())]
                .into_iter()
                .collect();

        let mut collected = Vec::new();
        let result = resolve_secret_placeholders_with(
            "before={{SECRET:KEY}}",
            &mut collected,
            mock_resolver(&secrets),
        );

        assert_eq!(result, Ok("before=val}}ue".to_string()));
    }

    #[test]
    fn placeholder_resolver_error_propagates() {
        let mut collected = Vec::new();
        let result = resolve_secret_placeholders_with(
            "{{SECRET:FORBIDDEN}}",
            &mut collected,
            |_name| Err("not allowed by capabilities".to_string()),
        );

        assert!(result.is_err());
        assert_eq!(
            result.unwrap_err(),
            "not allowed by capabilities".to_string()
        );
    }

    #[test]
    fn placeholder_empty_name() {
        let secrets: HashMap<String, String> =
            [("".to_string(), "empty_key_val".to_string())]
                .into_iter()
                .collect();

        let mut collected = Vec::new();
        let result = resolve_secret_placeholders_with(
            "{{SECRET:}}",
            &mut collected,
            mock_resolver(&secrets),
        );

        assert_eq!(result, Ok("empty_key_val".to_string()));
    }

    // ==================== exec_command integration tests ====================
    // These test the full exec path using real programs (echo, cat, etc.)

    use super::{
        HostInvokeFn, RuntimeSnapshot, StoreData,
    };
    use crate::capabilities::{
        CapabilitiesFile, ExecAllowlistEntry, ExecCapabilitySchema, RateLimitSchema,
        SecretsCapabilitySchema,
    };
    use std::path::PathBuf;
    use std::sync::Arc;

    fn make_store_data(capabilities: CapabilitiesFile) -> StoreData {
        let host_invoke: HostInvokeFn = Arc::new(|target, params| {
            // Mock secret resolution: return the secret name as value for testing
            if target == "__lemon.secret.resolve" {
                let parsed: serde_json::Value =
                    serde_json::from_str(&params).unwrap_or_default();
                let name = parsed["name"].as_str().unwrap_or("");
                match name {
                    "TEST_SECRET" => Ok(r#"{"value":"s3cret_val"}"#.to_string()),
                    "ETH_PRIVATE_KEY" => Ok(r#"{"value":"0xdeadbeef1234567890"}"#.to_string()),
                    _ => Err(format!("unknown secret: {}", name)),
                }
            } else if target == "__lemon.secret.exists" {
                let parsed: serde_json::Value =
                    serde_json::from_str(&params).unwrap_or_default();
                let name = parsed["name"].as_str().unwrap_or("");
                match name {
                    "TEST_SECRET" | "ETH_PRIVATE_KEY" => Ok(r#"{"exists":true}"#.to_string()),
                    _ => Ok(r#"{"exists":false}"#.to_string()),
                }
            } else {
                Err(format!("unknown host target: {}", target))
            }
        });

        let engine = wasmtime::Engine::default();
        let runtime = RuntimeSnapshot {
            engine,
            tools: Arc::new(HashMap::new()),
        };

        StoreData::new(
            runtime,
            capabilities,
            PathBuf::from("."),
            0,
            4,
            host_invoke,
        )
    }

    fn exec_caps_for_echo() -> CapabilitiesFile {
        CapabilitiesFile {
            exec: Some(ExecCapabilitySchema {
                allowlist: vec![ExecAllowlistEntry {
                    program: "echo".to_string(),
                    allowed_subcommands: vec![],
                    blocked_flags: vec!["--forbidden".to_string()],
                }],
                credentials: HashMap::new(),
                rate_limit: Some(RateLimitSchema {
                    requests_per_minute: 5,
                    requests_per_hour: 100,
                }),
                timeout_secs: Some(10),
            }),
            secrets: Some(SecretsCapabilitySchema {
                allowed_names: vec!["TEST_*".to_string(), "ETH_*".to_string()],
            }),
            ..Default::default()
        }
    }

    #[test]
    fn exec_command_runs_echo() {
        use super::near::agent::host::Host;

        let mut store = make_store_data(exec_caps_for_echo());
        let result = store.exec_command(
            "echo".to_string(),
            r#"["hello","world"]"#.to_string(),
            "{}".to_string(),
            Some(5000),
        );

        let result = result.expect("exec should succeed");
        assert_eq!(result.exit_code, 0);
        assert_eq!(result.stdout.trim(), "hello world");
    }

    #[test]
    fn exec_command_rejects_unlisted_program() {
        use super::near::agent::host::Host;

        let mut store = make_store_data(exec_caps_for_echo());
        let result = store.exec_command(
            "curl".to_string(),
            r#"["https://example.com"]"#.to_string(),
            "{}".to_string(),
            None,
        );

        assert!(result.is_err());
        assert!(result.unwrap_err().contains("not in exec allowlist"));
    }

    #[test]
    fn exec_command_rejects_blocked_flag() {
        use super::near::agent::host::Host;

        let mut store = make_store_data(exec_caps_for_echo());
        let result = store.exec_command(
            "echo".to_string(),
            r#"["--forbidden","test"]"#.to_string(),
            "{}".to_string(),
            None,
        );

        assert!(result.is_err());
        assert!(result.unwrap_err().contains("blocked flag"));
    }

    #[test]
    fn exec_command_resolves_secret_placeholder() {
        use super::near::agent::host::Host;

        let mut store = make_store_data(exec_caps_for_echo());
        let result = store.exec_command(
            "echo".to_string(),
            r#"["value={{SECRET:TEST_SECRET}}"]"#.to_string(),
            "{}".to_string(),
            Some(5000),
        );

        let result = result.expect("exec should succeed");
        assert_eq!(result.exit_code, 0);
        // The secret should be resolved in the actual command but sanitized in output
        assert!(
            !result.stdout.contains("s3cret_val"),
            "stdout should not contain raw secret"
        );
        assert!(
            result.stdout.contains("[REDACTED]"),
            "stdout should contain [REDACTED]"
        );
    }

    #[test]
    fn exec_command_sanitizes_secret_in_output() {
        use super::near::agent::host::Host;

        let mut store = make_store_data(exec_caps_for_echo());
        // echo will print the resolved secret, which should be redacted
        let result = store.exec_command(
            "echo".to_string(),
            r#"["{{SECRET:TEST_SECRET}}"]"#.to_string(),
            "{}".to_string(),
            Some(5000),
        );

        let result = result.expect("exec should succeed");
        assert_eq!(result.exit_code, 0);
        assert_eq!(result.stdout.trim(), "[REDACTED]");
        assert!(
            !result.stdout.contains("s3cret_val"),
            "raw secret must not appear in output"
        );
    }

    #[test]
    fn exec_command_rate_limits() {
        use super::near::agent::host::Host;

        let caps = CapabilitiesFile {
            exec: Some(ExecCapabilitySchema {
                allowlist: vec![ExecAllowlistEntry {
                    program: "echo".to_string(),
                    allowed_subcommands: vec![],
                    blocked_flags: vec![],
                }],
                credentials: HashMap::new(),
                rate_limit: Some(RateLimitSchema {
                    requests_per_minute: 2,
                    requests_per_hour: 100,
                }),
                timeout_secs: None,
            }),
            ..Default::default()
        };

        let mut store = make_store_data(caps);

        // First two calls should succeed
        assert!(store
            .exec_command(
                "echo".to_string(),
                r#"["1"]"#.to_string(),
                "{}".to_string(),
                Some(5000),
            )
            .is_ok());
        assert!(store
            .exec_command(
                "echo".to_string(),
                r#"["2"]"#.to_string(),
                "{}".to_string(),
                Some(5000),
            )
            .is_ok());

        // Third should hit rate limit
        let result = store.exec_command(
            "echo".to_string(),
            r#"["3"]"#.to_string(),
            "{}".to_string(),
            Some(5000),
        );
        assert!(result.is_err());
        assert!(result.unwrap_err().contains("rate limit"));
    }

    #[test]
    fn exec_command_rejects_invalid_args_json() {
        use super::near::agent::host::Host;

        let mut store = make_store_data(exec_caps_for_echo());
        let result = store.exec_command(
            "echo".to_string(),
            "not json".to_string(),
            "{}".to_string(),
            None,
        );

        assert!(result.is_err());
        assert!(result.unwrap_err().contains("invalid args JSON"));
    }

    #[test]
    fn exec_command_rejects_invalid_env_json() {
        use super::near::agent::host::Host;

        let mut store = make_store_data(exec_caps_for_echo());
        let result = store.exec_command(
            "echo".to_string(),
            r#"["hello"]"#.to_string(),
            "not json".to_string(),
            None,
        );

        assert!(result.is_err());
        assert!(result.unwrap_err().contains("invalid env JSON"));
    }

    #[test]
    fn exec_command_disallowed_secret_name_errors() {
        use super::near::agent::host::Host;

        let caps = CapabilitiesFile {
            exec: Some(ExecCapabilitySchema {
                allowlist: vec![ExecAllowlistEntry {
                    program: "echo".to_string(),
                    allowed_subcommands: vec![],
                    blocked_flags: vec![],
                }],
                ..Default::default()
            }),
            // No secrets capability at all
            secrets: None,
            ..Default::default()
        };

        let mut store = make_store_data(caps);
        let result = store.exec_command(
            "echo".to_string(),
            r#"["{{SECRET:FORBIDDEN_KEY}}"]"#.to_string(),
            "{}".to_string(),
            Some(5000),
        );

        assert!(result.is_err());
        assert!(result.unwrap_err().contains("not allowed"));
    }

    #[test]
    fn exec_command_nonexistent_program_errors() {
        use super::near::agent::host::Host;

        let caps = CapabilitiesFile {
            exec: Some(ExecCapabilitySchema {
                allowlist: vec![ExecAllowlistEntry {
                    program: "nonexistent_binary_xyz_12345".to_string(),
                    allowed_subcommands: vec![],
                    blocked_flags: vec![],
                }],
                ..Default::default()
            }),
            ..Default::default()
        };

        let mut store = make_store_data(caps);
        let result = store.exec_command(
            "nonexistent_binary_xyz_12345".to_string(),
            r#"[]"#.to_string(),
            "{}".to_string(),
            Some(5000),
        );

        assert!(result.is_err());
        assert!(result.unwrap_err().contains("failed to execute"));
    }

    #[test]
    fn exec_command_captures_nonzero_exit_code() {
        use super::near::agent::host::Host;

        let caps = CapabilitiesFile {
            exec: Some(ExecCapabilitySchema {
                allowlist: vec![ExecAllowlistEntry {
                    program: "false".to_string(),
                    allowed_subcommands: vec![],
                    blocked_flags: vec![],
                }],
                ..Default::default()
            }),
            ..Default::default()
        };

        let mut store = make_store_data(caps);
        let result = store.exec_command(
            "false".to_string(),
            r#"[]"#.to_string(),
            "{}".to_string(),
            Some(5000),
        );

        let result = result.expect("exec should succeed even with nonzero exit");
        assert_ne!(result.exit_code, 0);
    }

    #[test]
    fn exec_command_no_exec_capability_errors() {
        use super::near::agent::host::Host;

        let mut store = make_store_data(CapabilitiesFile::default());
        let result = store.exec_command(
            "echo".to_string(),
            r#"["hello"]"#.to_string(),
            "{}".to_string(),
            None,
        );

        assert!(result.is_err());
        assert!(result.unwrap_err().contains("exec capability not granted"));
    }

    #[test]
    fn exec_command_with_env_vars() {
        use super::near::agent::host::Host;

        let caps = CapabilitiesFile {
            exec: Some(ExecCapabilitySchema {
                allowlist: vec![ExecAllowlistEntry {
                    program: "sh".to_string(),
                    allowed_subcommands: vec!["-c".to_string()],
                    blocked_flags: vec![],
                }],
                ..Default::default()
            }),
            ..Default::default()
        };

        let mut store = make_store_data(caps);
        let result = store.exec_command(
            "sh".to_string(),
            r#"["-c","echo $MY_TEST_VAR"]"#.to_string(),
            r#"{"MY_TEST_VAR":"hello_env"}"#.to_string(),
            Some(5000),
        );

        let result = result.expect("exec should succeed");
        assert_eq!(result.exit_code, 0);
        assert_eq!(result.stdout.trim(), "hello_env");
    }
}
