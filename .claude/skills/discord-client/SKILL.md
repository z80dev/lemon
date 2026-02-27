---
name: discord-client
description: "Interact with Discord via a bot: read channels, send messages, list guilds/channels, upload files, manage threads. Uses the Discord REST API with a bot token stored in ~/.zeebot/api_keys/discord.txt."
disable-model-invocation: true
argument-hint: "[action, e.g. 'read messages in #general' or 'send hello to channel 123']"
allowed-tools: Read, Grep, Bash, Glob, Write
---

# Discord Client

Use this skill to interact with Discord via the bot account.

## Quick Reference

All commands use the helper script at `/Users/z80/dev/lemon/.claude/skills/discord-client/discord_api.py`.
Run via `uv` so no install is needed:

```bash
SCRIPT="/Users/z80/dev/lemon/.claude/skills/discord-client/discord_api.py"
uv run --with httpx python "$SCRIPT" <command> [args]
```

### Commands

| Command | Description |
|---------|-------------|
| `me` | Show bot info |
| `guilds` | List all servers the bot is in |
| `channels <guild_id>` | List channels in a server |
| `read <channel_id> [--limit N] [--before ID] [--after ID]` | Read messages (default 50, oldest first) |
| `send <channel_id> "message"` | Send a message |
| `reply <channel_id> <msg_id> "text"` | Reply to a message |
| `edit <channel_id> <msg_id> "new text"` | Edit a bot message |
| `delete <channel_id> <msg_id>` | Delete a message |
| `react <channel_id> <msg_id> <emoji>` | Add a reaction |
| `upload <channel_id> <file_path> [--caption "text"]` | Upload a file |
| `threads <channel_id>` | List threads |
| `thread-create <channel_id> "name"` | Create a thread |
| `members <guild_id> [--limit N]` | List server members |

## Workflow

1. **Discover**: Run `guilds` to find the guild ID, then `channels <guild_id>` to find channel IDs.
2. **Read**: Run `read <channel_id>` to see recent messages. Use `--limit`, `--before`, `--after` to paginate.
3. **Act**: Use `send`, `reply`, `edit`, `delete`, `react`, `upload` as needed.

## Token

The bot token is loaded automatically from `~/.zeebot/api_keys/discord.txt` (field: `bot_token`).

- NEVER print, echo, or commit the token.
- NEVER include the token in scripts written to disk.
- The helper script reads it at runtime from the secrets file.

## Notes

- The bot can only act in servers/channels it has been invited to with appropriate permissions.
- Message content requires the **Message Content Intent** to be enabled in the Discord Developer Portal.
- The bot can read messages from other bots and users.
- Rate limits: Discord enforces per-route rate limits. The script will get HTTP 429 if you hit them — back off and retry.
- Max message length: 2000 characters. For longer content, split into multiple messages or upload as a file.

## Custom Scripts

For operations not covered by the CLI, write a temporary Python script that imports the helpers:

```python
import sys
sys.path.insert(0, "/Users/z80/dev/lemon/.claude/skills/discord-client")
from discord_api import load_token, api_get, api_post, BASE

token = load_token()
# ... custom API calls
```

If `$ARGUMENTS` is provided, perform the requested Discord action.
