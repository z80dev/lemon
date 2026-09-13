# Execution policy and authority context

Lemon resolves authorization before an execution reaches tools. The canonical
types live in `lemon_core` so direct sessions, routed runs, delegated children,
gateway execution, and named nodes use the same fail-closed semantics.

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
- command restrictions and file-size/sandbox limits retained by router policy

An absent policy is `{:error, :policy_absent}`. Execution entry points handle
absence by choosing an explicit trusted default; they do not use that default
for malformed supplied data. Unknown profiles, unknown fields, conflicting
atom/string keys, invalid allow values, malformed tool lists, and unsupported
approval modes are rejected.

`CodingAgent.ToolPolicy` remains a compatibility facade. Authorization helpers
fail closed when called with malformed data.

## Policy intersection

`LemonCore.ToolPolicy.restrict/2` computes authority intersection:

- allowlists intersect;
- deny and blocked lists form a union;
- approval requirements form a union and the stricter per-tool mode wins;
- command allowlists intersect and blocklists form a union;
- numeric limits take the lower value;
- sandbox and silent-mode restrictions cannot be removed.

Router policy layers and child requests use this operation. A later policy
layer can narrow authority but cannot undo an earlier restriction.

### Stored-policy upgrade semantics

Session policy envelopes retain their nested `tool_policy` payload until the
canonical parser sees it. Conflicting atom/string keys are therefore rejected
instead of being normalized away.

The canonical meaning of `allowed_commands: []` is **allow no commands**.
Legacy router code treated both a missing value and an empty list as
unrestricted; after this upgrade, operators who intend unrestricted command
execution must omit the field or set it to `"all"`. The stricter interpretation
is intentional so an ambiguous stored restriction cannot fail open.

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

Workspace `read_only` mode is an admission guard for the maintained direct
workspace mutation set returned by
`ExecutionContext.direct_workspace_mutation_tools/0` (`write`, `edit`,
`hashline_edit`, `patch`, `bash`, and `execute_code`). It is not an
operating-system filesystem sandbox and does not claim to classify extension
tools or indirect state effects. Those surfaces must also be excluded by the
validated tool policy and their own capability checks.

## Named execution nodes

The named-node `coding_agent.run` protocol carries a versioned
`executionContext` object. The source removes source-machine workspace paths
from this object. The destination:

1. validates the outer protocol version and payload bounds;
2. decodes and validates the execution context;
3. checks that the context run ID matches the request run ID;
4. intersects the context with its destination-local capability ceiling;
5. resolves the destination-local cwd;
6. binds the context workspace to that canonical path;
7. invokes the executor, which validates the context again.

The wire request does not carry a second independently normalized tool policy.
Malformed or missing contexts are rejected before a destination session starts.
Named workers default to an `all` ceiling and can narrow it with
`--capabilities read,write,...` or `LEMON_NODE_CAPABILITIES`; a transported
context can never add a capability omitted by that destination.
