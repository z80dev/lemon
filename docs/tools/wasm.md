# WASM Tools Runtime

Lemon supports Ironclaw-compatible WASM tools through a per-session Rust sidecar runtime.

The Foundry/cast command tools under `native/wasm-tools/` share a support crate at `native/wasm-tools/common`. That crate owns common JSON param parsing, Ethereum address validation, secret placeholder injection, and host command execution/error formatting so credential-handling logic is reviewed in one place.

## Scope

- ABI: strict `tool.wit` parity (copied from Ironclaw).
- Sidecar lifecycle: one runtime process per `CodingAgent.Session`.
- Tool registration: one Lemon tool per discovered WASM module.
- Capabilities schema: Ironclaw-style top-level `http`, `secrets`, `tool_invoke`, `workspace`, `auth`.
- Precedence: built-in > WASM > extension.
- Output trust: all WASM tool results are marked `trust: :untrusted`.

## Enablement

WASM tools are opt-in and disabled by default.

```toml
[runtime.tools.wasm]
enabled = true
auto_build = true
runtime_path = ""
tool_paths = []
default_memory_limit = 10485760
default_timeout_ms = 60000
default_fuel_limit = 10000000
cache_compiled = true
cache_dir = ""
max_tool_invoke_depth = 4
```

`LEMON_WASM_*` environment variables (`ENABLED`, `AUTO_BUILD`, `RUNTIME_PATH`,
`TOOL_PATHS`, `DEFAULT_MEMORY_LIMIT`, `DEFAULT_TIMEOUT_MS`, `DEFAULT_FUEL_LIMIT`,
`CACHE_COMPILED`, `CACHE_DIR`, `MAX_TOOL_INVOKE_DEPTH`) override these keys; see
[Configuration](../config.md#wasm-tools).

Discovery roots:

1. `<cwd>/.lemon/wasm-tools`
2. `<agent dir>/wasm-tools` (`~/.lemon/agent/wasm-tools` by default; `LEMON_AGENT_DIR` changes the agent dir)
3. `runtime.tools.wasm.tool_paths`

Each module is discovered as:

- `<name>.wasm`
- Optional `<name>.capabilities.json`

## Runtime Build

If `runtime_path` is unset, Lemon expects the runtime binary at:

- `<repo>/_build/lemon-wasm-runtime/release/lemon-wasm-runtime`

With `auto_build = true`, Lemon runs:

```bash
CARGO_TARGET_DIR=<repo>/_build/lemon-wasm-runtime cargo build --release --manifest-path <repo>/native/lemon-wasm-runtime/Cargo.toml
```

Manual build example:

```bash
CARGO_TARGET_DIR=_build/lemon-wasm-runtime cargo build --release --manifest-path native/lemon-wasm-runtime/Cargo.toml
```

## Troubleshooting

1. `extensions_status` includes WASM runtime state (`enabled`, `running`, discovered tools, warnings/errors).
2. If runtime build fails, Lemon logs a warning and disables WASM tools for that session.
3. If discovery fails, non-WASM tools still load and the session continues.
4. If a WASM tool name conflicts:
   - Built-in tools always win.
   - WASM tools shadow extension tools.
   - Conflicts are logged and included in `extensions_status`.
5. If host tool callbacks fail (`tool-invoke` to non-WASM tools), the runtime returns an error to the caller tool.

