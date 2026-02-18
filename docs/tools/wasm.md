# WASM Tools Runtime

Lemon supports Ironclaw-compatible WASM tools through a per-session Rust sidecar runtime.

## Scope

- ABI: strict `tool.wit` parity (copied from Ironclaw).
- Sidecar lifecycle: one runtime process per `CodingAgent.Session`.
- Tool registration: one Lemon tool per discovered WASM module.
- Precedence: built-in > WASM > extension.
- Output trust: all WASM tool results are marked `trust: :untrusted`.

## Enablement

WASM tools are opt-in and disabled by default.

```toml
[agent.tools.wasm]
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

Discovery roots:

1. `<cwd>/.lemon/wasm-tools`
2. `~/.lemon/agent/wasm-tools`
3. `agent.tools.wasm.tool_paths`

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

## Security Model (v1)

- `secret-exists` checks env vars only.
- `workspace-read` is path-normalized and restricted by allowed prefixes.
- `http-request` is allowlist/rate-limited by capabilities.
- `tool-invoke` is alias-based and depth/rate-limited.
- Direct workspace write imports are intentionally not exposed; write/edit/patch behavior must go through host tool aliases.
