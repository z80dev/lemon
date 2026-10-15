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

Only one checkpoint may be active. A checkpoint becomes ready after its tool turn
finishes. Rewind is single-use, refuses an empty report and refuses to cross a
new user message. Active and completed checkpoints follow the selected persisted
branch on resume or tree navigation. Subagents receive the pair only when either
name is explicitly requested. Requesting either includes both, subject to policy.

These tools do **not** snapshot or restore files, undo shell commands or restore
external state. They do not ask for confirmation because they collapse only the
model's own exploration. The operator `/rewind` preview/confirmation and optional
file restoration workflow is unchanged.

## Filesystem history: `fs_checkpoint`

The former filesystem `checkpoint` tool is now named `fs_checkpoint`. There is
no alias. Migrate tool allow/deny lists and explicit tool requests to the new name
when filesystem inspection or restoration is intended.

- `action: "list"`: list checkpoints for the current session, or `session_id`.
- `action: "diff"`: inspect a `checkpoint_id`, optionally limited to `paths`.
- `action: "restore"`: restore a checkpoint, optionally limited to `paths`.
- `action: "delete"`: delete a checkpoint by ID.

Normal write/edit/patch operations still create filesystem checkpoints
independently of the conversation checkpoint feature flag. Filesystem restoration
remains a mutating operation subject to the session's approval and tool policy.
The TUI uses its generic tool card for `fs_checkpoint`, `checkpoint` and `rewind`;
no legacy filesystem-specific renderer or tool-name alias is retained.
