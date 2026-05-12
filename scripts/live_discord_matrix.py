#!/usr/bin/env -S uv run
# /// script
# dependencies = ["websockets>=12.0"]
# ///

import argparse
import asyncio
import json
import os
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from pathlib import Path


DEFAULT_CREDENTIALS = Path.home() / ".zeebot/api_keys/discord.txt"
DEFAULT_GUILD_ID = "1475727416549969980"
DEFAULT_CONTROL_PLANE_WS_URL = "ws://127.0.0.1:4040/ws"
API_BASE = "https://discord.com/api/v10"
BOT_TOKEN_KEYS = {"bot_token", "discord_bot_token", "discord_bot", "bot", "token"}


class Check:
    def __init__(self, run, sender):
        self.run = run
        self.sender = sender

    def __call__(self, channel_id):
        return self.run(channel_id)


def load_pairs(path):
    pairs = []

    for raw in Path(path).read_text().splitlines():
        line = raw.strip()

        if not line or line.startswith("#"):
            continue

        if line.startswith("export "):
            line = line[7:].strip()

        if "=" in line:
            key, value = line.split("=", 1)
        else:
            parts = line.split(None, 1)

            if len(parts) != 2:
                key, value = "bot_token", line
            else:
                key, value = parts

        value = value.strip().strip("'\"")

        if value.lower().startswith("bot "):
            value = value[4:].strip()

        pairs.append((key.strip().lower(), value))

    return pairs


def bot_tokens(args):
    tokens = []

    if os.environ.get("DISCORD_BOT_TOKEN"):
        tokens.append(os.environ["DISCORD_BOT_TOKEN"])

    if args.credentials.exists():
        tokens.extend(value for key, value in load_pairs(args.credentials) if key in BOT_TOKEN_KEYS)

    if not tokens:
        raise SystemExit(f"No bot_token found in env or {args.credentials}")

    return tokens


def select_token(args):
    tokens = bot_tokens(args)
    index = args.bot_token_index

    try:
        return tokens[index]
    except IndexError:
        raise SystemExit(f"bot token index {index} out of range; found {len(tokens)} token(s)")


def api(token, method, path, payload=None):
    data = None
    headers = {
        "Authorization": f"Bot {token}",
        "User-Agent": "LemonLiveDiscordMatrix/1.0",
    }

    if payload is not None:
        data = json.dumps(payload).encode()
        headers["Content-Type"] = "application/json"

    request = urllib.request.Request(API_BASE + path, data=data, headers=headers, method=method)

    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            body = response.read()

            if not body:
                return None

            return json.loads(body.decode())
    except urllib.error.HTTPError as error:
        body = error.read().decode(errors="replace")
        raise SystemExit(f"Discord API {method} {path} failed: {error.code} {body}")


def bot_identity(token):
    user = api(token, "GET", "/users/@me")

    return {
        "id": user.get("id"),
        "username": user.get("username"),
        "bot": user.get("bot"),
    }


def list_channels(token, guild_id):
    channels = api(token, "GET", f"/guilds/{guild_id}/channels")

    return [
        {
            "id": channel.get("id"),
            "name": channel.get("name"),
            "type": channel.get("type"),
            "parent_id": channel.get("parent_id"),
        }
        for channel in channels
    ]


def get_messages(token, channel_id, limit=50):
    query = urllib.parse.urlencode({"limit": limit})
    return api(token, "GET", f"/channels/{channel_id}/messages?{query}")


def send_message(token, channel_id, content):
    return api(token, "POST", f"/channels/{channel_id}/messages", {"content": content})


def create_thread(token, channel_id, name):
    return api(
        token,
        "POST",
        f"/channels/{channel_id}/threads",
        {
            "name": name[:100],
            "type": 11,
            "auto_archive_duration": 60,
        },
    )


def find_message(messages, predicate):
    for message in messages:
        if predicate(message):
            return message

    return None


def run_bot_api_smoke(token, channel_id):
    nonce = f"lemon-discord-bot-api-{int(time.time())}"
    content = f"{nonce} bot API smoke. This does not prove Lemon inbound handling."
    sent = send_message(token, channel_id, content)
    messages = get_messages(token, channel_id, limit=20)
    found = find_message(messages, lambda message: message.get("id") == sent.get("id"))

    return {
        "name": "discord_bot_api_smoke_not_inbound_proof",
        "ok": found is not None,
        "nonce": nonce,
        "channel_id": channel_id,
        "message_id": sent.get("id"),
        "proof_scope": "bot API reachability only",
    }


def run_user_inbound_wait(token, channel_id, bot_id, timeout_s, sender=None):
    nonce = f"lemon-discord-user-{int(time.time())}"
    prompt = f"{nonce} Discord matrix probe: reply with exactly OK {nonce}"
    expected = f"OK {nonce}"
    return run_user_prompt_check(
        token,
        channel_id,
        bot_id,
        timeout_s,
        name="discord_user_inbound_prompt_round_trip",
        nonce=nonce,
        prompt=prompt,
        expected_description=expected,
        validator=lambda messages, user_message: validate_exact_reply(messages, bot_id, user_message, expected),
        sender=sender,
    )


def run_markdown_wait(token, channel_id, bot_id, timeout_s, sender=None):
    nonce = f"lemon-discord-markdown-{int(time.time())}"
    prompt = (
        f"{nonce} Discord matrix probe: reply with a bold marker **BOLD {nonce}** "
        f"and a fenced code block containing CODE {nonce}"
    )

    return run_user_prompt_check(
        token,
        channel_id,
        bot_id,
        timeout_s,
        name="discord_markdown_code_rendering",
        nonce=nonce,
        prompt=prompt,
        expected_description=f"reply contains **BOLD {nonce}** and fenced CODE {nonce}",
        validator=lambda messages, user_message: validate_combined_reply(
            messages,
            bot_id,
            user_message,
            nonce,
            required=[f"**BOLD {nonce}**", "```", f"CODE {nonce}"],
        ),
        sender=sender,
    )


def run_long_output_wait(token, channel_id, bot_id, timeout_s, sender=None):
    nonce = f"lemon-discord-long-{int(time.time())}"
    prompt = (
        f"{nonce} Discord matrix probe: reply with BEGIN {nonce}, then at least "
        f"2300 visible characters, then END {nonce}"
    )

    return run_user_prompt_check(
        token,
        channel_id,
        bot_id,
        timeout_s,
        name="discord_long_output_chunking",
        nonce=nonce,
        prompt=prompt,
        expected_description=f"combined bot reply contains BEGIN/END {nonce} and length >= 2300",
        validator=lambda messages, user_message: validate_combined_reply(
            messages,
            bot_id,
            user_message,
            nonce,
            required=[f"BEGIN {nonce}", f"END {nonce}"],
            min_length=2300,
        ),
        sender=sender,
    )


def run_tool_rendering_wait(token, channel_id, bot_id, timeout_s, sender=None):
    nonce = f"lemon-discord-tool-{int(time.time())}"
    prompt = (
        f"{nonce} Discord matrix probe: use shell tools. First run a command that prints "
        f"TOOL_OK {nonce}. Then run a command that prints TOOL_FAIL {nonce} and exits "
        f"nonzero. After both commands finish, reply with TOOL_MATRIX {nonce}."
    )

    return run_user_prompt_check(
        token,
        channel_id,
        bot_id,
        timeout_s,
        name="discord_tool_success_failure_rendering",
        nonce=nonce,
        prompt=prompt,
        expected_description=f"bot output contains TOOL_OK, TOOL_FAIL, and TOOL_MATRIX for {nonce}",
        validator=lambda messages, user_message: validate_combined_reply(
            messages,
            bot_id,
            user_message,
            nonce,
            required=[f"TOOL_OK {nonce}", f"TOOL_FAIL {nonce}", f"TOOL_MATRIX {nonce}"],
        ),
        sender=sender,
    )


def run_file_delivery_wait(token, channel_id, bot_id, timeout_s, sender=None):
    nonce = f"lemon-discord-file-{int(time.time())}"
    filename = f"discord-proof-{nonce}.txt"
    prompt = (
        f"{nonce} Discord matrix probe: create a text file named tmp/{filename} containing "
        f"FILE {nonce}, send that file back to this Discord channel as an attachment, "
        f"and reply with FILE_SENT {nonce}."
    )

    return run_user_prompt_check(
        token,
        channel_id,
        bot_id,
        timeout_s,
        name="discord_file_delivery",
        nonce=nonce,
        prompt=prompt,
        expected_description=f"bot reply contains FILE_SENT {nonce} and a Discord attachment",
        validator=lambda messages, user_message: validate_file_delivery(
            messages,
            bot_id,
            user_message,
            nonce,
            filename,
        ),
        sender=sender,
    )


def run_user_prompt_check(
    token,
    channel_id,
    bot_id,
    timeout_s,
    *,
    name,
    nonce,
    prompt,
    expected_description,
    validator,
    sender=None,
):
    deadline = time.time() + timeout_s
    user_message = None
    bot_result = None
    recent = []

    if sender:
        prompt_to_send = sender_prompt(sender, bot_id, prompt)
        sent = send_message(sender["token"], channel_id, prompt_to_send)
        print(
            json.dumps(
                {
                    "action": "sent_bot_message",
                    "channel_id": channel_id,
                    "sender": sender["identity"],
                    "message_id": sent.get("id"),
                    "prompt": prompt_to_send,
                    "expected_bot_reply": expected_description,
                },
                indent=2,
            ),
            flush=True,
        )
    else:
        print(
            json.dumps(
                {
                    "action_required": "send_user_message",
                    "channel_id": channel_id,
                    "prompt": prompt,
                    "expected_bot_reply": expected_description,
                },
                indent=2,
            ),
            flush=True,
        )

    while time.time() < deadline:
        recent = get_messages(token, channel_id, limit=50)

        if user_message is None:
            user_message = find_message(
                recent,
                lambda message: nonce in (message.get("content") or "")
                and message.get("author", {}).get("id") != bot_id
                and sender_matches(message, sender)
                and message.get("webhook_id") is None,
            )

        if user_message is not None:
            bot_result = validator(recent, user_message)

            if bot_result["ok"]:
                break

        time.sleep(2)

    return {
        "name": name,
        "ok": bot_result is not None and bot_result["ok"],
        "nonce": nonce,
        "channel_id": channel_id,
        "user_message": summarize_message(user_message),
        "bot_reply": None if bot_result is None else bot_result.get("summary"),
        "sender_proof": sender_proof(sender),
        "recent": [summarize_message(message) for message in recent[:10]],
    }


def sender_prompt(sender, bot_id, prompt):
    if sender.get("mention_responder", True):
        return f"<@{bot_id}> {prompt}"

    return prompt


def sender_matches(message, sender):
    author = message.get("author", {})

    if sender:
        return author.get("id") == sender["identity"].get("id")

    return not author.get("bot", False)


def sender_proof(sender):
    if not sender:
        return {"kind": "non_bot_user"}

    return {
        "kind": "bot_to_bot",
        "sender": sender["identity"],
        "mention_responder": sender.get("mention_responder", True),
    }


def discord_session_key(args, channel_id, sender):
    if not sender:
        raise SystemExit("--reset-session-between-checks requires --sender-bot-token-index")

    return (
        f"agent:{args.agent_id}:discord:{args.account_id}:group:{channel_id}"
        f":sub:{sender['identity']['id']}"
    )


async def reset_session_ws(ws_url, session_key):
    import websockets

    async with websockets.connect(ws_url) as ws:
        await ws.send(
            json.dumps(
                {
                    "type": "req",
                    "id": str(uuid.uuid4()),
                    "method": "connect",
                    "params": {
                        "role": "operator",
                        "scopes": ["operator.admin"],
                        "client": {"id": "lemon-discord-matrix"},
                    },
                }
            )
        )
        hello = json.loads(await ws.recv())

        if hello.get("type") != "hello-ok":
            raise SystemExit(f"control-plane connect failed: {json.dumps(hello)}")

        request_id = str(uuid.uuid4())
        await ws.send(
            json.dumps(
                {
                    "type": "req",
                    "id": request_id,
                    "method": "sessions.reset",
                    "params": {"sessionKey": session_key},
                }
            )
        )

        while True:
            response = json.loads(await ws.recv())

            if response.get("type") != "res" or response.get("id") != request_id:
                continue

            if response.get("ok") is not True:
                raise SystemExit(f"control-plane sessions.reset failed: {json.dumps(response)}")

            return response


def maybe_reset_session(args, channel_id, sender):
    if not args.reset_session_between_checks:
        return None

    session_key = discord_session_key(args, channel_id, sender)
    response = asyncio.run(reset_session_ws(args.control_plane_ws_url, session_key))

    return {
        "session_key": session_key,
        "control_plane_ws_url": args.control_plane_ws_url,
        "response": response.get("payload"),
    }


def validate_exact_reply(messages, bot_id, user_message, expected):
    user_id = user_message.get("author", {}).get("id")
    user_created = user_message.get("timestamp")

    bot_reply = find_message(
        messages,
        lambda message: message.get("author", {}).get("id") == bot_id
        and (message.get("content") or "").strip() == expected
        and message.get("timestamp", "") >= user_created
        and user_id != bot_id,
    )

    return {"ok": bot_reply is not None, "summary": summarize_message(bot_reply)}


def validate_combined_reply(messages, bot_id, user_message, nonce, required, min_length=0):
    user_created = user_message.get("timestamp")

    bot_messages = [
        message
        for message in messages
        if message.get("author", {}).get("id") == bot_id
        and message.get("timestamp", "") >= user_created
        and nonce in (message.get("content") or "")
    ]
    ordered = sorted(bot_messages, key=lambda message: message.get("timestamp") or "")
    combined = "\n".join(message.get("content") or "" for message in ordered)
    ok = bool(ordered) and len(combined) >= min_length and all(marker in combined for marker in required)

    return {
        "ok": ok,
        "summary": {
            "message_count": len(ordered),
            "combined_length": len(combined),
            "message_ids": [message.get("id") for message in ordered],
            "missing": [marker for marker in required if marker not in combined],
        },
    }


def validate_file_delivery(messages, bot_id, user_message, nonce, filename):
    combined = validate_combined_reply(
        messages,
        bot_id,
        user_message,
        nonce,
        required=[f"FILE_SENT {nonce}"],
    )
    user_created = user_message.get("timestamp")

    bot_messages = [
        message
        for message in messages
        if message.get("author", {}).get("id") == bot_id
        and message.get("timestamp", "") >= user_created
    ]
    attachments = [
        attachment
        for message in bot_messages
        for attachment in (message.get("attachments") or [])
    ]
    matching = [
        attachment
        for attachment in attachments
        if filename in (attachment.get("filename") or "") or nonce in (attachment.get("filename") or "")
    ]
    ok = combined["ok"] and bool(matching)

    return {
        "ok": ok,
        "summary": {
            **(combined.get("summary") or {}),
            "attachment_count": len(attachments),
            "matching_attachments": [summarize_attachment(attachment) for attachment in matching],
        },
    }


def summarize_message(message):
    if not message:
        return None

    author = message.get("author") or {}

    return {
        "id": message.get("id"),
        "author_id": author.get("id"),
        "author_bot": author.get("bot", False),
        "content": message.get("content"),
        "timestamp": message.get("timestamp"),
        "channel_id": message.get("channel_id"),
        "attachments": [summarize_attachment(attachment) for attachment in message.get("attachments", [])],
    }


def summarize_attachment(attachment):
    return {
        "id": attachment.get("id"),
        "filename": attachment.get("filename"),
        "size": attachment.get("size"),
        "content_type": attachment.get("content_type"),
    }


def parser():
    root = argparse.ArgumentParser(description="Run Lemon live Discord channel checks.")
    root.add_argument("--credentials", type=Path, default=Path(os.environ.get("LEMON_DISCORD_CREDS_PATH", DEFAULT_CREDENTIALS)))
    root.add_argument("--bot-token-index", type=int, default=-1)
    root.add_argument("--sender-bot-token-index", type=int)
    root.add_argument("--no-mention-responder", action="store_true")
    root.add_argument("--per-check-thread", action="store_true")
    root.add_argument("--reset-session-between-checks", action="store_true")
    root.add_argument("--control-plane-ws-url", default=os.environ.get("LEMON_CONTROL_PLANE_WS_URL", DEFAULT_CONTROL_PLANE_WS_URL))
    root.add_argument("--account-id", default="default")
    root.add_argument("--agent-id", default="default")
    root.add_argument("--guild-id", default=DEFAULT_GUILD_ID)
    root.add_argument("--channel-id")
    root.add_argument("--list-channels", action="store_true")
    root.add_argument("--bot-api-smoke", action="store_true")
    root.add_argument("--wait-user-inbound", action="store_true")
    root.add_argument("--wait-markdown", action="store_true")
    root.add_argument("--wait-long-output", action="store_true")
    root.add_argument("--wait-tool-rendering", action="store_true")
    root.add_argument("--wait-file-delivery", action="store_true")
    root.add_argument("--manual-matrix", action="store_true")
    root.add_argument("--continue-on-failure", action="store_true")
    root.add_argument("--result-path", type=Path)
    root.add_argument("--timeout", type=int, default=120)
    return root


def resolve_sender(args, responder_identity):
    if args.sender_bot_token_index is None:
        return None

    tokens = bot_tokens(args)

    try:
        sender_token = tokens[args.sender_bot_token_index]
    except IndexError:
        raise SystemExit(
            f"sender bot token index {args.sender_bot_token_index} out of range; found {len(tokens)} token(s)"
        )

    sender_identity = bot_identity(sender_token)

    if sender_identity.get("id") == responder_identity.get("id"):
        raise SystemExit("sender bot token must identify a different bot than --bot-token-index")

    return {
        "token": sender_token,
        "identity": sender_identity,
        "mention_responder": not args.no_mention_responder,
    }


def run_in_check_channel(args, token, run_check, check_index):
    if not args.per_check_thread:
        reset = maybe_reset_session(args, args.channel_id, run_check.sender)
        check = run_check(args.channel_id)

        if reset:
            check["session_reset"] = reset

        return check

    thread_name = f"lemon-discord-proof-{int(time.time())}-{check_index}"
    thread = create_thread(token, args.channel_id, thread_name)
    thread_id = thread.get("id")

    if not thread_id:
        raise SystemExit(f"Discord thread creation returned no id: {json.dumps(thread)}")

    check = run_check(thread_id)
    check["parent_channel_id"] = args.channel_id
    check["thread"] = {
        "id": thread.get("id"),
        "name": thread.get("name"),
        "type": thread.get("type"),
        "parent_id": thread.get("parent_id"),
    }
    return check


def main():
    args = parser().parse_args()
    token = select_token(args)
    identity = bot_identity(token)
    sender = resolve_sender(args, identity)

    if args.list_channels:
        print(
            json.dumps(
                {
                    "ok": True,
                    "bot": identity,
                    "guild_id": args.guild_id,
                    "channels": list_channels(token, args.guild_id),
                },
                indent=2,
            )
        )
        return

    if not args.channel_id:
        raise SystemExit("--channel-id is required unless --list-channels is used")

    selected = []

    if args.bot_api_smoke:
        selected.append(Check(lambda channel_id: run_bot_api_smoke(token, channel_id), None))

    if args.wait_user_inbound or args.manual_matrix:
        selected.append(Check(lambda channel_id: run_user_inbound_wait(token, channel_id, identity["id"], args.timeout, sender=sender), sender))

    if args.wait_markdown or args.manual_matrix:
        selected.append(Check(lambda channel_id: run_markdown_wait(token, channel_id, identity["id"], args.timeout, sender=sender), sender))

    if args.wait_long_output or args.manual_matrix:
        selected.append(Check(lambda channel_id: run_long_output_wait(token, channel_id, identity["id"], args.timeout, sender=sender), sender))

    if args.wait_tool_rendering or args.manual_matrix:
        selected.append(Check(lambda channel_id: run_tool_rendering_wait(token, channel_id, identity["id"], args.timeout, sender=sender), sender))

    if args.wait_file_delivery or args.manual_matrix:
        selected.append(Check(lambda channel_id: run_file_delivery_wait(token, channel_id, identity["id"], args.timeout, sender=sender), sender))

    if not selected:
        raise SystemExit(
            "Select at least one check: --bot-api-smoke, --wait-user-inbound, --wait-markdown, --wait-long-output, --wait-tool-rendering, --wait-file-delivery, or --manual-matrix"
        )

    checks = []

    for index, run_check in enumerate(selected, start=1):
        check = run_in_check_channel(args, token, run_check, index)
        checks.append(check)

        if args.manual_matrix and not args.continue_on_failure and not check["ok"]:
            break

    result = {
        "ok": all(check["ok"] for check in checks),
        "bot": identity,
        "sender": sender_proof(sender),
        "channel_id": args.channel_id,
        "checks": checks,
    }

    if args.result_path:
        args.result_path.parent.mkdir(parents=True, exist_ok=True)
        args.result_path.write_text(json.dumps(result, indent=2) + "\n")

    print(json.dumps(result, indent=2))
    raise SystemExit(0 if result["ok"] else 1)


if __name__ == "__main__":
    main()
