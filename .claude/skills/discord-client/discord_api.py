"""
Discord REST API client for Claude Code skill usage.

Usage via uv (no install needed):
    uv run --with httpx python /path/to/discord_api.py <command> [args]

Commands:
    guilds                              List all guilds the bot is in
    channels <guild_id>                 List channels in a guild
    read <channel_id> [--limit N]       Read recent messages (default 50)
    send <channel_id> "message"         Send a message
    reply <channel_id> <msg_id> "text"  Reply to a specific message
    edit <channel_id> <msg_id> "text"   Edit a message
    delete <channel_id> <msg_id>        Delete a message
    react <channel_id> <msg_id> <emoji> Add a reaction
    upload <channel_id> <file_path>     Upload a file (optional --caption)
    threads <channel_id>                List active threads
    thread-create <channel_id> "name"   Create a new thread
    members <guild_id> [--limit N]      List guild members
    me                                  Show bot user info
"""

import httpx
import json
import sys
from pathlib import Path


def load_token():
    """Load the second bot_token (zeebot-debug) from ~/.zeebot/api_keys/discord.txt.

    The file has two bot_token entries:
      - First: zeebot (used by the gateway)
      - Second: zeebot-debug (used by this skill)
    """
    path = Path.home() / ".zeebot" / "api_keys" / "discord.txt"
    if not path.exists():
        print(f"Error: {path} not found", file=sys.stderr)
        sys.exit(1)
    tokens = []
    for line in path.read_text().splitlines():
        line = line.strip()
        if line.startswith("#") or not line:
            continue
        parts = line.split(None, 1)
        if len(parts) == 2 and parts[0] == "bot_token":
            tokens.append(parts[1])
    if len(tokens) < 2:
        if tokens:
            return tokens[0]
        print("Error: bot_token not found in discord.txt", file=sys.stderr)
        sys.exit(1)
    return tokens[1]  # zeebot-debug


BASE = "https://discord.com/api/v10"


def headers(token):
    return {"Authorization": f"Bot {token}"}


def api_get(token, path, params=None):
    r = httpx.get(f"{BASE}{path}", headers=headers(token), params=params, timeout=30)
    r.raise_for_status()
    return r.json()


def api_post(token, path, payload=None):
    r = httpx.post(f"{BASE}{path}", headers=headers(token), json=payload, timeout=30)
    r.raise_for_status()
    return r.json()


def api_patch(token, path, payload):
    r = httpx.patch(f"{BASE}{path}", headers=headers(token), json=payload, timeout=30)
    r.raise_for_status()
    return r.json()


def api_put(token, path):
    r = httpx.put(f"{BASE}{path}", headers=headers(token), timeout=30)
    r.raise_for_status()


def api_delete(token, path):
    r = httpx.delete(f"{BASE}{path}", headers=headers(token), timeout=30)
    r.raise_for_status()


def fmt_msg(m):
    author = m["author"]["username"]
    content = m.get("content", "")
    ts = m["timestamp"][:19]
    mid = m["id"]
    attachments = [a["url"] for a in m.get("attachments", [])]
    embeds = len(m.get("embeds", []))
    parts = [f"[{ts}] {author} ({mid}): {content}"]
    if attachments:
        parts.append(f"  attachments: {', '.join(attachments)}")
    if embeds:
        parts.append(f"  embeds: {embeds}")
    ref = m.get("referenced_message")
    if ref:
        parts.append(f"  -> reply to {ref['author']['username']}: {ref.get('content', '')[:80]}")
    return "\n".join(parts)


def cmd_guilds(token, args):
    guilds = api_get(token, "/users/@me/guilds")
    for g in guilds:
        owner = " (owner)" if g.get("owner") else ""
        print(f"{g['id']}  {g['name']}{owner}")


def cmd_channels(token, args):
    if not args:
        print("Usage: channels <guild_id>", file=sys.stderr)
        sys.exit(1)
    channels = api_get(token, f"/guilds/{args[0]}/channels")
    # Sort by position
    channels.sort(key=lambda c: (c.get("parent_id") or "", c.get("position", 0)))
    type_names = {0: "text", 2: "voice", 4: "category", 5: "announcement", 13: "stage", 15: "forum"}
    for c in channels:
        t = type_names.get(c["type"], f"type={c['type']}")
        parent = f"  (in {c['parent_id']})" if c.get("parent_id") else ""
        print(f"{c['id']}  [{t:12s}] #{c.get('name', '?')}{parent}")


def cmd_read(token, args):
    if not args:
        print("Usage: read <channel_id> [--limit N] [--before MSG_ID] [--after MSG_ID]", file=sys.stderr)
        sys.exit(1)
    channel_id = args[0]
    params = {"limit": 50}
    i = 1
    while i < len(args):
        if args[i] == "--limit" and i + 1 < len(args):
            params["limit"] = int(args[i + 1])
            i += 2
        elif args[i] == "--before" and i + 1 < len(args):
            params["before"] = args[i + 1]
            i += 2
        elif args[i] == "--after" and i + 1 < len(args):
            params["after"] = args[i + 1]
            i += 2
        else:
            i += 1
    messages = api_get(token, f"/channels/{channel_id}/messages", params)
    # Print oldest first
    for m in reversed(messages):
        print(fmt_msg(m))
        print()


def cmd_send(token, args):
    if len(args) < 2:
        print("Usage: send <channel_id> \"message\"", file=sys.stderr)
        sys.exit(1)
    channel_id = args[0]
    content = " ".join(args[1:])
    msg = api_post(token, f"/channels/{channel_id}/messages", {"content": content})
    print(f"Sent message {msg['id']} to {channel_id}")


def cmd_reply(token, args):
    if len(args) < 3:
        print("Usage: reply <channel_id> <message_id> \"text\"", file=sys.stderr)
        sys.exit(1)
    channel_id, msg_id = args[0], args[1]
    content = " ".join(args[2:])
    msg = api_post(token, f"/channels/{channel_id}/messages", {
        "content": content,
        "message_reference": {"message_id": msg_id},
    })
    print(f"Replied with message {msg['id']}")


def cmd_edit(token, args):
    if len(args) < 3:
        print("Usage: edit <channel_id> <message_id> \"new text\"", file=sys.stderr)
        sys.exit(1)
    channel_id, msg_id = args[0], args[1]
    content = " ".join(args[2:])
    api_patch(token, f"/channels/{channel_id}/messages/{msg_id}", {"content": content})
    print(f"Edited message {msg_id}")


def cmd_delete(token, args):
    if len(args) < 2:
        print("Usage: delete <channel_id> <message_id>", file=sys.stderr)
        sys.exit(1)
    api_delete(token, f"/channels/{channel_id}/messages/{args[1]}")
    print(f"Deleted message {args[1]}")


def cmd_react(token, args):
    if len(args) < 3:
        print("Usage: react <channel_id> <message_id> <emoji>", file=sys.stderr)
        sys.exit(1)
    channel_id, msg_id, emoji = args[0], args[1], args[2]
    # URL-encode the emoji for the path
    import urllib.parse
    emoji_encoded = urllib.parse.quote(emoji)
    api_put(token, f"/channels/{channel_id}/messages/{msg_id}/reactions/{emoji_encoded}/@me")
    print(f"Reacted with {emoji}")


def cmd_upload(token, args):
    if len(args) < 2:
        print("Usage: upload <channel_id> <file_path> [--caption \"text\"]", file=sys.stderr)
        sys.exit(1)
    channel_id = args[0]
    file_path = Path(args[1])
    if not file_path.exists():
        print(f"Error: file not found: {file_path}", file=sys.stderr)
        sys.exit(1)
    caption = None
    if "--caption" in args:
        idx = args.index("--caption")
        if idx + 1 < len(args):
            caption = " ".join(args[idx + 1:])
    data = {}
    if caption:
        data["content"] = caption
    with open(file_path, "rb") as f:
        files = {"files[0]": (file_path.name, f)}
        h = {"Authorization": f"Bot {load_token()}"}
        r = httpx.post(f"{BASE}/channels/{channel_id}/messages", headers=h, data=data, files=files, timeout=60)
        r.raise_for_status()
        msg = r.json()
    print(f"Uploaded {file_path.name} as message {msg['id']}")


def cmd_threads(token, args):
    if not args:
        print("Usage: threads <channel_id>", file=sys.stderr)
        sys.exit(1)
    data = api_get(token, f"/channels/{args[0]}/threads/archived/public")
    active = api_get(token, f"/guilds/{args[0]}/threads/active") if False else {"threads": []}
    all_threads = data.get("threads", []) + active.get("threads", [])
    for t in all_threads:
        print(f"{t['id']}  {t.get('name', '?')}  (messages: {t.get('message_count', '?')})")


def cmd_thread_create(token, args):
    if len(args) < 2:
        print("Usage: thread-create <channel_id> \"thread name\"", file=sys.stderr)
        sys.exit(1)
    channel_id = args[0]
    name = " ".join(args[1:])
    thread = api_post(token, f"/channels/{channel_id}/threads", {
        "name": name,
        "type": 11,  # PUBLIC_THREAD
        "auto_archive_duration": 1440,
    })
    print(f"Created thread {thread['id']}: {thread['name']}")


def cmd_members(token, args):
    if not args:
        print("Usage: members <guild_id> [--limit N]", file=sys.stderr)
        sys.exit(1)
    guild_id = args[0]
    limit = 100
    if "--limit" in args:
        idx = args.index("--limit")
        if idx + 1 < len(args):
            limit = int(args[idx + 1])
    members = api_get(token, f"/guilds/{guild_id}/members", {"limit": limit})
    for m in members:
        user = m.get("user", {})
        nick = m.get("nick") or user.get("global_name") or ""
        bot = " [BOT]" if user.get("bot") else ""
        print(f"{user.get('id', '?')}  {user.get('username', '?')}  ({nick}){bot}")


def cmd_me(token, args):
    me = api_get(token, "/users/@me")
    print(json.dumps(me, indent=2))


COMMANDS = {
    "guilds": cmd_guilds,
    "channels": cmd_channels,
    "read": cmd_read,
    "send": cmd_send,
    "reply": cmd_reply,
    "edit": cmd_edit,
    "delete": cmd_delete,
    "react": cmd_react,
    "upload": cmd_upload,
    "threads": cmd_threads,
    "thread-create": cmd_thread_create,
    "members": cmd_members,
    "me": cmd_me,
}


def main():
    if len(sys.argv) < 2 or sys.argv[1] in ("-h", "--help"):
        print(__doc__)
        sys.exit(0)

    cmd = sys.argv[1]
    if cmd not in COMMANDS:
        print(f"Unknown command: {cmd}", file=sys.stderr)
        print(f"Available: {', '.join(COMMANDS.keys())}", file=sys.stderr)
        sys.exit(1)

    token = load_token()
    COMMANDS[cmd](token, sys.argv[2:])


if __name__ == "__main__":
    main()
