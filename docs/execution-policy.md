# Execution policy and authority context

Lemon resolves authorization before an execution reaches tools. The canonical
types live in `lemon_core` so direct sessions, routed runs, delegated children,
and named nodes use the same fail-closed semantics.

## Validated tool policies

`LemonCore.ToolPolicy.parse/1` is the only parser for supplied policy data. It
returns `{:ok, policy}` or `{:error, reason}` and accepts atom- or string-keyed
maps. It validates:

- `allow`
- `deny`
- `blocked_tools`
- `require_approval`
- `approvals`
- `no_reply`
- `profile`
- `allowed_commands` / `blocked_commands` (see [Command lists](#command-lists))
- file-size limits retained by router policy

An absent policy is `{:error, :policy_absent}`. Execution entry points handle
absence by choosing an explicit trusted default; they do not use that default
for malformed supplied data. Unknown profiles, unknown fields, conflicting
atom/string keys, invalid allow values, malformed tool lists, and unsupported
approval modes are rejected.

The removed `sandbox` key is the sole legacy exception: atom- and string-keyed
input is accepted and ignored, with a warning once per parsing process. Its
value never changes authority, and it is omitted from normalized/serialized
policies. Remove it from configuration; tool policy provides no OS sandbox.

`CodingAgent.ToolPolicy` remains a compatibility facade. Authorization helpers
fail closed when called with malformed data.

## Policy intersection

`LemonCore.ToolPolicy.restrict/2` computes authority intersection:

- allowlists intersect;
- deny and blocked lists form a union;
- approval requirements form a union and the stricter per-tool mode wins;
- a per-tool `never` survives only when neither side gates that tool at any
  approval tier: the tier depends on call arguments (for example `write` with
  `diagnostics`) and tool source, so one side cannot waive the other's gate;
  a dropped `never` inherits the stricter `approval_mode`;
- command allowlists intersect and blocklists form a union;
- numeric limits take the lower value;
- silent-mode restrictions cannot be removed;
- `workspace_read_exempt` is kept from the parent unless the request sets
  `false`; a request cannot enable it when the parent does not.

Child requests, request overrides at router admission, and execution-node wire
policies use `restrict/2`, so the result is always within the parent
(`subset?/2`). Trusted operator layers (agent, channel, session, runtime and
profile policy) use `LemonCore.ToolPolicy.layer/2`, which is identical except
that an unset `workspace_read_exempt` is neutral, so any operator layer may
enable it and an explicit `false` wins. A later policy layer can narrow
authority but cannot undo an earlier restriction.

### Stored-policy upgrade semantics

Session policy envelopes retain their nested `tool_policy` payload until the
canonical parser sees it. Conflicting atom/string keys are therefore rejected
instead of being normalized away.

The canonical meaning of `allowed_commands: []` is **allow no commands**.
Legacy router code treated both a missing value and an empty list as
unrestricted; after this upgrade, operators who intend unrestricted command
execution must omit the field or set it to `"all"`. The stricter interpretation
is intentional so an ambiguous stored restriction cannot fail open.

## Command lists

`allowed_commands` and `blocked_commands` are enforced by
`CodingAgent.Tools.Bash.CommandPolicy` at every shell execution point, after
internal URL expansion and before anything is spawned: the `bash` tool
(foreground, PTY, background, named service and ACP terminal runs, locally and
on execution nodes through `coding_agent.tool`). A refused command returns an
error result that names the list.

- `blocked_commands` matches broadly. Each simple command, including those
  inside subshells, command substitutions and quoted strings that contain
  whitespace (`bash -c '...'`), is split into words; an entry such as
  `"rm -rf"` matches when a word whose basename is `rm` is followed, in order,
  by `-rf`. `sudo rm -rf`, `/bin/rm -rf` and `echo rm -rf` all match.
- `allowed_commands` matches narrowly. Every simple command must begin with an
  entry's words exactly, with no path, variable-assignment or wrapper prefix
  (`sudo`, `env`); no word may contain `<` or `>` (redirection, here-docs and
  substitutions are refused); and the `env` parameter is refused. An empty
  list allows nothing.
- `process_input` checks what it writes against `blocked_commands`.
- `eval` and `debug` run code no command list can inspect, so they refuse every
  call while either list is set. For the same reason the `lsp` tool refuses
  every action except `status` before any language server starts or syncs
  (servers run build tools and project code), `lsp_diagnostics` refuses to run
  project checkers and compilers, and the formatter refuses to launch. On
  `write`, `edit` and `patch`, an explicit `diagnostics: true` or
  `format: true` is refused and a configured default is skipped.
- `omp` cannot enforce either list, so it refuses `start`, `start_many`,
  `resume` and `send` while either list is set.

This is a best-effort string check, not a sandbox. The shell can still build a
command at run time (variable expansion, `eval`, aliases, a script on disk, an
interpreter reading stdin, flag spellings such as `rm -r -f`), so a blocklist
cannot contain a determined caller. Use `allow`/`deny` on tools, approvals and
OS isolation for that; `GitGuard` remains a separate footgun check.

## Execution context

`LemonCore.ExecutionContext` binds the following immutable values:

- run, attempt, and parent run identity;
- principal and provenance;
- validated tool policy;
- canonical workspace root and read/write mode;
- effective tool capabilities;
- numeric execution limits.

Root contexts are built with `ExecutionContext.new/1`. Delegated tasks,
router-level agent delegation, background runs, and session forks inherit or
derive context from the parent. `ExecutionContext.child/2` rejects workspace
escape and intersects policy, capabilities, and limits. Use `subset?/2` to
check the invariant.

The existing task-owned Git worktree creation path may relocate a derived
workspace only after it has successfully created and admitted that worktree.
This trusted relocation preserves principal, lineage, policy, capabilities and
limits; caller-supplied child paths cannot request the exception. Session
authority is journaled independently of the selected transcript branch, so
rewind, fork and resume cannot recover an older, broader policy.

Workspace `read_only` mode is an admission guard for the maintained direct
workspace mutation set returned by
`ExecutionContext.direct_workspace_mutation_tools/0`, including file editors,
shells, persistent evaluation kernels, debuggers and project language servers.
It is not an operating-system filesystem sandbox and does not claim to classify extension
tools or indirect state effects. Those surfaces must also be excluded by the
validated tool policy and their own capability checks.

## Named execution nodes

The named-node `coding_agent.run` protocol version 2 carries a version-1
`executionContext` object alongside the existing version-1 native privacy
descriptor. The source removes source-machine workspace paths
from this object. The destination:

1. validates the outer protocol version and payload bounds;
2. decodes and validates the execution context;
3. checks that the context run ID matches the request run ID;
4. intersects the context with its destination-local capability ceiling;
5. resolves the destination-local cwd;
6. binds the context workspace to that canonical path;
7. invokes the executor, which validates the context again.

The wire request retains a canonical JSON `toolPolicy` projection for the existing
native privacy/admission protocol; it cannot widen the accompanying execution
context. Malformed or missing contexts are rejected before a destination session starts.
Named workers default to an `all` ceiling and can narrow it with
`--capabilities read,write,...` or `LEMON_NODE_CAPABILITIES`; a transported
context can never add a capability omitted by that destination.
