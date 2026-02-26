---
name: session-logs
description: Search and analyze your own Lemon session logs (older/parent conversations) using jq.
metadata: { "lemon": { "emoji": "📜", "requires": { "bins": ["jq", "rg"] } } }
---

# session-logs

Search your complete conversation history stored in Lemon session JSONL files. Use this when a user references older/parent conversations or asks what was said before.

## Trigger

Use this skill when the user asks about prior chats, parent conversations, or historical context that isn't in current memory files.

## Location

Session logs live under `~/.lemon/agent/sessions/` and are organized by encoded working directory name:

- `<encoded-cwd>/*.jsonl` - Full conversation transcript per session

For example: `~/.lemon/agent/sessions/--home-user-project--/2026...jsonl`

The first line in each `.jsonl` is a session header with metadata.

## Structure

Each `.jsonl` file contains messages with:

- `type`: `"session"` (metadata header) or `"message"` (conversation entries)
- `timestamp`: Epoch timestamp
- `message.role`: `"user"`, `"assistant"`, etc.
- `message.content[]`: Text, thinking, or tool calls (filter `type=="text"` for human-readable content)
- `message.usage.cost.total`: Cost per response

## Common Queries

### List all sessions by date and size

```bash
for f in ~/.lemon/agent/sessions/*/*.jsonl; do
  ts=$(jq -r 'select(.type=="session") | .timestamp' "$f")
  size=$(wc -c <"$f")
  started="$(date -r "$((ts / 1000))" '+%F %T' 2>/dev/null || printf 'ts=%s' "$ts")"
  echo "$started $size $(basename "$f")"
done | sort -r
```

### Find sessions from a specific day

```bash
for f in ~/.lemon/agent/sessions/*/*.jsonl; do
  ts=$(jq -r 'select(.type=="session") | .timestamp' "$f")
  day="$(date -r "$((ts / 1000))" '+%F' 2>/dev/null || true)"
  [[ "$day" == "2026-01-06" ]] && echo "$f"
done
```

### Extract user messages from a session

```bash
jq -r 'select(.type=="message" and .message.role == "user") | .message.content[]? | select(.type == "text") | .text' <session>.jsonl
```

### Search for keyword in assistant responses

```bash
jq -r 'select(.type=="message" and .message.role == "assistant") | .message.content[]? | select(.type == "text") | .text' <session>.jsonl | rg -i "keyword"
```

### Get total cost for a session

```bash
jq -s '[.[] | select(.type=="message") | .message.usage.cost.total // 0] | add' <session>.jsonl
```

### Daily cost summary

```bash
for f in ~/.lemon/agent/sessions/*/*.jsonl; do
  day="$(date -r "$(( $(jq -r 'select(.type=="session") | .timestamp' "$f") / 1000 ))" '+%F' 2>/dev/null || continue)"
  cost=$(jq -s '[.[] | select(.type=="message") | .message.usage.cost.total // 0] | add' "$f")
  echo "$day $cost"
done | awk '{a[$1]+=$2} END {for(d in a) print d, "$"a[d]}' | sort -r
```

### Count messages and tokens in a session

```bash
jq -s '{
  messages: length,
  user: [.[] | select(.type=="message" and .message.role == "user")] | length,
  assistant: [.[] | select(.type=="message" and .message.role == "assistant")] | length,
  first: .[0].timestamp,
  last: .[-1].timestamp
}' <session>.jsonl
```

### Tool usage breakdown

```bash
jq -r '.message.content[]? | select(.type == "toolCall") | .name' <session>.jsonl | sort | uniq -c | sort -rn
```

### Search across ALL sessions for a phrase

```bash
rg -l "phrase" ~/.lemon/agent/sessions/*/*.jsonl
```

## Tips

- Sessions are append-only JSONL (one JSON object per line)
- Large sessions can be several MB - use `head`/`tail` for sampling
- `~/.lemon/agent/sessions` is the session root in Lemon
- No separate `sessions.json` index file exists for logs

## Fast text-only hint (low noise)

```bash
jq -r 'select(.type=="message") | .message.content[]? | select(.type=="text") | .text' ~/.lemon/agent/sessions/*/*.jsonl | rg 'keyword'
```
