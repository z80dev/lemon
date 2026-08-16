#!/usr/bin/env -S uv run
# /// script
# dependencies = ["telethon>=1.41,<2"]
# ///
"""Composable Telegram conversation driver for live lemon-bot test flows.

Library + CLI extracted from scripts/live_telegram_matrix.py so an agent can
drive ad-hoc real-Telegram flows against the lemon bot instead of only the
fixed matrix scenarios.

Library use (no import-time side effects):

    from telegram_driver import TelegramDriver

    async def flow():
        async with TelegramDriver() as driver:
            topic_id = driver.create_topic("[adhoc] my flow")
            result = await driver.send_and_await(
                "group", "reply with exactly OK", topic_id=topic_id
            )
            driver.delete_topic(topic_id)

CLI use (each subcommand supports --json for machine-readable output):

    uv run scripts/telegram_driver.py topic-create "[adhoc] probe" --json
    uv run scripts/telegram_driver.py send-and-await "hello" --topic-id 35 --json
    uv run scripts/telegram_driver.py await --topic-id 35 --after-id 1234 --json
    uv run scripts/telegram_driver.py press-button --message-id 1240 "Approve once"
    uv run scripts/telegram_driver.py topic-cleanup "[adhoc]" --json

Credentials come from ~/.zeebot/api_keys/telegram.txt (TELEGRAM_API_ID,
TELEGRAM_API_HASH, TELEGRAM_SESSION_STRING) — override the path with
--credentials or LEMON_TELEGRAM_CREDS_PATH. The Bot API token (used only for
forum-topic management) comes from LEMON_TELEGRAM_BOT_TOKEN /
TELEGRAM_BOT_TOKEN env vars, a TELEGRAM_BOT_TOKEN line in the credentials
file, or the lemon secrets store via `mix run`. Secrets are never printed.

Polling follows the hard-won reliable pattern: poll with
client.get_messages(chat, reply_to=topic_id) instead of event handlers, read
text as `m.raw_text or m.text`, filter service/empty messages, and stop after
an idle timeout once the last new message arrived.
"""

import argparse
import asyncio
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

from telethon import TelegramClient
from telethon.sessions import StringSession
from telethon.tl.functions.messages import GetForumTopicsRequest

DEFAULT_CREDENTIALS = Path.home() / ".zeebot/api_keys/telegram.txt"
DEFAULT_BOT = "zeebot_lemon_bot"
DEFAULT_GROUP = "-1003842984060"

BOT_TOKEN_ENV_VARS = ("LEMON_TELEGRAM_BOT_TOKEN", "TELEGRAM_BOT_TOKEN")
BOT_TOKEN_SECRET_NAME = "gateway_telegram_bot_token"

_TOKEN_BEGIN = "LEMON_TOKEN_BEGIN"
_TOKEN_END = "LEMON_TOKEN_END"


# --------------------------------------------------------------------------
# Credential loading (shared with scripts/live_telegram_matrix.py)
# --------------------------------------------------------------------------


def load_env(path):
    """Parse KEY=VALUE lines (optionally `export`-prefixed) into a dict."""
    data = {}
    for raw in Path(path).read_text().splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("export "):
            line = line[7:].strip()
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        data[key.strip()] = value.strip().strip("'\"")
    return data


def require_config(cfg, path):
    missing = [
        key
        for key in ("TELEGRAM_API_ID", "TELEGRAM_API_HASH", "TELEGRAM_SESSION_STRING")
        if not cfg.get(key)
    ]
    if missing:
        raise SystemExit(f"Missing {', '.join(missing)} in {path}")


def build_client(cfg):
    return TelegramClient(
        StringSession(cfg["TELEGRAM_SESSION_STRING"]),
        int(cfg["TELEGRAM_API_ID"]),
        cfg["TELEGRAM_API_HASH"],
    )


# --------------------------------------------------------------------------
# Message helpers (shared with scripts/live_telegram_matrix.py)
# --------------------------------------------------------------------------


def entity_types(msg):
    return [type(entity).__name__ for entity in (msg.entities or [])]


def row_in_topic(row, expected_topic_id):
    if expected_topic_id is None:
        return True

    return (
        row.get("reply_to_top_id") == expected_topic_id
        or row.get("reply_to_msg_id") == expected_topic_id
    )


def message_row(msg):
    reply = msg.reply_to

    return {
        "id": msg.id,
        "out": bool(msg.out),
        "text": msg.raw_text or "",
        "reply_to_msg_id": getattr(reply, "reply_to_msg_id", None) if reply else None,
        "reply_to_top_id": getattr(reply, "reply_to_top_id", None) if reply else None,
        "entity_types": entity_types(msg),
        "has_document": bool(getattr(msg, "document", None)),
        "has_photo": bool(getattr(msg, "photo", None)),
        "file_name": getattr(getattr(msg, "file", None), "name", None),
    }


def button_rows(msg):
    """Flatten a message's inline keyboard into [{text, data}] dicts."""
    markup = getattr(msg, "reply_markup", None)
    buttons = []
    for row in getattr(markup, "rows", None) or []:
        for button in getattr(row, "buttons", None) or []:
            data = getattr(button, "data", None)
            if isinstance(data, (bytes, bytearray)):
                data = data.decode("utf-8", "replace")
            else:
                data = None
            buttons.append({"text": getattr(button, "text", None), "data": data})
    return buttons


def driver_row(msg):
    """message_row plus fields useful for ad-hoc driving (date, buttons)."""
    row = message_row(msg)
    date = getattr(msg, "date", None)
    row["date"] = date.isoformat() if date else None
    row["buttons"] = button_rows(msg)
    return row


# --------------------------------------------------------------------------
# Bot API (token used only for forum-topic management and raw calls)
# --------------------------------------------------------------------------


def load_bot_token(cfg=None, repo_root=None):
    """Resolve the Bot API token without ever printing it.

    Order: env override -> TELEGRAM_BOT_TOKEN in the credentials file ->
    lemon secrets store via `mix run --no-start` (the documented house way).
    """
    for var in BOT_TOKEN_ENV_VARS:
        value = os.environ.get(var)
        if value and value.strip():
            return value.strip()

    if cfg and cfg.get("TELEGRAM_BOT_TOKEN"):
        return cfg["TELEGRAM_BOT_TOKEN"]

    root = Path(repo_root) if repo_root else Path(__file__).resolve().parents[1]
    code = (
        "Application.ensure_all_started(:lemon_core); "
        f'case LemonCore.Secrets.get("{BOT_TOKEN_SECRET_NAME}") do '
        '{:ok, token} when is_binary(token) and token != "" -> '
        f'IO.write("{_TOKEN_BEGIN}" <> token <> "{_TOKEN_END}"); '
        "_ -> System.halt(3) end"
    )
    env = os.environ.copy()
    env["LEMON_LOG_LEVEL"] = "error"

    result = subprocess.run(
        ["mix", "run", "--no-start", "--no-compile", "-e", code],
        cwd=root,
        env=env,
        capture_output=True,
        text=True,
    )

    # Never include stdout in errors: it could contain the token.
    if result.returncode != 0:
        stderr_tail = "\n".join(result.stderr.strip().splitlines()[-3:])
        raise RuntimeError(
            f"Could not resolve Telegram bot token from secrets store "
            f"(mix exit {result.returncode}). Set {BOT_TOKEN_ENV_VARS[0]} instead. "
            f"stderr tail: {stderr_tail}"
        )

    match = re.search(f"{_TOKEN_BEGIN}(.+?){_TOKEN_END}", result.stdout, re.DOTALL)
    if not match:
        raise RuntimeError(
            "Bot token markers missing from mix output. "
            f"Set {BOT_TOKEN_ENV_VARS[0]} instead."
        )

    return match.group(1).strip()


def bot_api_call(token, method, params=None, timeout=30):
    """POST to the Telegram Bot API. Errors never echo the URL (it embeds the token)."""
    url = f"https://api.telegram.org/bot{token}/{method}"
    request = urllib.request.Request(
        url,
        data=json.dumps(params or {}).encode("utf-8"),
        headers={"Content-Type": "application/json"},
    )

    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            payload = json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        try:
            description = json.loads(exc.read().decode("utf-8")).get("description")
        except Exception:
            description = None
        raise RuntimeError(
            f"Bot API {method} failed: HTTP {exc.code}: {description or 'no description'}"
        ) from None
    except urllib.error.URLError as exc:
        raise RuntimeError(f"Bot API {method} failed: {exc.reason}") from None

    if not payload.get("ok"):
        raise RuntimeError(f"Bot API {method} failed: {payload.get('description')}")

    return payload["result"]


# --------------------------------------------------------------------------
# Driver
# --------------------------------------------------------------------------


class TelegramDriver:
    """Conversation-driver primitives over a Telethon user session + Bot API.

    Async context manager: `async with TelegramDriver() as driver:` connects
    the Telethon client and verifies authorization. Topic management
    (create/delete) uses only the Bot API and works without connecting.
    """

    def __init__(
        self,
        credentials_path=None,
        group=None,
        bot=None,
        bot_token=None,
        repo_root=None,
    ):
        self.credentials_path = Path(
            credentials_path
            or os.environ.get("LEMON_TELEGRAM_CREDS_PATH", DEFAULT_CREDENTIALS)
        ).expanduser()
        self.group = str(group or os.environ.get("LEMON_TELEGRAM_GROUP", DEFAULT_GROUP))
        self.bot = str(bot or os.environ.get("LEMON_TELEGRAM_BOT", DEFAULT_BOT))
        self.repo_root = Path(repo_root) if repo_root else Path(__file__).resolve().parents[1]
        self._bot_token = bot_token
        self._cfg = None
        self._client = None
        self._entities = {}

    # -- credentials / clients ------------------------------------------------

    @property
    def cfg(self):
        if self._cfg is None:
            self._cfg = load_env(self.credentials_path)
        return self._cfg

    @property
    def client(self):
        if self._client is None:
            require_config(self.cfg, self.credentials_path)
            self._client = build_client(self.cfg)
        return self._client

    def bot_api_token(self):
        if self._bot_token is None:
            cfg = None
            if self.credentials_path.exists():
                cfg = self.cfg
            self._bot_token = load_bot_token(cfg=cfg, repo_root=self.repo_root)
        return self._bot_token

    async def __aenter__(self):
        client = self.client
        await client.__aenter__()
        if not await client.is_user_authorized():
            await client.__aexit__(None, None, None)
            raise RuntimeError("Telegram session is not authorized.")
        return self

    async def __aexit__(self, exc_type, exc, tb):
        return await self.client.__aexit__(exc_type, exc, tb)

    async def _entity(self, chat=None):
        """Resolve chat: None/"group" -> test group, "bot" -> bot DM, else id/username."""
        if chat in (None, "", "group"):
            chat = self.group
        elif chat == "bot":
            chat = self.bot

        if isinstance(chat, str):
            stripped = chat.strip()
            chat = int(stripped) if re.fullmatch(r"-?\d+", stripped) else stripped

        key = str(chat)
        if key not in self._entities:
            self._entities[key] = await self.client.get_entity(chat)
        return self._entities[key]

    # -- conversation primitives ----------------------------------------------

    async def send(self, chat=None, text="", topic_id=None):
        """Send a message; returns the sent message id.

        Works for DMs (chat="bot" or a username), plain groups, and forum
        topics (topic_id set with a group chat).
        """
        entity = await self._entity(chat)
        message = await self.client.send_message(entity, text, reply_to=topic_id)
        return message.id

    async def await_replies(
        self,
        chat=None,
        topic_id=None,
        after_id=0,
        timeout=90.0,
        idle_timeout=15.0,
        limit=50,
    ):
        """Poll for incoming (bot) messages newer than after_id.

        Reliable pattern: poll get_messages(chat, reply_to=topic_id) — never
        event handlers; read m.raw_text or m.text; skip service and empty
        messages. Returns once idle_timeout passes with no new message after
        at least one arrived, or when timeout expires. Result is a list of
        row dicts sorted by message id.
        """
        entity = await self._entity(chat)
        deadline = time.monotonic() + timeout
        last_new = time.monotonic()
        seen = {}

        while time.monotonic() < deadline:
            kwargs = {"limit": limit}
            if topic_id is not None:
                kwargs["reply_to"] = topic_id

            messages = await self.client.get_messages(entity, **kwargs)
            got_new = False

            for msg in messages:
                if msg is None or msg.id <= after_id or msg.id in seen:
                    continue
                if getattr(msg, "out", False):
                    continue
                if getattr(msg, "action", None) is not None:
                    continue  # service message (topic created, pins, ...)

                text = msg.raw_text or msg.text or ""
                has_payload = bool(
                    getattr(msg, "document", None) or getattr(msg, "photo", None)
                )
                if not text.strip() and not has_payload:
                    continue

                seen[msg.id] = driver_row(msg)
                got_new = True

            if got_new:
                last_new = time.monotonic()
            elif seen and time.monotonic() - last_new >= idle_timeout:
                break

            await asyncio.sleep(2)

        return sorted(seen.values(), key=lambda row: row["id"])

    async def send_and_await(
        self,
        chat=None,
        text="",
        topic_id=None,
        timeout=90.0,
        idle_timeout=15.0,
        limit=50,
    ):
        """send() then await_replies() scoped to messages after the sent id."""
        started = time.monotonic()
        sent_id = await self.send(chat, text, topic_id=topic_id)
        replies = await self.await_replies(
            chat,
            topic_id=topic_id,
            after_id=sent_id,
            timeout=timeout,
            idle_timeout=idle_timeout,
            limit=limit,
        )

        return {
            "sent_id": sent_id,
            "topic_id": topic_id,
            "replies": replies,
            "reply_count": len(replies),
            "elapsed_s": round(time.monotonic() - started, 2),
        }

    async def press_button(self, chat=None, message_id=None, data_or_label=""):
        """Press an inline keyboard button by callback data or visible label."""
        entity = await self._entity(chat)
        message = await self.client.get_messages(entity, ids=message_id)
        if message is None:
            raise RuntimeError(f"Message {message_id} not found")

        buttons = await message.get_buttons() or []
        flat = [button for row in buttons for button in row]
        if not flat:
            raise RuntimeError(f"Message {message_id} has no inline buttons")

        def decoded_data(button):
            data = getattr(button.button, "data", None)
            if isinstance(data, (bytes, bytearray)):
                return data.decode("utf-8", "replace")
            return None

        target = None
        via = None
        for button in flat:
            if decoded_data(button) == data_or_label:
                target, via = button, "data"
                break
        if target is None:
            for button in flat:
                if (button.text or "") == data_or_label:
                    target, via = button, "label"
                    break
        if target is None:
            lowered = data_or_label.lower()
            for button in flat:
                if lowered in (button.text or "").lower():
                    target, via = button, "label_substring"
                    break
        if target is None:
            labels = [button.text for button in flat]
            raise RuntimeError(
                f"No button matching {data_or_label!r} on message {message_id}; "
                f"available labels: {labels}"
            )

        await target.click()

        return {
            "message_id": message_id,
            "clicked_label": target.text,
            "clicked_data": decoded_data(target),
            "matched_via": via,
        }

    # -- forum topic management (Bot API) -------------------------------------

    def create_topic(self, name):
        """Create a forum topic in the test group; returns the topic id."""
        result = bot_api_call(
            self.bot_api_token(),
            "createForumTopic",
            {"chat_id": int(self.group), "name": name},
        )
        return result["message_thread_id"]

    def delete_topic(self, topic_id):
        """Delete a forum topic (and its messages) in the test group."""
        bot_api_call(
            self.bot_api_token(),
            "deleteForumTopic",
            {"chat_id": int(self.group), "message_thread_id": int(topic_id)},
        )
        return True

    async def cleanup_topics(self, prefix, dry_run=False):
        """Delete every forum topic whose title starts with prefix.

        Topic listing needs the Telethon user session (the Bot API cannot
        enumerate topics), so call this inside `async with`. The General
        topic (id 1) is never touched. Prefix must be non-empty.
        """
        if not prefix:
            raise ValueError("cleanup_topics requires a non-empty prefix")

        entity = await self._entity("group")
        result = await self.client(
            GetForumTopicsRequest(
                peer=entity,
                offset_date=None,
                offset_id=0,
                offset_topic=0,
                limit=100,
            )
        )

        deleted = []
        failed = []
        for topic in getattr(result, "topics", None) or []:
            topic_id = getattr(topic, "id", None)
            title = getattr(topic, "title", "") or ""
            if topic_id in (None, 1) or not title.startswith(prefix):
                continue

            entry = {"topic_id": topic_id, "title": title}
            if dry_run:
                deleted.append(entry)
                continue

            try:
                self.delete_topic(topic_id)
                deleted.append(entry)
            except RuntimeError as exc:
                failed.append({**entry, "error": str(exc)})

        return {
            "prefix": prefix,
            "dry_run": dry_run,
            "deleted": deleted,
            "failed": failed,
        }


# --------------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------------


def build_parser():
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument(
        "--credentials",
        type=Path,
        default=None,
        help="Telethon credentials file (default: $LEMON_TELEGRAM_CREDS_PATH "
        "or ~/.zeebot/api_keys/telegram.txt)",
    )
    common.add_argument(
        "--group",
        default=None,
        help="Test group chat id (default: $LEMON_TELEGRAM_GROUP or the "
        "Lemonade Stand group)",
    )
    common.add_argument(
        "--bot",
        default=None,
        help="Bot username for DMs (default: $LEMON_TELEGRAM_BOT or "
        f"{DEFAULT_BOT})",
    )
    common.add_argument(
        "--repo-root",
        type=Path,
        default=None,
        help="Lemon repo root for the mix-based bot-token fallback",
    )
    common.add_argument("--json", action="store_true", help="Emit JSON result")

    chatty = argparse.ArgumentParser(add_help=False)
    chatty.add_argument(
        "--chat",
        default="group",
        help='Target chat: "group" (default), "bot" (DM), a username, or a numeric id',
    )
    chatty.add_argument("--topic-id", type=int, default=None, help="Forum topic id")

    waity = argparse.ArgumentParser(add_help=False)
    waity.add_argument("--timeout", type=float, default=90.0, help="Overall wait (s)")
    waity.add_argument(
        "--idle-timeout",
        type=float,
        default=15.0,
        help="Stop after this many idle seconds once at least one reply arrived",
    )
    waity.add_argument("--limit", type=int, default=50, help="Messages per poll")

    root = argparse.ArgumentParser(
        description="Composable Telegram conversation driver for lemon live testing."
    )
    sub = root.add_subparsers(dest="command", required=True)

    p = sub.add_parser("send", parents=[common, chatty], help="Send a message")
    p.add_argument("text", help="Message text")

    sub.add_parser(
        "await",
        parents=[common, chatty, waity],
        help="Await bot replies newer than --after-id",
    ).add_argument("--after-id", type=int, default=0, help="Only messages with id > this")

    p = sub.add_parser(
        "send-and-await",
        parents=[common, chatty, waity],
        help="Send a message and await bot replies to it",
    )
    p.add_argument("text", help="Message text")

    p = sub.add_parser(
        "press-button",
        parents=[common, chatty],
        help="Press an inline keyboard button by callback data or label",
    )
    p.add_argument("--message-id", type=int, required=True)
    p.add_argument("button", help="Callback data or button label (or label substring)")

    p = sub.add_parser("topic-create", parents=[common], help="Create a forum topic")
    p.add_argument("name", help="Topic name")

    p = sub.add_parser("topic-delete", parents=[common], help="Delete a forum topic")
    p.add_argument("topic_id", type=int, help="Topic id")

    p = sub.add_parser(
        "topic-cleanup",
        parents=[common],
        help="Delete all forum topics whose title starts with a prefix",
    )
    p.add_argument("prefix", help="Topic title prefix (non-empty)")
    p.add_argument("--dry-run", action="store_true", help="List matches, delete nothing")

    return root


def make_driver(args):
    return TelegramDriver(
        credentials_path=args.credentials,
        group=args.group,
        bot=args.bot,
        repo_root=args.repo_root,
    )


async def dispatch(args):
    driver = make_driver(args)

    if args.command == "topic-create":
        topic_id = driver.create_topic(args.name)
        return {"ok": True, "topic_id": topic_id, "name": args.name}

    if args.command == "topic-delete":
        driver.delete_topic(args.topic_id)
        return {"ok": True, "topic_id": args.topic_id, "deleted": True}

    async with driver:
        if args.command == "send":
            started = time.monotonic()
            sent_id = await driver.send(args.chat, args.text, topic_id=args.topic_id)
            return {
                "ok": True,
                "sent_id": sent_id,
                "chat": args.chat,
                "topic_id": args.topic_id,
                "elapsed_s": round(time.monotonic() - started, 2),
            }

        if args.command == "await":
            started = time.monotonic()
            replies = await driver.await_replies(
                args.chat,
                topic_id=args.topic_id,
                after_id=args.after_id,
                timeout=args.timeout,
                idle_timeout=args.idle_timeout,
                limit=args.limit,
            )
            return {
                "ok": bool(replies),
                "chat": args.chat,
                "topic_id": args.topic_id,
                "after_id": args.after_id,
                "reply_count": len(replies),
                "replies": replies,
                "elapsed_s": round(time.monotonic() - started, 2),
            }

        if args.command == "send-and-await":
            result = await driver.send_and_await(
                args.chat,
                args.text,
                topic_id=args.topic_id,
                timeout=args.timeout,
                idle_timeout=args.idle_timeout,
                limit=args.limit,
            )
            return {"ok": result["reply_count"] > 0, "chat": args.chat, **result}

        if args.command == "press-button":
            result = await driver.press_button(
                args.chat, message_id=args.message_id, data_or_label=args.button
            )
            return {"ok": True, "chat": args.chat, **result}

        if args.command == "topic-cleanup":
            result = await driver.cleanup_topics(args.prefix, dry_run=args.dry_run)
            return {"ok": not result["failed"], **result}

    raise RuntimeError(f"Unknown command: {args.command}")


def emit_human(result):
    replies = result.get("replies")
    scalars = {
        key: value
        for key, value in result.items()
        if key not in ("replies", "deleted", "failed")
    }
    print(" ".join(f"{key}={value}" for key, value in scalars.items()))

    for row in replies or []:
        print(f"--- message {row['id']} (reply_to={row['reply_to_msg_id']})")
        print(row["text"])
        for button in row.get("buttons") or []:
            print(f"  [button] label={button['text']!r} data={button['data']!r}")

    for entry in result.get("deleted") or []:
        print(f"deleted topic {entry['topic_id']}: {entry['title']}")
    for entry in result.get("failed") or []:
        print(f"FAILED topic {entry['topic_id']}: {entry['title']}: {entry['error']}")


def main(argv=None):
    args = build_parser().parse_args(argv)

    try:
        result = asyncio.run(dispatch(args))
    except (RuntimeError, ValueError, OSError) as exc:
        if args.json:
            print(json.dumps({"ok": False, "error": str(exc)}, ensure_ascii=False))
        else:
            print(f"error: {exc}", file=sys.stderr)
        raise SystemExit(2)
    except SystemExit as exc:
        # e.g. require_config: keep the documented contract (exit 2, JSON error)
        if exc.code in (None, 0):
            raise
        if args.json:
            print(json.dumps({"ok": False, "error": str(exc)}, ensure_ascii=False))
        else:
            print(f"error: {exc}", file=sys.stderr)
        raise SystemExit(2)

    if args.json:
        print(json.dumps(result, indent=2, ensure_ascii=False))
    else:
        emit_human(result)

    raise SystemExit(0 if result.get("ok") else 1)


if __name__ == "__main__":
    main()
