#!/usr/bin/env -S uv run
# /// script
# dependencies = ["telethon>=1.41,<2"]
# ///

import argparse
import asyncio
import json
import os
import time
from pathlib import Path

from telethon import TelegramClient
from telethon.tl.types import MessageEntityBold, MessageEntityPre
from telethon.sessions import StringSession


DEFAULT_CREDENTIALS = Path.home() / ".zeebot/api_keys/telegram.txt"
DEFAULT_BOT = "zeebot_lemon_bot"
DEFAULT_GROUP = "-1003842984060"
DEFAULT_TOPIC = 35
DEFAULT_ISOLATION_TOPICS = [35, 16456]


def load_env(path):
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


async def wait_for_reply(
    client,
    peer,
    sent_id,
    nonce,
    timeout_s,
    expected_topic_id=None,
    expected_text=None,
):
    deadline = time.time() + timeout_s
    last_rows = []

    while time.time() < deadline:
        last_rows = []

        async for msg in client.iter_messages(peer, limit=40):
            row = message_row(msg)
            last_rows.append(row)

            if row["out"]:
                continue

            if row["reply_to_msg_id"] != sent_id and nonce not in row["text"]:
                continue

            if row["text"].startswith("Running"):
                continue

            if not row_in_topic(row, expected_topic_id):
                continue

            if expected_text is not None and row["text"] != expected_text:
                continue

            return row

        await asyncio.sleep(2)

    return {"error": "timeout", "recent": last_rows[:10]}


async def collect_matching_messages(client, peer, sent_ids, nonce, limit=80, expected_topic_id=None):
    rows = []
    sent_ids = set(sent_ids if isinstance(sent_ids, list) else [sent_ids])

    async for msg in client.iter_messages(peer, limit=limit):
        row = message_row(msg)

        if not row_in_topic(row, expected_topic_id):
            continue

        if row["reply_to_msg_id"] in sent_ids or nonce in row["text"]:
            rows.append(row)

    return rows


async def run_dm(client, bot, timeout_s):
    nonce = f"lemon-dm-{int(time.time())}"
    prompt = f"{nonce} DM matrix probe: reply with exactly OK {nonce}"
    sent = await client.send_message(bot, prompt)
    expected = f"OK {nonce}"
    reply = await wait_for_reply(client, bot, sent.id, nonce, timeout_s, expected_text=expected)

    ok = reply.get("text") == expected

    return {
        "name": "telegram_dm_prompt_round_trip",
        "ok": ok,
        "nonce": nonce,
        "sent_id": sent.id,
        "reply": reply,
    }


async def run_topic(client, group, topic_id, timeout_s):
    nonce = f"lemon-topic-{topic_id}-{int(time.time())}"
    prompt = f"{nonce} topic matrix probe: reply with exactly OK {nonce}"
    sent = await client.send_message(group, prompt, reply_to=topic_id)
    expected = f"OK {nonce}"
    reply = await wait_for_reply(client, group, sent.id, nonce, timeout_s, topic_id, expected)

    ok = reply.get("text") == expected and reply.get("reply_to_top_id") == topic_id

    return {
        "name": "telegram_forum_topic_prompt_round_trip",
        "ok": ok,
        "topic_id": topic_id,
        "nonce": nonce,
        "sent_id": sent.id,
        "reply": reply,
    }


async def run_topic_cancel(client, group, topic_id, timeout_s):
    nonce = f"lemon-cancel-{topic_id}-{int(time.time())}"
    success_text = f"OK {nonce}"
    prompt = (
        f"{nonce} cancellation probe: use bash to run "
        f"`sleep 60 && echo {success_text}`. Do not reply until the command finishes."
    )

    sent = await client.send_message(group, prompt, reply_to=topic_id)
    await asyncio.sleep(6)
    cancel = await client.send_message(group, "/cancel", reply_to=topic_id)

    deadline = time.time() + timeout_s
    cancel_ack = None
    matched = []

    while time.time() < deadline:
        matched = await collect_matching_messages(
            client,
            group,
            [sent.id, cancel.id],
            nonce,
            expected_topic_id=topic_id,
        )

        for row in matched:
            text = row["text"].lower()

            if "cancelling current run" in text or "cancelled" in text or "canceled" in text:
                cancel_ack = row

        successful_completion_seen = [
            row
            for row in matched
            if row["text"] == success_text
            or (row["text"].startswith("working") and "\n✓ sleep 60" in row["text"])
        ]

        if cancel_ack and not successful_completion_seen and time.time() >= deadline - min(timeout_s, 15):
            break

        await asyncio.sleep(2)

    successful_completion_seen = [
        row
        for row in matched
        if row["text"] == success_text
        or (row["text"].startswith("working") and "\n✓ sleep 60" in row["text"])
    ]
    command_started = any("sleep 60" in row["text"] for row in matched)
    cancelled_or_failed = any(
        "run failed: user_requested" in row["text"].lower()
        or (row["text"].startswith("working") and "\n✗ sleep 60" in row["text"])
        for row in matched
    )

    ok = (
        cancel_ack is not None
        and successful_completion_seen == []
        and command_started
        and cancelled_or_failed
    )

    return {
        "name": "telegram_forum_topic_cancel",
        "ok": ok,
        "topic_id": topic_id,
        "nonce": nonce,
        "sent_id": sent.id,
        "cancel_id": cancel.id,
        "cancel_ack": cancel_ack,
        "command_started": command_started,
        "cancelled_or_failed": cancelled_or_failed,
        "successful_completion_seen": successful_completion_seen,
        "matched": matched[:8],
    }


async def run_topic_tool_success(client, group, topic_id, timeout_s):
    nonce = f"lemon-tool-ok-{topic_id}-{int(time.time())}"
    expected = f"OK {nonce}"
    command = f"echo {expected}"
    prompt = (
        f"{nonce} tool success rendering probe: use bash to run "
        f"`{command}`, then reply with exactly {expected}"
    )

    sent = await client.send_message(group, prompt, reply_to=topic_id)
    reply = await wait_for_reply(client, group, sent.id, nonce, timeout_s, topic_id, expected)
    matched = await collect_matching_messages(client, group, sent.id, nonce, expected_topic_id=topic_id)
    tool_success_seen = any(
        row["text"].startswith("working")
        and "\n✓ echo" in row["text"]
        and expected in row["text"]
        for row in matched
    )

    return {
        "name": "telegram_forum_topic_tool_success_rendering",
        "ok": reply.get("text") == expected and tool_success_seen,
        "topic_id": topic_id,
        "nonce": nonce,
        "sent_id": sent.id,
        "reply": reply,
        "tool_success_seen": tool_success_seen,
        "matched": matched[:8],
    }


async def run_topic_tool_failure(client, group, topic_id, timeout_s):
    nonce = f"lemon-tool-fail-{topic_id}-{int(time.time())}"
    expected = f"FAILED {nonce}"
    command = f"sh -c 'echo FAIL {nonce} >&2; exit 7'"
    prompt = (
        f"{nonce} tool failure rendering probe: use bash to run "
        f"`{command}`, then reply with exactly {expected}"
    )

    sent = await client.send_message(group, prompt, reply_to=topic_id)
    reply = await wait_for_reply(client, group, sent.id, nonce, timeout_s, topic_id, expected)
    matched = await collect_matching_messages(client, group, sent.id, nonce, expected_topic_id=topic_id)
    tool_failure_seen = any(
        row["text"].startswith("working")
        and "\n✗ sh -c" in row["text"]
        and nonce in row["text"]
        for row in matched
    )

    return {
        "name": "telegram_forum_topic_tool_failure_rendering",
        "ok": reply.get("text") == expected and tool_failure_seen,
        "topic_id": topic_id,
        "nonce": nonce,
        "sent_id": sent.id,
        "reply": reply,
        "tool_failure_seen": tool_failure_seen,
        "matched": matched[:8],
    }


async def run_topic_markdown(client, group, topic_id, timeout_s):
    nonce = f"lemon-markdown-{topic_id}-{int(time.time())}"
    prompt = (
        f"{nonce} markdown rendering probe: do not use tools. Reply with a bold "
        f"word containing {nonce} and a fenced text code block containing code-{nonce}."
    )

    sent = await client.send_message(group, prompt, reply_to=topic_id)
    reply = await wait_for_reply(client, group, sent.id, nonce, timeout_s, topic_id)
    entity_set = set(reply.get("entity_types") or [])
    ok = (
        nonce in reply.get("text", "")
        and f"code-{nonce}" in reply.get("text", "")
        and MessageEntityBold.__name__ in entity_set
        and MessageEntityPre.__name__ in entity_set
    )

    return {
        "name": "telegram_forum_topic_markdown_code_rendering",
        "ok": ok,
        "topic_id": topic_id,
        "nonce": nonce,
        "sent_id": sent.id,
        "reply": reply,
    }


async def run_topic_approval(client, group, topic_id, timeout_s):
    nonce = f"lemon-approval-{topic_id}-{int(time.time())}"
    expected = f"APPROVED {nonce}"
    command = f"echo {expected}"
    prompt = (
        f"{nonce} approval rendering probe: use bash to run "
        f"`{command}`, approve when asked, then reply with exactly {expected}"
    )

    sent = await client.send_message(group, prompt, reply_to=topic_id)
    deadline = time.time() + timeout_s
    approval_msg = None

    while time.time() < deadline:
        matched = await collect_matching_messages(
            client,
            group,
            sent.id,
            nonce,
            expected_topic_id=topic_id,
        )

        approval_msg = next(
            (
                row
                for row in matched
                if row["text"].startswith("Approval requested: bash")
                and "Approve once" not in row["text"]
            ),
            None,
        )

        if approval_msg:
            break

        await asyncio.sleep(2)

    if not approval_msg:
        return {
            "name": "telegram_forum_topic_approval_once",
            "ok": False,
            "topic_id": topic_id,
            "nonce": nonce,
            "sent_id": sent.id,
            "error": "approval prompt not observed",
            "matched": matched[:8] if "matched" in locals() else [],
        }

    message = await client.get_messages(group, ids=approval_msg["id"])
    await message.click(text="Approve once")

    reply = await wait_for_reply(client, group, sent.id, nonce, timeout_s, topic_id, expected)
    matched = await collect_matching_messages(client, group, sent.id, nonce, expected_topic_id=topic_id)
    edited_approval = await client.get_messages(group, ids=approval_msg["id"])
    approval_recorded = (edited_approval.raw_text or "") == "Approval: approve once"
    tool_success_seen = any(
        row["text"].startswith("working")
        and "\n✓ echo" in row["text"]
        and expected in row["text"]
        for row in matched
    )

    return {
        "name": "telegram_forum_topic_approval_once",
        "ok": reply.get("text") == expected and approval_recorded and tool_success_seen,
        "topic_id": topic_id,
        "nonce": nonce,
        "sent_id": sent.id,
        "approval_id": approval_msg["id"],
        "reply": reply,
        "approval_recorded": approval_recorded,
        "tool_success_seen": tool_success_seen,
        "matched": matched[:8],
    }


async def run_topic_long_output(client, group, topic_id, timeout_s):
    nonce = f"lemon-long-{topic_id}-{int(time.time())}"
    line_a = f"{nonce} A " + ("alpha " * 520)
    line_b = f"{nonce} B " + ("bravo " * 520)
    line_c = f"{nonce} C " + ("charlie " * 360) + f" END {nonce}"
    prompts = [
        f"/echo {nonce} long-output probe part 1:\n{line_a}",
        f"/echo {nonce} long-output probe part 2:\n{line_b}",
        f"/echo {nonce} long-output probe part 3:\n{line_c}",
    ]

    sent = []
    for prompt in prompts:
        msg = await client.send_message(group, prompt, reply_to=topic_id)
        sent.append(msg.id)

    deadline = time.time() + timeout_s
    matched = []
    answer_rows = []
    combined = ""

    while time.time() < deadline:
        matched = await collect_matching_messages(
            client,
            group,
            sent,
            nonce,
            limit=120,
            expected_topic_id=topic_id,
        )
        answer_rows = [
            row
            for row in matched
            if (
                not row["out"]
                and not row["text"].startswith("Running")
                and nonce in row["text"]
            )
        ]
        answer_rows = sorted(answer_rows, key=lambda row: row["id"])
        combined = "\n".join(row["text"] for row in answer_rows)

        if f"END {nonce}" in combined and len(combined) > 4500 and len(answer_rows) >= 2:
            break

        await asyncio.sleep(2)

    chunk_lengths = [len(row["text"]) for row in answer_rows]
    first_replies_to_prompt = bool(answer_rows) and answer_rows[0].get("reply_to_msg_id") in sent
    followups_in_topic = all(row_in_topic(row, topic_id) for row in answer_rows)
    ok = (
        f"END {nonce}" in combined
        and len(combined) > 4500
        and len(answer_rows) >= 2
        and first_replies_to_prompt
        and followups_in_topic
        and all(length <= 4096 for length in chunk_lengths)
    )

    return {
        "name": "telegram_forum_topic_long_output_chunking",
        "ok": ok,
        "topic_id": topic_id,
        "nonce": nonce,
        "sent_ids": sent,
        "chunk_count": len(answer_rows),
        "chunk_lengths": chunk_lengths,
        "first_replies_to_prompt": first_replies_to_prompt,
        "followups_in_topic": followups_in_topic,
        "saw_end_marker": f"END {nonce}" in combined,
        "combined_length": len(combined),
        "matched": matched[:10],
    }


async def run_topic_file_get(client, group, topic_id, timeout_s, workdir):
    nonce = f"lemon-file-{topic_id}-{int(time.time())}"
    proof_dir = Path(workdir) / "tmp"
    proof_dir.mkdir(parents=True, exist_ok=True)
    filename = f"telegram-proof-{nonce}.txt"
    rel_path = f"tmp/{filename}"
    proof_path = Path(workdir) / rel_path
    proof_path.write_text(f"{nonce}\ntelegram file proof\n", encoding="utf-8")

    sent = await client.send_message(group, f"/file get {rel_path}", reply_to=topic_id)
    deadline = time.time() + timeout_s
    matched = []
    document = None

    try:
        while time.time() < deadline:
            matched = await collect_matching_messages(
                client,
                group,
                sent.id,
                filename,
                limit=80,
                expected_topic_id=topic_id,
            )

            document = next(
                (
                    row
                    for row in matched
                    if not row["out"]
                    and row["has_document"]
                    and row["file_name"] == filename
                    and row["reply_to_msg_id"] == sent.id
                ),
                None,
            )

            if document:
                break

            await asyncio.sleep(2)
    finally:
        try:
            proof_path.unlink()
        except FileNotFoundError:
            pass

    return {
        "name": "telegram_forum_topic_file_get_document",
        "ok": document is not None and row_in_topic(document, topic_id),
        "topic_id": topic_id,
        "nonce": nonce,
        "sent_id": sent.id,
        "rel_path": rel_path,
        "document": document,
        "matched": matched[:8],
    }


async def run_topic_restart_seed(client, group, topic_id, timeout_s):
    nonce = f"lemon-restart-seed-{topic_id}-{int(time.time())}"
    prompt = f"/echo {nonce} restart dedupe seed"
    sent = await client.send_message(group, prompt, reply_to=topic_id)
    reply = await wait_for_reply(client, group, sent.id, nonce, timeout_s, topic_id)

    ok = (
        nonce in reply.get("text", "")
        and reply.get("reply_to_msg_id") == sent.id
        and row_in_topic(reply, topic_id)
    )

    return {
        "name": "telegram_forum_topic_restart_seed",
        "ok": ok,
        "topic_id": topic_id,
        "nonce": nonce,
        "sent_id": sent.id,
        "reply": reply,
        "reply_id": reply.get("id") if ok else None,
    }


async def run_topic_restart_verify(
    client,
    group,
    topic_id,
    timeout_s,
    restart_nonce,
    restart_reply_id,
):
    deadline = time.time() + timeout_s
    duplicates = []
    matched = []

    while time.time() < deadline:
        matched = await collect_matching_messages(
            client,
            group,
            [],
            restart_nonce,
            limit=120,
            expected_topic_id=topic_id,
        )

        duplicates = [
            row
            for row in matched
            if not row["out"]
            and row["id"] != restart_reply_id
            and (restart_reply_id is None or row["id"] > restart_reply_id)
        ]

        if duplicates:
            break

        await asyncio.sleep(2)

    fresh_nonce = f"lemon-restart-after-{topic_id}-{int(time.time())}"
    fresh_prompt = f"/echo {fresh_nonce} post restart prompt"
    sent = await client.send_message(group, fresh_prompt, reply_to=topic_id)
    fresh_reply = await wait_for_reply(client, group, sent.id, fresh_nonce, timeout_s, topic_id)
    fresh_ok = (
        fresh_nonce in fresh_reply.get("text", "")
        and fresh_reply.get("reply_to_msg_id") == sent.id
        and row_in_topic(fresh_reply, topic_id)
    )

    return {
        "name": "telegram_forum_topic_restart_dedupe",
        "ok": duplicates == [] and fresh_ok,
        "topic_id": topic_id,
        "restart_nonce": restart_nonce,
        "restart_reply_id": restart_reply_id,
        "duplicates": duplicates,
        "fresh_nonce": fresh_nonce,
        "fresh_sent_id": sent.id,
        "fresh_reply": fresh_reply,
        "matched": matched[:8],
    }


async def run_topic_isolation(client, group, topic_ids, timeout_s):
    if len(topic_ids) < 2:
        return {
            "name": "telegram_forum_topic_isolation",
            "ok": False,
            "error": "requires at least two topic ids",
            "topic_ids": topic_ids,
        }

    started_at = int(time.time())
    sent = []

    for topic_id in topic_ids:
        nonce = f"lemon-isolate-{topic_id}-{started_at}"
        prompt = (
            f"{nonce} topic isolation probe: use bash to run "
            f"`sleep 6 && echo OK {nonce}`, then reply with exactly OK {nonce}"
        )
        message = await client.send_message(group, prompt, reply_to=topic_id)
        sent.append({"topic_id": topic_id, "nonce": nonce, "sent_id": message.id})

    replies = []

    for item in sent:
        reply = await wait_for_reply(
            client,
            group,
            item["sent_id"],
            item["nonce"],
            timeout_s,
            item["topic_id"],
            f"OK {item['nonce']}",
        )
        replies.append({**item, "reply": reply})

    ok = all(
        item["reply"].get("text") == f"OK {item['nonce']}"
        and item["reply"].get("reply_to_msg_id") == item["sent_id"]
        and item["reply"].get("reply_to_top_id") == item["topic_id"]
        for item in replies
    )

    return {
        "name": "telegram_forum_topic_isolation",
        "ok": ok,
        "topic_ids": topic_ids,
        "replies": replies,
    }


async def run(args):
    cfg = load_env(args.credentials)
    require_config(cfg, args.credentials)

    client = build_client(cfg)

    async with client:
        if not await client.is_user_authorized():
            raise SystemExit("Telegram session is not authorized.")

        bot = await client.get_entity(args.bot)
        group = await client.get_entity(int(args.group))

        checks = []

        if not args.skip_dm:
            checks.append(await run_dm(client, bot, args.timeout))

        topic_ids = args.topic_id or [DEFAULT_TOPIC]

        if not args.skip_topic:
            for topic_id in topic_ids:
                checks.append(await run_topic(client, group, topic_id, args.timeout))

        if args.topic_isolation:
            isolation_topic_ids = args.isolation_topic_id or DEFAULT_ISOLATION_TOPICS
            checks.append(
                await run_topic_isolation(client, group, isolation_topic_ids, args.timeout)
            )

        if args.topic_cancel:
            checks.append(await run_topic_cancel(client, group, args.cancel_topic_id, args.timeout))

        if args.topic_tool_rendering:
            checks.append(await run_topic_tool_success(client, group, args.tool_topic_id, args.timeout))
            checks.append(await run_topic_tool_failure(client, group, args.tool_topic_id, args.timeout))

        if args.topic_markdown:
            checks.append(await run_topic_markdown(client, group, args.markdown_topic_id, args.timeout))

        if args.topic_approval:
            checks.append(await run_topic_approval(client, group, args.approval_topic_id, args.timeout))

        if args.topic_long_output:
            checks.append(
                await run_topic_long_output(client, group, args.long_output_topic_id, args.timeout)
            )

        if args.topic_file_get:
            checks.append(
                await run_topic_file_get(
                    client,
                    group,
                    args.file_get_topic_id,
                    args.timeout,
                    args.workdir,
                )
            )

        if args.topic_restart_seed:
            checks.append(
                await run_topic_restart_seed(
                    client,
                    group,
                    args.restart_topic_id,
                    args.timeout,
                )
            )

        if args.topic_restart_verify:
            if not args.restart_nonce:
                raise SystemExit("--restart-nonce is required with --topic-restart-verify")

            checks.append(
                await run_topic_restart_verify(
                    client,
                    group,
                    args.restart_topic_id,
                    args.timeout,
                    args.restart_nonce,
                    args.restart_reply_id,
                )
            )

    return {
        "ok": all(check["ok"] for check in checks),
        "bot": args.bot,
        "group": args.group,
        "checks": checks,
    }


def parser():
    root = argparse.ArgumentParser(description="Run Lemon live Telegram channel checks.")
    root.add_argument("--credentials", type=Path, default=Path(os.environ.get("LEMON_TELEGRAM_CREDS_PATH", DEFAULT_CREDENTIALS)))
    root.add_argument("--bot", default=DEFAULT_BOT)
    root.add_argument("--group", default=DEFAULT_GROUP)
    root.add_argument("--topic-id", action="append", type=int)
    root.add_argument("--skip-topic", action="store_true")
    root.add_argument("--topic-isolation", action="store_true")
    root.add_argument("--isolation-topic-id", action="append", type=int)
    root.add_argument("--topic-cancel", action="store_true")
    root.add_argument("--cancel-topic-id", type=int, default=DEFAULT_TOPIC)
    root.add_argument("--topic-tool-rendering", action="store_true")
    root.add_argument("--tool-topic-id", type=int, default=DEFAULT_TOPIC)
    root.add_argument("--topic-markdown", action="store_true")
    root.add_argument("--markdown-topic-id", type=int, default=DEFAULT_TOPIC)
    root.add_argument("--topic-approval", action="store_true")
    root.add_argument("--approval-topic-id", type=int, default=DEFAULT_TOPIC)
    root.add_argument("--topic-long-output", action="store_true")
    root.add_argument("--long-output-topic-id", type=int, default=DEFAULT_TOPIC)
    root.add_argument("--topic-file-get", action="store_true")
    root.add_argument("--file-get-topic-id", type=int, default=DEFAULT_TOPIC)
    root.add_argument("--workdir", type=Path, default=Path.cwd())
    root.add_argument("--topic-restart-seed", action="store_true")
    root.add_argument("--topic-restart-verify", action="store_true")
    root.add_argument("--restart-topic-id", type=int, default=DEFAULT_TOPIC)
    root.add_argument("--restart-nonce")
    root.add_argument("--restart-reply-id", type=int)
    root.add_argument("--timeout", type=int, default=90)
    root.add_argument("--skip-dm", action="store_true")
    return root


def main():
    args = parser().parse_args()
    result = asyncio.run(run(args))
    print(json.dumps(result, indent=2, ensure_ascii=False))
    raise SystemExit(0 if result["ok"] else 1)


if __name__ == "__main__":
    main()
