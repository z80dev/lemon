# Tool Issue Reports

`report_issue` records observed tool misbehavior as a short plain-text note. It is
a local QA sink, not a GitHub issue creator or network submission.

```json
{"tool":"read","note":"A bounded selector returned unrelated line numbers."}
```

`note` is required, nonblank UTF-8 text of at most 4096 bytes. `tool` is an
optional nonblank tool name of at most 128 bytes. Do not include credentials,
private conversation content, or complete tool arguments/results.

Each successful call appends a JSON object containing `note`, `tool` (or null),
UTC `timestamp`, and `session_id` to `tool-issues.jsonl` beneath the session's
state/spill directory. A nonempty session id is required. The file is private
(mode 0600), and writes are serialized. It retains the newest complete records
within a 1 MiB byte budget, dropping oldest records on rotation. A failed write
returns an error rather than claiming the report was recorded.

The tool has the read approval tier and requires no approval by default,
including the standard ask/write/yolo modes. Explicit per-tool approval
requirements and inherited parent restrictions remain authoritative; normal
allow/deny policy can remove the tool. Reporting does not edit project files,
create checkpoints, or send the note to a remote service.
