# Review: Phase 1 (Debug RPC UI Adapter) — Findings, Fixes, Next Steps

Date: 2026-01-30

This review covers the current Phase 1 implementation in Lemon:
- `apps/coding_agent_ui/lib/coding_agent/ui/debug_rpc.ex`
- `scripts/debug_agent_rpc.exs`
- `apps/coding_agent_ui/test/coding_agent/ui/debug_rpc_test.exs`

The goal is to validate correctness against the proposed protocol and ensure the data shapes match what a `@mariozechner/pi-tui` frontend will expect.

---

## Findings (with impact)

### 1) **Notify payload key mismatch (`notify_type` vs `type`)**
**Where**
- Docstring and plan show `notify_type` in the JSON payload.
- Implementation sends `params.type`.

**Why it matters**
- The frontend will look for the key documented in the plan. If it uses `notify_type`, it will miss the value entirely and may render all notifications as a default type.

**Suggested fix**
- Use `notify_type` in the payload (clearer, less ambiguous) and update tests/docs to match.
- This is the most self-descriptive name and avoids collision with top-level `type` in the envelope.

---

### 2) **`parse_response/1` can mask errors**
**Where**
- `parse_response/1` returns `{:ok, result}` even when an error is present, if both fields exist in the JSON.

**Why it matters**
- Buggy or partial clients could accidentally send both `result` and `error`. Current logic will treat that as success, hiding real failures.

**Suggested fix**
- Give `error` precedence. If `error` is non-nil, return `{:error, error}` regardless of `result`.

---

### 3) **`set_widget/3` sends `opts` as raw keyword list**
**Where**
- `set_widget/3` uses `opts` directly in JSON (`params.opts`).

**Why it matters**
- Keyword lists serialize to arrays of tuples. For JS/TS clients this is awkward and inconsistent with the rest of the protocol, which uses maps.

**Suggested fix**
- Normalize `opts` to a map with `clean_opts/1` before encoding.
- This matches how dialog requests normalize their options.

---

### 4) **UI should be enabled by default**
**Where**
- `debug_agent_rpc.exs` currently requires `--ui` to enable the UI adapter.

**Why it matters**
- The new TUI will assume UI is always enabled. Requiring a flag introduces foot‑guns and inconsistent behavior.

**Suggested fix**
- Enable UI by default; optionally add `--no-ui` for headless use.
- Keep the `ready` payload field `ui: true/false` for clarity.

---

## Suggested fixes (concrete)

### A) Normalize `ui_notify` payload key
**Change**
```elixir
# debug_rpc.ex
GenServer.cast(server, {:signal, "ui_notify", %{message: message, notify_type: type}})
```

**Tests to update**
- `debug_rpc_test.exs` should assert `params.notify_type == "info"`.

**Plan/doc updates**
- Ensure `LEMON_TUI_PLAN.md` and module docstrings show `notify_type`.

---

### B) Make `parse_response/1` error‑first
**Change**
```elixir
defp parse_response(%{"error" => error}) when not is_nil(error), do: {:error, error}

defp parse_response(%{"result" => result, "error" => nil}), do: {:ok, result}

defp parse_response(%{"result" => result}) when not is_nil(result), do: {:ok, result}

defp parse_response(%{"result" => nil, "error" => nil}), do: {:ok, nil}
```

---

### C) Normalize widget `opts`
**Change**
```elixir
# debug_rpc.ex
cleaned = clean_opts(opts)
GenServer.cast(server, {:signal, "ui_widget", %{key: key, content: content, opts: cleaned}})
```

---

### D) Enable UI by default in debug RPC
**Change**
- Replace `--ui` flag with `--no-ui` or keep both but default to enabled.
- Example:
```elixir
ui_enabled = opts[:ui] != false and opts[:no_ui] != true
```

**Ready payload**
- Keep `ui: true/false` for the client to display connection state.

---

## Suggested next steps

1) **Apply fixes A–D** in `apps/coding_agent_ui/lib/coding_agent/ui/debug_rpc.ex` and `scripts/debug_agent_rpc.exs`.
2) **Update tests** to reflect `notify_type` and normalized widget `opts`.
3) **Update `LEMON_TUI_PLAN.md`** (Frontend Data Contract section) to match the final wire format:
   - `ui_notify.params.notify_type`
   - `ui_widget.params.opts` is a map
4) **Add a minimal integration test** for `debug_agent_rpc.exs` to verify:
   - UI enabled by default
   - `ui_request` emitted for select
   - `ui_response` routes correctly

---

## Additional observations (optional)

- The `ui_widget` signal name is consistent in code but not listed in the DebugRPC module doc. Consider adding it explicitly in the doc block to avoid confusion.
- The tests for notify/status/etc. currently call `GenServer.cast` directly; consider at least one public API test to ensure the exported functions route correctly through `get_server/1`.

