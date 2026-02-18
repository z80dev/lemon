# json_transform (WASM sample tool)

Minimal component-model WASM tool used to validate Lemon sidecar discovery/invocation end-to-end.

## Behavior

- Accepts either `input` (JSON value) or `input_json` (string).
- Optionally applies:
  - `pick`: keep only listed top-level keys (object input only)
  - `set`: overwrite/insert top-level keys (object input only)
- Returns transformed JSON string (`pretty: true` enables pretty output).

## Build

```bash
cargo build \
  --target wasm32-wasip2 \
  --release \
  --manifest-path native/wasm-tools/json-transform/Cargo.toml
```

Install target first if needed:

```bash
rustup target add wasm32-wasip2
```

## Using with Lemon

Copy the artifact to a discovery directory as `json_transform.wasm`, for example:

```bash
cp native/wasm-tools/json-transform/target/wasm32-wasip2/release/json_transform.wasm .lemon/wasm-tools/json_transform.wasm
```
