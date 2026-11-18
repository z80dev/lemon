# Checkpoint tools

## Conversation exploration: `checkpoint` and `rewind`

Enable the pair in user or project configuration (disabled by default):

```toml
[runtime.tools.checkpoint]
enabled = true
```

`checkpoint({"goal": "Trace the request lifecycle"})` marks the current native
session's conversation. Explore with normal tools, then call
`rewind({"report": "The request enters ..."})` with non-empty findings.
The active branch returns to the checkpoint turn and retains the report as a
branch summary. The next model request sees the summary instead of the abandoned
exploration. Completed sibling tools in the rewind batch remain in context.
Original entries remain available through the session tree.
The session owner supplies the retained prefix even if compaction removed the
checkpoint receipt from the running model context. External tool metadata cannot
authorize a rewrite or replace the retained report.

Only one checkpoint may be active. A checkpoint becomes ready after its tool turn
finishes. Rewind is single-use, refuses an empty report and refuses to cross a
new user message. Active and completed checkpoints follow the selected persisted
branch on resume or tree navigation. Subagents receive the pair only when either
name is explicitly requested. Requesting either includes both, subject to policy.

These tools do **not** snapshot or restore files, undo shell commands or restore
external state. They do not ask for confirmation because they collapse only the
model's own exploration. The operator `/rewind` preview/confirmation and optional
file restoration workflow is unchanged.
Persisted `checkpoint({"goal": "..."})` calls do not block operator file
restoration of earlier recoverable edits, even when bridged or interrupted.
This exemption requires the recorded invocation, not just result metadata.

## Filesystem history: `fs_checkpoint`

The former filesystem `checkpoint` tool is now named `fs_checkpoint`. There is
no alias. Migrate tool allow/deny lists and explicit tool requests to the new name
when filesystem inspection or restoration is intended.

- `action: "list"`: list checkpoints for the current session.
- `action: "diff"`: inspect a `checkpoint_id`, optionally limited to `paths`.
- `action: "restore"`: restore a checkpoint, optionally limited to `paths`.
- `action: "delete"`: delete a checkpoint by ID.

Checkpoints are owned by the session id of the session that captured them
(`CodingAgent.Checkpoint.owner/1`), and every action is scoped to that owner.
The owner is never taken from model input (there is no `session_id`
parameter) or from `session_key`/`run_id`.
Without a session id, tools capture no checkpoint and `fs_checkpoint` refuses to
run. Subagent/task children run in their own sessions and own their own
checkpoints; they cannot reach the parent's. IDs must have the generated
`chk_` + 16 hex digit shape. Malformed IDs and checkpoints owned by another
session are reported as not found, and nothing is read, written or deleted.
Restore and diff only act on the root paths recorded when the checkpoint was
captured. Checkpoints whose snapshots name other paths, or that have no
recorded roots, are refused; rewind preview lists their tools as unrestorable.
No roots were recorded before this check existed (some of those checkpoints
were also owned by a session key), so all such legacy checkpoints are
unavailable to diff, restore and rewind rather than migrated. Diff does not
read through a symlinked parent directory or leaf.

Normal write/edit/patch operations still create filesystem checkpoints
independently of the conversation checkpoint feature flag. Filesystem restoration
remains a mutating operation subject to the session's approval and tool policy.
Operator rewind uses captures from mutating tools, not checkpoint IDs echoed by
inspection results. Manual filesystem restores and unknown checkpoint actions
cannot be undone by operator file restoration and fail closed, including
interrupted calls and historical action-shaped `checkpoint` invocations.
History-only rewind remains available.
The TUI uses its generic tool card for `fs_checkpoint`, `checkpoint` and `rewind`;
no legacy filesystem-specific renderer or tool-name alias is retained.
