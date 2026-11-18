# omp port ledger

This inventory distinguishes borrowed designs from compatibility adapters and actual
package dependencies. It is not a claim of behavioral equivalence or measured gain.
Upstream repositories: [omp](https://github.com/can1357/oh-my-pi) and its
[pi-mono ancestry](https://github.com/badlogic/pi-mono).

## Provenance and decisions

The audit baseline is Lemon `4d94b3c8e`; the epic compared omp v18.20.2,
commit `7c49c11aa5bb`. That comparison revision is **not** evidence that old
native ports were copied from that revision. Native rows therefore say
“unknown”: comments and local history do not identify an upstream source SHA.
`git log -S 'ports the TypeScript Agent'` traces the Agent attribution back to
Lemon `7dc28c315`; planning's omp attribution appears in `159f26d5d` and DAP's
in `a398cb412`. These are Lemon commits, not upstream pins. Record an actual
upstream SHA when a future port is made; do not infer one from a release date.

**Native port** includes independently implemented compatibility readers. All
credentials, instruction loading, approvals, execution policy, process ownership,
RPC validation and untrusted-result handling remain native trust boundaries.
**Delegate via lemon_omp** means external model/tool execution only: Lemon's
native `lemon_omp` adapter still owns admission, approvals, subprocess lifecycle,
protocol validation and projections. It is not an alternative native executor.
**Depend on package** applies to presentation primitives, not daemon authority.
Client controllers still send authenticated daemon requests; rendered data never
acquires policy authority. No trust-boundary implementation is delegated to a
presentation package.

Acceptance references below are existing test paths (directories mean that app's
suite), not claims that they have been run. Native edit acceptance additionally
uses [#545](https://github.com/z80dev/lemon/issues/545)'s edit benchmark; paid
model comparisons are opt-in and cannot be replaced by unit tests.

Subsystem acceptance anchors: plan gating uses
`apps/coding_agent/test/coding_agent/session/planning_test.exs`; DAP defaults
use `apps/coding_agent/test/coding_agent/debug/adapters_test.exs`; persona roots
use `apps/coding_agent/test/coding_agent/subagents_test.exs`; approval tiers use
`apps/coding_agent/test/coding_agent/tool_approval_tiers_test.exs`; model roles use
`apps/lemon_agent/test/lemon_agent/model_runtime/model_roles_test.exs`; edit
semantics use `apps/coding_agent/test/coding_agent/tools/anchored_edit_test.exs`
and `apps/coding_agent/test/coding_agent/tools/edit_friction_test.exs` before
the #545 model benchmark. These are the focused contracts behind the broader
app-suite references below.

## Native subsystems and compatibility boundaries

| Lemon module source | Upstream origin / version | Disposition | Acceptance test |
| --- | --- | --- | --- |
| `apps/lemon_core/lib/lemon_core/tool_policy.ex` | omp approval-mode vocabulary; source revision unknown | native port | `apps/lemon_core/test/lemon_core/tool_policy_test.exs` |
| `apps/coding_agent/lib/coding_agent/commands.ex` | omp / pi-mono; source revision unknown | native port | `apps/coding_agent/test/coding_agent/commands_test.exs` |
| `apps/coding_agent/lib/coding_agent/compaction.ex` | omp compaction pruning policy and #2275 recovery band; source revision unknown | native port | `apps/coding_agent/test/coding_agent/compaction_pruning_test.exs`, `apps/coding_agent/test/coding_agent/compaction_pruning_wire_test.exs`, `apps/coding_agent/test/coding_agent/compaction_test.exs` |
| `apps/coding_agent/lib/coding_agent/debug/adapters.ex` | omp / pi-mono; source revision unknown | native port | `apps/coding_agent/test/coding_agent/debug/adapters_test.exs` |
| `apps/coding_agent/lib/coding_agent/resource_loader.ex` | omp / pi-mono; source revision unknown | native port | `apps/coding_agent/test/coding_agent/resource_loader_test.exs` |
| `apps/coding_agent/lib/coding_agent/security/secret_obfuscator/loader.ex` | omp / pi-mono; source revision unknown | native port | `apps/coding_agent/test` |
| `apps/coding_agent/lib/coding_agent/session/model_resolver.ex` | omp / pi-mono; source revision unknown | native port | `apps/coding_agent/test/coding_agent/session/model_resolver_test.exs` |
| `apps/coding_agent/lib/coding_agent/session/planning.ex` | omp / pi-mono; source revision unknown | native port | `apps/coding_agent/test/coding_agent/session/planning_test.exs` |
| `apps/coding_agent/lib/coding_agent/subagents.ex` | omp / pi-mono; source revision unknown | native port | `apps/coding_agent/test/coding_agent/subagents_test.exs` |
| `apps/coding_agent/lib/coding_agent/tool_policy.ex` | omp / pi-mono; source revision unknown | native port | `apps/coding_agent/test/coding_agent/tool_policy_test.exs` |
| `apps/coding_agent/lib/coding_agent/tools/anchored_edit.ex` | omp / pi-mono; source revision unknown | native port | `apps/coding_agent/test/coding_agent/tools/anchored_edit_test.exs` |
| `apps/coding_agent/lib/coding_agent/tools/edit.ex` | omp / pi-mono; source revision unknown | native port | `apps/coding_agent/test/coding_agent/tools/edit_test.exs` |
| `apps/coding_agent/lib/coding_agent/tools/task/params.ex` | omp / pi-mono; source revision unknown | native port | `apps/coding_agent/test` |
| `apps/lemon_agent/lib/lemon_agent/agent.ex` | omp / pi-mono; source revision unknown | native port | `apps/lemon_agent/test/lemon_agent/agent_test.exs` |
| `apps/lemon_agent/lib/lemon_agent/env.ex` | omp / pi-mono; source revision unknown | native port | `apps/lemon_agent/test` |
| `apps/lemon_agent/lib/lemon_agent/model_runtime/credentials.ex` | omp / pi-mono; source revision unknown | native port | `apps/lemon_agent/test/lemon_agent/model_runtime/credentials_test.exs` |
| `apps/lemon_agent/lib/lemon_agent/model_runtime/model_roles.ex` | omp / pi-mono; source revision unknown | native port | `apps/lemon_agent/test/lemon_agent/model_runtime/model_roles_test.exs` |
| `apps/lemon_agent/lib/lemon_agent/model_runtime/omp_broker.ex` | omp / pi-mono; source revision unknown | native port | `apps/lemon_agent/test/lemon_agent/model_runtime/omp_broker_test.exs` |
| `apps/lemon_ai/lib/lemon_ai/auth/omp_auth_broker.ex` | omp / pi-mono; source revision unknown | native port | `apps/lemon_ai/test/lemon_ai/auth/omp_auth_broker_test.exs` |
| `apps/lemon_ai/lib/lemon_ai/auth/omp_config.ex` | omp / pi-mono; source revision unknown | native port | `apps/lemon_ai/test` |
| `apps/lemon_ai/lib/lemon_ai/auth/omp_token.ex` | omp / pi-mono; source revision unknown | native port | `apps/lemon_ai/test/lemon_ai/auth/omp_token_test.exs` |
| `apps/lemon_ai/lib/lemon_ai/model_cache.ex` | omp / pi-mono; source revision unknown | native port | `apps/lemon_ai/test/lemon_ai/model_cache_test.exs` |
| `apps/lemon_ai/lib/lemon_ai/models/omp_gateway.ex` | omp / pi-mono; source revision unknown | native port | `apps/lemon_ai/test/lemon_ai/models/omp_gateway_test.exs` |
| `apps/lemon_ai/lib/lemon_ai/models/open_ai.ex` | omp / pi-mono; source revision unknown | native port | `apps/lemon_ai/test` |
| `apps/lemon_ai/lib/lemon_ai/models/presets.ex` | omp / pi-mono; source revision unknown | native port | `apps/lemon_ai/test/lemon_ai/models/presets_test.exs` |
| `apps/lemon_ai/lib/lemon_ai/providers/kimi_code_usage.ex` | omp / pi-mono; source revision unknown | native port | `apps/lemon_ai/test` |
| `apps/lemon_cli/lib/lemon_cli/command_registry.ex` | omp / pi-mono; source revision unknown | native port | `apps/lemon_cli/test/lemon_cli/command_registry_test.exs` |
| `apps/lemon_cli/lib/lemon_cli/doctor/providers.ex` | omp / pi-mono; source revision unknown | native port | `apps/lemon_cli/test` |
| `apps/lemon_cli/lib/lemon_cli/omp_command.ex` | omp / pi-mono; source revision unknown | native port | `apps/lemon_cli/test/lemon_cli/omp_command_test.exs` |
| `apps/lemon_cli/lib/lemon_cli/onboarding/runner.ex` | omp / pi-mono; source revision unknown | native port | `apps/lemon_cli/test/lemon_cli/onboarding/runner_test.exs` |
| `apps/lemon_cli/lib/lemon_cli/provider_live_check.ex` | omp / pi-mono; source revision unknown | native port | `apps/lemon_cli/test/lemon_cli/provider_live_check_test.exs` |
| `apps/lemon_cli/lib/lemon_cli/providers_command.ex` | omp / pi-mono; source revision unknown | native port | `apps/lemon_cli/test/lemon_cli/providers_command_test.exs` |
| `apps/lemon_cli/lib/lemon_cli/setup/omp.ex` | omp auth-broker client contract; source revision unknown | native port | `apps/lemon_cli/test/lemon_cli/setup/omp_setup_test.exs` |
| `apps/lemon_cli/lib/lemon_cli/setup/provider_auth.ex` | omp / pi-mono; source revision unknown | native port | `apps/lemon_cli/test/lemon_cli/setup/provider_auth_test.exs` |
| `apps/lemon_control_plane/lib/lemon_control_plane/methods/omp.ex` | omp / pi-mono; source revision unknown | native port | `apps/lemon_control_plane/test` |
| `apps/lemon_core/lib/lemon_core/config/providers.ex` | omp / pi-mono; source revision unknown | native port | `apps/lemon_core/test/lemon_core/config/providers_test.exs` |
| `apps/lemon_core/lib/lemon_core/doctor/checks/providers.ex` | omp / pi-mono; source revision unknown | native port | `apps/lemon_core/test` |
| `apps/lemon_core/lib/lemon_core/service/readiness.ex` | omp auth-broker health probe; source revision unknown | native port | `apps/lemon_core/test/lemon_core/service_test.exs` |
| `apps/lemon_core/lib/lemon_core/service/role.ex` | omp auth-broker serve command and config-root selectors; source revision unknown | native port | `apps/lemon_core/test/lemon_core/service_test.exs` |
| `apps/lemon_omp/lib/lemon_omp.ex` | omp / pi-mono; source revision unknown | delegate via lemon_omp (native adapter) | `apps/lemon_omp/test` |
| `apps/lemon_omp/lib/lemon_omp/config.ex` | omp / pi-mono; source revision unknown | delegate via lemon_omp (native adapter) | `apps/lemon_omp/test/lemon_omp/config_test.exs` |
| `apps/lemon_omp/lib/lemon_omp/env.ex` | omp / pi-mono; source revision unknown | delegate via lemon_omp (native adapter) | `apps/lemon_omp/test` |
| `apps/lemon_omp/lib/lemon_omp/manager.ex` | omp / pi-mono; source revision unknown | delegate via lemon_omp (native adapter) | `apps/lemon_omp/test` |
| `apps/lemon_omp/lib/lemon_omp/projection.ex` | omp / pi-mono; source revision unknown | delegate via lemon_omp (native adapter) | `apps/lemon_omp/test/lemon_omp/projection_test.exs` |
| `apps/lemon_omp/lib/lemon_omp/rpc.ex` | omp / pi-mono; source revision unknown | delegate via lemon_omp (native adapter) | `apps/lemon_omp/test/lemon_omp/rpc_test.exs` |
| `apps/lemon_omp/lib/lemon_omp/session.ex` | omp / pi-mono; source revision unknown | delegate via lemon_omp (native adapter) | `apps/lemon_omp/test` |
| `apps/lemon_omp/lib/lemon_omp/session_files.ex` | omp / pi-mono; source revision unknown | delegate via lemon_omp (native adapter) | `apps/lemon_omp/test/lemon_omp/session_files_test.exs` |
| `apps/lemon_omp/lib/lemon_omp/tools/omp.ex` | omp / pi-mono; source revision unknown | delegate via lemon_omp (native adapter) | `apps/lemon_omp/test/lemon_omp/tools/omp_test.exs` |
| `apps/lemon_skills/lib/lemon_skills/config.ex` | omp / pi-mono; source revision unknown | native port | `apps/lemon_skills/test/lemon_skills/config_test.exs` |
| `apps/lemon_skills/lib/lemon_skills/mcp_discovery.ex` | omp / pi-mono; source revision unknown | native port | `apps/lemon_skills/test/lemon_skills/mcp_discovery_test.exs` |
| `apps/lemon_web/lib/lemon_web/live/omp_components.ex` | omp / pi-mono; source revision unknown | native port | `apps/lemon_web/test` |
| `apps/lemon_web/lib/lemon_web/live/omp_live.ex` | omp / pi-mono; source revision unknown | native port | `apps/lemon_web/test` |
| `apps/lemon_web/lib/lemon_web/nav.ex` | omp / pi-mono; source revision unknown | native port | `apps/lemon_web/test` |

## Terminal presentation and delegate UI

These modules import omp packages or explicitly describe omp-derived interaction
patterns. Package imports are included conservatively, even when they are not
claims of a source port. All use omp v18.20.2 (npm-published package version).
The `omp` command/protocol/panel/formatter files are native client adapters to
`lemon_omp`, not a copy of the external execution engine.

| Lemon source | Upstream origin / version | Disposition | Acceptance test |
| --- | --- | --- | --- |
| `clients/lemon-browser-node/src/relay/bridge.ts` | omp packages 18.20.2 | depend on package (presentation); native daemon boundary | `clients/tui/test` |
| `clients/tui/src/app.ts` | omp packages 18.20.2 | depend on package (presentation); native daemon boundary | `clients/tui/test` |
| `clients/tui/src/commands/copy.ts` | omp packages 18.20.2 | depend on package (presentation); native daemon boundary | `clients/tui/test` |
| `clients/tui/src/commands/jobs.ts` | omp packages 18.20.2 | depend on package (presentation); native daemon boundary | `clients/tui/test` |
| `clients/tui/src/commands/omp.ts` | omp packages 18.20.2 | depend on package (presentation); native daemon boundary | `clients/tui/test` |
| `clients/tui/src/commands/palette-source.ts` | omp packages 18.20.2 | depend on package (presentation); native daemon boundary | `clients/tui/test` |
| `clients/tui/src/commands/registry.ts` | omp packages 18.20.2 | depend on package (presentation); native daemon boundary | `clients/tui/test` |
| `clients/tui/src/commands/session-tree.ts` | omp packages 18.20.2 | depend on package (presentation); native daemon boundary | `clients/tui/test` |
| `clients/tui/src/composer/attachment-list.ts` | omp packages 18.20.2 | depend on package (presentation); native daemon boundary | `clients/tui/test` |
| `clients/tui/src/composer/autocomplete.ts` | omp packages 18.20.2 | depend on package (presentation); native daemon boundary | `clients/tui/test` |
| `clients/tui/src/composer/clipboard.ts` | omp packages 18.20.2 | depend on package (presentation); native daemon boundary | `clients/tui/test` |
| `clients/tui/src/composer/model-mentions.ts` | omp packages 18.20.2 | depend on package (presentation); native daemon boundary | `clients/tui/test` |
| `clients/tui/src/config.ts` | omp packages 18.20.2 | depend on package (presentation); native daemon boundary | `clients/tui/test` |
| `clients/tui/src/dev/fixtures/tool-fixtures.ts` | omp packages 18.20.2 | depend on package (presentation); native daemon boundary | `clients/tui/test` |
| `clients/tui/src/dev/gallery.ts` | omp packages 18.20.2 | depend on package (presentation); native daemon boundary | `clients/tui/test` |
| `clients/tui/src/formatters/omp.ts` | omp packages 18.20.2 | depend on package (presentation); native daemon boundary | `clients/tui/test` |
| `clients/tui/src/protocol/omp.ts` | omp packages 18.20.2 | depend on package (presentation); native daemon boundary | `clients/tui/test` |
| `clients/tui/src/terminal/capabilities.ts` | omp packages 18.20.2 | depend on package (presentation); native daemon boundary | `clients/tui/test` |
| `clients/tui/src/terminal/integration.ts` | omp packages 18.20.2 | depend on package (presentation); native daemon boundary | `clients/tui/test` |
| `clients/tui/src/terminal/links.ts` | omp packages 18.20.2 | depend on package (presentation); native daemon boundary | `clients/tui/test` |
| `clients/tui/src/terminal/native-tool-view.ts` | omp packages 18.20.2 | depend on package (presentation); native daemon boundary | `clients/tui/test` |
| `clients/tui/src/terminal/native-tool.ts` | omp packages 18.20.2 | depend on package (presentation); native daemon boundary | `clients/tui/test` |
| `clients/tui/src/terminal/signals.ts` | omp packages 18.20.2 | depend on package (presentation); native daemon boundary | `clients/tui/test` |
| `clients/tui/src/ui/components/accordion.ts` | omp packages 18.20.2 | depend on package (presentation); native daemon boundary | `clients/tui/test` |
| `clients/tui/src/ui/components/agent-hub.ts` | omp packages 18.20.2 | depend on package (presentation); native daemon boundary | `clients/tui/test` |
| `clients/tui/src/ui/components/approval-panel.ts` | omp packages 18.20.2 | depend on package (presentation); native daemon boundary | `clients/tui/test` |
| `clients/tui/src/ui/components/assistant-message.ts` | omp packages 18.20.2 | depend on package (presentation); native daemon boundary | `clients/tui/test` |
| `clients/tui/src/ui/components/banner.ts` | omp packages 18.20.2 | depend on package (presentation); native daemon boundary | `clients/tui/test` |
| `clients/tui/src/ui/components/context-panel.ts` | omp packages 18.20.2 | depend on package (presentation); native daemon boundary | `clients/tui/test` |
| `clients/tui/src/ui/components/custom-editor.ts` | omp packages 18.20.2 | depend on package (presentation); native daemon boundary | `clients/tui/test` |
| `clients/tui/src/ui/components/diff.ts` | omp packages 18.20.2 | depend on package (presentation); native daemon boundary | `clients/tui/test` |
| `clients/tui/src/ui/components/html-form-answer.ts` | omp packages 18.20.2 | depend on package (presentation); native daemon boundary | `clients/tui/test` |
| `clients/tui/src/ui/components/model-picker.ts` | omp packages 18.20.2 | depend on package (presentation); native daemon boundary | `clients/tui/test` |
| `clients/tui/src/ui/components/native-chrome.ts` | omp packages 18.20.2 | depend on package (presentation); native daemon boundary | `clients/tui/test` |
| `clients/tui/src/ui/components/notice-message.ts` | omp packages 18.20.2 | depend on package (presentation); native daemon boundary | `clients/tui/test` |
| `clients/tui/src/ui/components/omp-panel.ts` | omp packages 18.20.2 | depend on package (presentation); native daemon boundary | `clients/tui/test` |
| `clients/tui/src/ui/components/pickers.ts` | omp packages 18.20.2 | depend on package (presentation); native daemon boundary | `clients/tui/test` |
| `clients/tui/src/ui/components/queue-panel.ts` | omp packages 18.20.2 | depend on package (presentation); native daemon boundary | `clients/tui/test` |
| `clients/tui/src/ui/components/readiness-card.ts` | omp packages 18.20.2 | depend on package (presentation); native daemon boundary | `clients/tui/test` |
| `clients/tui/src/ui/components/reasoning-block.ts` | omp packages 18.20.2 | depend on package (presentation); native daemon boundary | `clients/tui/test` |
| `clients/tui/src/ui/components/session-switcher.ts` | omp packages 18.20.2 | depend on package (presentation); native daemon boundary | `clients/tui/test` |
| `clients/tui/src/ui/components/status-bar.ts` | omp packages 18.20.2 | depend on package (presentation); native daemon boundary | `clients/tui/test` |
| `clients/tui/src/ui/components/tool-card.ts` | omp packages 18.20.2 | depend on package (presentation); native daemon boundary | `clients/tui/test` |
| `clients/tui/src/ui/components/tool-output.ts` | omp packages 18.20.2 | depend on package (presentation); native daemon boundary | `clients/tui/test` |
| `clients/tui/src/ui/components/tool-shelf.ts` | omp packages 18.20.2 | depend on package (presentation); native daemon boundary | `clients/tui/test` |
| `clients/tui/src/ui/components/transcript-container.ts` | omp packages 18.20.2 | depend on package (presentation); native daemon boundary | `clients/tui/test` |
| `clients/tui/src/ui/components/user-message.ts` | omp packages 18.20.2 | depend on package (presentation); native daemon boundary | `clients/tui/test` |
| `clients/tui/src/ui/components/user-prompt-panel.ts` | omp packages 18.20.2 | depend on package (presentation); native daemon boundary | `clients/tui/test` |
| `clients/tui/src/ui/components/width-safe.ts` | omp packages 18.20.2 | depend on package (presentation); native daemon boundary | `clients/tui/test` |
| `clients/tui/src/ui/components/working-indicator.ts` | omp packages 18.20.2 | depend on package (presentation); native daemon boundary | `clients/tui/test` |
| `clients/tui/src/ui/controllers/approval-controller.ts` | omp packages 18.20.2 | depend on package (presentation); native daemon boundary | `clients/tui/test` |
| `clients/tui/src/ui/controllers/command-palette.ts` | omp packages 18.20.2 | depend on package (presentation); native daemon boundary | `clients/tui/test` |
| `clients/tui/src/ui/controllers/event-controller.ts` | omp packages 18.20.2 | depend on package (presentation); native daemon boundary | `clients/tui/test` |
| `clients/tui/src/ui/controllers/input-controller.ts` | omp packages 18.20.2 | depend on package (presentation); native daemon boundary | `clients/tui/test` |
| `clients/tui/src/ui/controllers/selector-controller.ts` | omp packages 18.20.2 | depend on package (presentation); native daemon boundary | `clients/tui/test` |
| `clients/tui/src/ui/controllers/session-controller.ts` | omp packages 18.20.2 | depend on package (presentation); native daemon boundary | `clients/tui/test` |
| `clients/tui/src/ui/controllers/streaming-reveal.ts` | omp packages 18.20.2 | depend on package (presentation); native daemon boundary | `clients/tui/test` |
| `clients/tui/src/ui/controllers/tool-inspector.ts` | omp packages 18.20.2 | depend on package (presentation); native daemon boundary | `clients/tui/test` |
| `clients/tui/src/ui/controllers/user-prompt-controller.ts` | omp packages 18.20.2 | depend on package (presentation); native daemon boundary | `clients/tui/test` |
| `clients/tui/src/ui/history-search.ts` | omp packages 18.20.2 | depend on package (presentation); native daemon boundary | `clients/tui/test` |
| `clients/tui/src/ui/link-browser.ts` | omp packages 18.20.2 | depend on package (presentation); native daemon boundary | `clients/tui/test` |
| `clients/tui/src/ui/link-hints.ts` | omp packages 18.20.2 | depend on package (presentation); native daemon boundary | `clients/tui/test` |
| `clients/tui/src/ui/omp-nodes.ts` | omp packages 18.20.2 | depend on package (presentation); native daemon boundary | `clients/tui/test` |
| `clients/tui/src/ui/plan-review.ts` | omp packages 18.20.2 | depend on package (presentation); native daemon boundary | `clients/tui/test` |
| `clients/tui/src/ui/replay-overlays.ts` | omp packages 18.20.2 | depend on package (presentation); native daemon boundary | `clients/tui/test` |
| `clients/tui/src/ui/row-frame-provider.ts` | omp packages 18.20.2 | depend on package (presentation); native daemon boundary | `clients/tui/test` |
| `clients/tui/src/ui/shell-confirm.ts` | omp packages 18.20.2 | depend on package (presentation); native daemon boundary | `clients/tui/test` |
| `clients/tui/src/ui/theme/appearance.ts` | omp packages 18.20.2 | depend on package (presentation); native daemon boundary | `clients/tui/test` |
| `clients/tui/src/ui/theme/theme.ts` | omp packages 18.20.2 | depend on package (presentation); native daemon boundary | `clients/tui/test` |
| `clients/tui/src/ui/theme/tui-adapters.ts` | omp packages 18.20.2 | depend on package (presentation); native daemon boundary | `clients/tui/test` |
| `clients/tui/src/ui/tool-view.ts` | omp packages 18.20.2 | depend on package (presentation); native daemon boundary | `clients/tui/test` |
| `clients/tui/src/ui/transcript-entries.ts` | omp packages 18.20.2 | depend on package (presentation); native daemon boundary | `clients/tui/test` |
| `clients/tui/src/ui/usage-dashboard.ts` | omp packages 18.20.2 | depend on package (presentation); native daemon boundary | `clients/tui/test` |

## Package refresh and retained patch

`@oh-my-pi/pi-tui`, `pi-natives` and `pi-utils` are exact-pinned together to
18.20.2, the published npm version queried for this refresh. Inspection of the
published pi-tui 18.20.2 tarball shows that neither local fix is upstream:
`render-utils.ts` still imports the pi-agent-core root, and `terminal.ts` still
restores raw input through Bun's `setRawMode` and uses `terminalEverStarted`.
The renamed 18.20.2 patch rebases those same fixes onto the new line positions:
public `/thinking` import, saved POSIX termios restored with `TCSANOW`, and
one-shot terminal restoration with cursor cleanup before stopping output.
Do not drop it until equivalent fixes ship upstream.

Focused contracts: `clients/tui/test/terminal-shutdown.test.ts`,
`clients/tui/test/ui/context-panel.test.ts` and the complete client lane.
The lockfile refresh is deliberately left to the integration owner:

```sh
cd clients/tui && bun install
# From the repository root:
scripts/test clients
```

## Coverage maintenance

`apps/lemon_core/test/lemon_core/quality/omp_port_ledger_test.exs` scans native
`apps/*/lib/**/*.ex` and client `clients/*/src/**/*.{ts,tsx,js}` for
`omp's`, `oh-my-pi`, `pi-mono`, `ports the TypeScript` and `.omp/`, requiring an
exact source-path table row with a disposition and acceptance reference. Tests,
fixtures outside source trees, documentation and lockfiles are not module-origin
claims. Update the row when adding or moving a source module; this is a quality
regression check, not an assertion of upstream conformance.

### 18.20.2 API adaptations

Upstream `TodoStatus` no longer includes `blocked`. Native tool and delegate
checklists map it to pending while retaining an explicit “blocked” label and,
where supplied, the blocker reason. Lemon's wire status is not rewritten.
`HistorySource` now requires stable numeric entry IDs and deletion. Saved search
entries expose SQLite IDs; deletion compares the selected ID, prompt and timestamp
to avoid removing a different prompt after row-ID reuse. Ring-only entries use
negative IDs, and deletion updates the current editor's recall without changing
its draft. Storage failures retain recall and use the existing error notice.

Regression contracts: `clients/tui/test/native-tool.test.ts`,
`clients/tui/test/ui/omp-nodes.test.ts`,
`clients/tui/test/composer/prompt-history-search.test.ts` and
`clients/tui/test/ui/custom-editor-history.test.ts`.
