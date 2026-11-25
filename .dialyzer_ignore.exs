[
  # ── call_with_opaque / call_without_opaque: MapSet (and MapSet-shaped
  # struct field) false positives ──────────────────────────────────────────
  #
  # Dialyzer infers a concrete, non-opaque structural type for a `%MapSet{}`
  # (or a struct holding one, e.g. TermUI.Renderer.Style, URI) when it's
  # constructed locally in the same function, then flags an "opacity
  # violation" when that value flows into MapSet.member?/2, MapSet.put/2, or
  # a callee whose @spec declares the properly-opaque %MapSet{} type. The
  # value is correct at runtime; this is a well-known Elixir+Dialyzer PLT
  # limitation with MapSet's opaque-map representation, not a real bug. Each
  # entry below was confirmed per file when it was added.
  {"lib/lemon_cli/hermes_migration.ex", :call_without_opaque},
  {"lib/lemon_core/extensions/manifest.ex", :call_without_opaque},
  {"lib/lemon_router/tool_status_renderer.ex", :call_without_opaque},
  {"lib/lemon_router/tool_status_renderer.ex", :call_with_opaque}
]
