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
  # limitation with MapSet's opaque-map representation, not a real bug. See
  # docs/plans/dialyzer-burndown.md ("opaque_term_violation") for the full
  # writeup and how this was confirmed per-file.
  {"lib/coding_agent/tools/web_guard.ex", :call_without_opaque},
  {"lib/coding_agent/tools/web_guard.ex", :call_with_opaque},
  {"lib/coding_agent/workspace.ex", :call_without_opaque},
  {"lib/lemon_cli/hermes_migration.ex", :call_without_opaque},
  {"lib/lemon_control_plane/methods/run_graph_get.ex", :call_without_opaque},
  {"lib/lemon_control_plane/methods/transports_status.ex", :call_without_opaque},
  {"lib/lemon_core/extensions/manifest.ex", :call_without_opaque},
  {"lib/lemon_core/oauth/local_callback_listener.ex", :call_without_opaque},
  {"lib/lemon_router/tool_status_renderer.ex", :call_without_opaque},
  {"lib/lemon_router/tool_status_renderer.ex", :call_with_opaque},
  {"lib/lemon_sim/examples/intel_network/updater.ex", :call_with_opaque},
  {"lib/lemon_sim/examples/skirmish/frame_renderer.ex", :call_without_opaque},
  {"lib/lemon_sim/examples/skirmish/map_generator.ex", :call_without_opaque},
  {"lib/lemon_sim/examples/skirmish/map_generator.ex", :call_with_opaque},
  {"lib/lemon_sim/examples/werewolf/frame_renderer.ex", :call_without_opaque},

  # ── unknown_function: IEx.Helpers.recompile/0 ───────────────────────────
  #
  # The Discord and Telegram `/reload` admin commands call
  # IEx.Helpers.recompile/0 directly, which only exists when the release is
  # attached to a live IEx session (`iex -S mix` / remote console). `:iex`
  # is intentionally not a runtime dependency of a compiled release, so it
  # can never be in the PLT's app set — this is permanent, not a PLT
  # configuration gap (contrast with the Nostrum `unknown_function` warnings
  # in the same files, which ARE fixable by adding :nostrum to
  # plt_add_apps and are intentionally NOT ignored here; see the burndown
  # plan).
  #
  # Matched by a regex over the warning's short description rather than the
  # exact `file:line:col:...` text: an exact-text entry is pinned to a line
  # number, and these two transport files are among the most heavily edited in
  # the umbrella. A pinned entry that drifts is not merely useless — dialyxir
  # treats an unused filter as an error and then DISCARDS the entire formatted
  # warning list (Dialyxir.Dialyzer.Runner.run), so one drifted line number
  # blanks the whole Dialyzer report and every app looks clean. The regex is
  # still scoped to these two files and to this one message, so it cannot
  # swallow a genuine `unknown_function` typo elsewhere in them.
  ~r{^lib/lemon_channels/adapters/(discord|telegram)/transport\.ex:\d+:\d+:unknown_function Function IEx\.Helpers\.recompile/0 does not exist\.$}
]
