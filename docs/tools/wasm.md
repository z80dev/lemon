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

Discovery roots (operator-controlled only; a project's `.lemon/wasm-tools` is
never searched):

1. `<agent dir>/wasm-tools` (`~/.lemon/agent/wasm-tools` by default; `LEMON_AGENT_DIR` changes the agent dir)
2. `runtime.tools.wasm.tool_paths` (relative entries, like `runtime_path` and
   `cache_dir`, resolve against the global config directory `~/.lemon`)

`[runtime.extensions] enabled = false` also disables WASM tools: the sidecar is
not started at session start or reload.

Each module is discovered as:

- `<name>.wasm`
- Optional `<name>.capabilities.json`

## Host Calls and Reserved Targets

The runtime sends host calls to Lemon as `host_call` events with a `channel`:

- `tool`: a guest `tool-invoke` call. The target comes from the tool's
  author-declared `tool_invoke.aliases`. Lemon runs it only as a regular host
  tool from the session's policy-authorized catalog.
- `internal`: a secret lookup made by the runtime itself (credential injection,
  <code v-pre>{{SECRET:name}}</code> placeholders, `secret-exists`). The event names the calling
  tool in `caller`.

Reserved targets are served only on the `internal` channel:

- `__lemon.secret.exists`
- `__lemon.secret.resolve`

Any `__lemon*` target (case-insensitive, surrounding whitespace ignored) cannot
be aliased. The runtime fails such a `tool-invoke` with
`reserved host target cannot be aliased`, and Lemon refuses a reserved target on
the `tool` channel with `reserved_target`. For `internal` calls, Lemon looks up
`caller` among the discovered tools (`unknown_caller` otherwise) and checks the
secret name against that tool's `secrets.allowed_names` (exact name or trailing
`*` prefix) before touching the secret store, returning `secret_not_allowed`
for any other name. A tool without a `secrets` capability can resolve nothing.

Secret names and `secrets.allowed_names` patterns are never trimmed. An empty
value, or one with leading or trailing whitespace, is non-canonical:

- The runtime fails discovery of a tool whose capabilities declare such a pattern,
  and Lemon drops such a tool from discovery with a
  `non-canonical secrets.allowed_names` error.
- At request time, the runtime refuses a non-canonical name or pattern, and Lemon
  answers `invalid_secret_name` (padded name) or `secret_not_allowed` (padded
  pattern).

### Environment isolation

The runtime process starts with every environment variable unset except
`PATH`, `HOME`, `LANG`, `LC_*` and `TMPDIR`, so provider keys and bot tokens in
Lemon's environment never reach it. Commands run through the `exec` capability
start from an empty environment. They get only `PATH`, `LANG`/`LC_*`, `TMPDIR`
and a sandbox `HOME` (a per-runtime temp directory), plus the env the tool
passes, whose <code v-pre>{{SECRET:name}}</code> placeholders must pass `secrets.allowed_names`.

## Runtime Build

The runtime and bundled tools require Rust 1.93 or newer. The runtime uses the
Wasmtime 36 LTS series (36.0.21 or newer), with WASI Preview 2 component bindings.

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

## Bundled Tool Builds

The bundled tools are WASI Preview 2 components. Install the target, then build
each crate (including the shared support library) from the repository root:

```bash
rustup target add wasm32-wasip2
for manifest in native/wasm-tools/*/Cargo.toml; do
  cargo build --release --target wasm32-wasip2 --manifest-path "$manifest"
done
```

Each tool component is written to
`native/wasm-tools/<crate>/target/wasm32-wasip2/release/<crate_name>.wasm`
(crate names use underscores). The `common` crate is a library, not a
discoverable tool. Copy the desired components and their accompanying
`*.capabilities.json` files, when present, into a discovery directory.

## Troubleshooting

1. `extensions_status` includes WASM runtime state (`enabled`, `running`, discovered tools, warnings/errors).
2. If runtime build fails, Lemon logs a warning and disables WASM tools for that session.
3. If discovery fails, non-WASM tools still load and the session continues.
4. If a WASM tool name conflicts:
   - Built-in tools always win.
   - WASM tools shadow extension tools.
   - Conflicts are logged and included in `extensions_status`.
5. If host tool callbacks fail (`tool-invoke` to non-WASM tools), the runtime returns an error to the caller tool.

