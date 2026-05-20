#!/usr/bin/env -S uv run
# /// script
# dependencies = ["websockets>=12.0"]
# ///

import argparse
import asyncio
from datetime import datetime, timezone
import json
import os
import subprocess
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from pathlib import Path


DEFAULT_CREDENTIALS = Path.home() / ".zeebot/api_keys/discord.txt"
DEFAULT_GUILD_ID = "1475727416549969980"
DEFAULT_CONTROL_PLANE_WS_URL = "ws://127.0.0.1:4040/ws"
DEFAULT_SLASH_CLIENT_CLICK_PROOF = Path(".lemon/proofs/discord-slash-client-click-proof-latest.json")
API_BASE = "https://discord.com/api/v10"
BOT_TOKEN_KEYS = {"bot_token", "discord_bot_token", "discord_bot", "bot", "token"}
GATEWAY_MESSAGE_CONTENT = 1 << 18
GATEWAY_MESSAGE_CONTENT_LIMITED = 1 << 19


class Check:
    def __init__(self, run, sender, peer_kind="group", channel_id=None):
        self.run = run
        self.sender = sender
        self.peer_kind = peer_kind
        self.channel_id = channel_id

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


def application_identity(token):
    app = api(token, "GET", "/oauth2/applications/@me")
    flags = application_flags(app)

    return {
        "id": app.get("id"),
        "name": app.get("name"),
        "bot_public": app.get("bot_public"),
        "flags_present": flags is not None,
        "message_content_intent_enabled": message_content_intent_enabled(flags),
    }


def application_flags(app):
    for key in ("flags_new", "flags"):
        value = app.get(key)

        if value is None:
            continue

        try:
            return int(value)
        except (TypeError, ValueError):
            continue

    return None


def message_content_intent_enabled(flags):
    if flags is None:
        return None

    return bool(flags & (GATEWAY_MESSAGE_CONTENT | GATEWAY_MESSAGE_CONTENT_LIMITED))


def list_global_commands(token, application_id):
    return api(token, "GET", f"/applications/{application_id}/commands")


def register_global_command(token, application_id, command):
    return api(token, "POST", f"/applications/{application_id}/commands", command)


def local_kanban_command_schema():
    return local_command_schema("kanban")


def local_checkpoint_command_schema():
    return local_command_schema("checkpoint")


def local_rollback_command_schema():
    return local_command_schema("rollback")


def local_media_command_schema():
    return local_command_schema("media")


def local_slash_command_names():
    return local_mix_json(
        "LEMON_DISCORD_SLASH_NAMES_JSON",
        "IO.puts(\"LEMON_DISCORD_SLASH_NAMES_JSON:\" <> Jason.encode!(Enum.map(LemonChannels.Adapters.Discord.Transport.slash_commands(), & &1.name)))",
        "slash command names",
    )


def local_command_schema(name):
    return local_mix_json(
        f"LEMON_DISCORD_{name.upper()}_COMMAND_JSON",
        f"IO.puts(\"LEMON_DISCORD_{name.upper()}_COMMAND_JSON:\" <> Jason.encode!(LemonChannels.Adapters.Discord.Transport.{name}_command_schema()))",
        f"{name} command schema",
    )


def run_slash_client_click_proof_check(path):
    proof_path = Path(path)

    check = {
        "name": "discord_slash_client_click_proof_artifact",
        "ok": False,
        "proof_scope": "Discord slash client-click proof artifact",
        "proof_object": "lemon.discord_slash_client_click",
        "proof_path_exists": proof_path.exists(),
        "file_hash": safe_hash(str(proof_path.resolve())),
    }

    if not proof_path.exists():
        check["reason_kind"] = "discord_slash_client_click_missing"
        check["failure_hint"] = (
            "No Discord slash client-click proof artifact found. Deploy or hot reload "
            "the runtime, click a real slash command in Discord, then rerun this check."
        )
        return check

    try:
        proof = json.loads(proof_path.read_text())
    except Exception:
        check["reason_kind"] = "discord_slash_client_click_invalid_artifact"
        check["failure_hint"] = "Discord slash client-click proof artifact is not valid JSON."
        return check

    coverage = proof.get("coverage") if isinstance(proof.get("coverage"), dict) else {}
    checks = proof.get("checks") if isinstance(proof.get("checks"), list) else []
    check_names = [row.get("name") for row in checks if isinstance(row, dict)]
    cleanup = proof.get("cleanup") if isinstance(proof.get("cleanup"), dict) else {}
    status = proof.get("status")

    required_cleanup = [
        "includes_raw_bot_tokens",
        "includes_raw_interaction_tokens",
        "includes_raw_application_ids",
        "includes_raw_channel_ids",
        "includes_raw_user_ids",
        "includes_raw_message_bodies",
    ]

    missing_cleanup = [key for key in required_cleanup if cleanup.get(key) is not False]
    real_client_click = coverage.get("real_client_click_proof") is True
    observed = "discord_slash_client_click_observed" in check_names
    safe_mentions = "discord_slash_client_click_safe_mentions" in check_names

    check.update(
        {
            "status": status,
            "proof_hash": safe_hash(json.dumps(proof, sort_keys=True)),
            "generated_at": proof.get("generated_at"),
            "coverage": {
                "registered_command_count": coverage.get("registered_command_count"),
                "client_click_command_count": coverage.get("client_click_command_count"),
                "real_client_click_proof": coverage.get("real_client_click_proof"),
            },
            "observed_check_present": observed,
            "safe_mentions_check_present": safe_mentions,
            "cleanup_ok": missing_cleanup == [],
        }
    )

    check["ok"] = (
        proof.get("proof_object") == "lemon.discord_slash_client_click"
        and status == "completed"
        and real_client_click
        and observed
        and safe_mentions
        and missing_cleanup == []
    )

    if not check["ok"]:
        check["reason_kind"] = "discord_slash_client_click_not_promotable"
        check["failure_hint"] = (
            "Discord slash client-click proof exists but is not promotable. "
            "Expected completed lemon.discord_slash_client_click proof with "
            "real_client_click_proof=true, observed/safe-mention checks, and redaction cleanup flags."
        )

    return check


def run_slash_client_click_proof_wait(args, token, identity):
    started_at = datetime.now(timezone.utc)
    started_iso = started_at.isoformat().replace("+00:00", "Z")
    nonce = f"lemon-discord-slash-click-{int(time.time())}"
    instruction = (
        f"Operator proof request {nonce}: click `{args.slash_client_click_command}` "
        "in Discord, then wait for Lemon to respond. The proof watcher will only "
        "accept a redacted client-click artifact generated after this request started."
    )

    if not args.skip_slash_client_click_instruction and args.channel_id:
        sent = send_message(token, args.channel_id, instruction)
        print(
            json.dumps(
                {
                    "action": "sent_slash_client_click_instruction",
                    "channel_id": args.channel_id,
                    "message_id": sent.get("id"),
                    "nonce": nonce,
                    "expected_operator_action": args.slash_client_click_command,
                },
                indent=2,
            ),
            flush=True,
        )
    else:
        print(
            json.dumps(
                {
                    "action_required": "click_discord_slash_command",
                    "channel_id": args.channel_id,
                    "nonce": nonce,
                    "expected_operator_action": args.slash_client_click_command,
                },
                indent=2,
            ),
            flush=True,
        )

    deadline = time.time() + args.timeout
    last_check = None

    while time.time() < deadline:
        check = run_slash_client_click_proof_check(args.slash_client_click_proof_path)
        check["name"] = "discord_slash_client_click_proof_wait"
        check["proof_scope"] = "Discord slash client-click proof wait"
        check["wait_started_at"] = started_iso
        check["recommended_command"] = args.slash_client_click_command
        check["nonce"] = nonce

        if check.get("ok") and proof_generated_after(check.get("generated_at"), started_at):
            check["fresh_after_wait_started"] = True
            return check

        if check.get("ok"):
            check["ok"] = False
            check["reason_kind"] = "discord_slash_client_click_stale"
            check["failure_hint"] = (
                "A promotable Discord slash client-click proof exists, but it was "
                "generated before this wait started. Click a real slash command again "
                "while this watcher is running."
            )

        last_check = check
        time.sleep(2)

    if last_check is None:
        last_check = {
            "name": "discord_slash_client_click_proof_wait",
            "ok": False,
            "proof_scope": "Discord slash client-click proof wait",
        }

    last_check["ok"] = False
    last_check.setdefault("reason_kind", "discord_slash_client_click_missing")
    last_check["failure_hint"] = (
        "Timed out waiting for a fresh Discord slash client-click proof. "
        "Click a real slash command in Discord while this watcher is running, "
        "then rerun the watcher or the one-shot proof check."
    )
    last_check["wait_started_at"] = started_iso
    last_check["recommended_command"] = args.slash_client_click_command
    last_check["nonce"] = nonce
    return last_check


def proof_generated_after(generated_at, started_at):
    generated = parse_iso8601(generated_at)

    if generated is None:
        return False

    return generated >= started_at


def parse_iso8601(value):
    if not isinstance(value, str):
        return None

    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00")).astimezone(timezone.utc)
    except ValueError:
        return None


def safe_hash(value):
    import hashlib

    return hashlib.sha256(str(value).encode()).hexdigest()[:16]


def now_iso():
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def sanitized_live_proof(result):
    checks = [sanitized_check(check) for check in result.get("checks", [])]
    completed_count = sum(1 for check in checks if check["status"] == "completed")
    failed_count = sum(1 for check in checks if check["status"] == "failed")

    return {
        "generated_at": now_iso(),
        "status": "completed" if failed_count == 0 else "failed",
        "proof": "discord_live_matrix",
        "proof_object": "lemon.discord_live_matrix",
        "proof_scope": "discord_live_matrix",
        "checks": checks,
        "completed_count": completed_count,
        "failed_count": failed_count,
        "skipped_count": 0,
        "reason_kind": sanitized_proof_reason_kind(checks),
        "coverage": sanitized_coverage(result, checks),
        "cleanup": {
            "includes_raw_bot_tokens": False,
            "includes_raw_interaction_tokens": False,
            "includes_raw_application_ids": False,
            "includes_raw_channel_ids": False,
            "includes_raw_user_ids": False,
            "includes_raw_message_bodies": False,
            "includes_secret_names": False,
        },
    }


def sanitized_proof_reason_kind(checks):
    for check in checks:
        if check.get("status") == "failed" and check.get("reason_kind"):
            return check["reason_kind"]

    return None


def sanitized_coverage(result, checks):
    names = [check["name"] for check in checks]

    return {
        "check_count": len(checks),
        "bot_to_bot_sender": result.get("sender", {}).get("kind") == "bot_to_bot",
        "non_bot_user_sender": result.get("sender", {}).get("kind") == "non_bot_user",
        "contains_restart_seed": "discord_restart_replay_seed" in names,
        "contains_restart_verify": "discord_restart_replay_verify" in names,
        "contains_free_response": "discord_free_response_trigger_round_trip" in names,
        "contains_dm": "discord_dm_prompt_round_trip" in names,
        "contains_thread": "discord_thread_prompt_round_trip" in names,
        "contains_generated_media": "discord_generated_media_delivery" in names,
        "contains_generated_audio": "discord_generated_audio_delivery" in names,
        "contains_media_directive": "discord_media_directive_delivery" in names,
        "contains_file_delivery": "discord_file_delivery" in names,
        "contains_slash_registration": any(
            name.endswith("_slash_registration") or name == "discord_all_slash_registration"
            for name in names
        ),
        "contains_kanban_slash_registration": "discord_kanban_slash_registration" in names,
        "contains_checkpoint_slash_registration": "discord_checkpoint_slash_registration"
        in names,
        "contains_rollback_slash_registration": "discord_rollback_slash_registration"
        in names,
        "contains_media_slash_registration": "discord_media_slash_registration" in names,
        "contains_all_slash_registration": "discord_all_slash_registration" in names,
        "contains_slash_client_click": any(
            name in {"discord_slash_client_click_proof_artifact", "discord_slash_client_click_proof_wait"}
            for name in names
        ),
    }


def sanitized_check(check):
    status = "completed" if check.get("ok") else "failed"
    sanitized = {
        "name": check.get("name") or "discord_live_matrix_check",
        "status": status,
        "proof_scope": safe_scope(check.get("proof_scope") or check.get("name")),
    }

    for key in [
        "failure_hint",
        "manual_runtime_restart_required",
        "duplicate_window_s",
    ]:
        if key in check:
            sanitized[key] = check[key]

    reason_kind = reason_kind_for(check)
    if reason_kind:
        sanitized["reason_kind"] = reason_kind

    if check.get("nonce"):
        sanitized["nonce_hash"] = safe_hash(check["nonce"])

    if check.get("channel_id"):
        sanitized["channel_hash"] = safe_hash(check["channel_id"])

    if check.get("restart_nonce"):
        sanitized["restart_nonce_hash"] = safe_hash(check["restart_nonce"])

    if check.get("restart_reply_id"):
        sanitized["restart_reply_hash"] = safe_hash(check["restart_reply_id"])

    if check.get("thread"):
        sanitized["thread_hash"] = safe_hash((check["thread"] or {}).get("id"))

    if check.get("sender_proof"):
        sanitized["sender"] = sanitized_sender(check["sender_proof"])

    if check.get("local_channel_diagnostics"):
        sanitized["local_channel_diagnostics"] = sanitized_channel_diagnostics(
            check["local_channel_diagnostics"]
        )

    if check.get("application_intents"):
        sanitized["application_intents"] = sanitized_application_intents(
            check["application_intents"]
        )

    if check.get("recommended_command"):
        sanitized["recommended_command"] = check["recommended_command"]

    if check.get("fresh_after_wait_started") is not None:
        sanitized["fresh_after_wait_started"] = check.get("fresh_after_wait_started")

    bot_reply = check.get("bot_reply")
    if isinstance(bot_reply, dict) and bot_reply.get("attachment_count") is not None:
        sanitized["attachment_count"] = bot_reply.get("attachment_count")
    if isinstance(bot_reply, dict) and bot_reply.get("directive_leaked") is not None:
        sanitized["directive_leaked"] = bot_reply.get("directive_leaked")
    if isinstance(bot_reply, dict) and bot_reply.get("marker_seen") is not None:
        sanitized["marker_seen"] = bot_reply.get("marker_seen")

    if check.get("trigger_mode"):
        sanitized["trigger_mode"] = sanitized_trigger_mode(check["trigger_mode"])

    if check.get("fresh_check"):
        sanitized["fresh_check"] = sanitized_check(check["fresh_check"])

    return sanitized


def sanitized_sender(sender):
    if not isinstance(sender, dict):
        return None

    summary = {
        "kind": sender.get("kind"),
        "mention_responder": sender.get("mention_responder"),
    }

    sender_identity = sender.get("sender") or {}
    if sender_identity.get("id"):
        summary["sender_hash"] = safe_hash(sender_identity["id"])
    if sender_identity.get("bot") is not None:
        summary["sender_bot"] = sender_identity.get("bot")

    return {key: value for key, value in summary.items() if value is not None}


def sanitized_channel_diagnostics(diagnostics):
    if not isinstance(diagnostics, dict):
        return None

    return {
        "ok": diagnostics.get("ok"),
        "transport": diagnostics.get("transport"),
        "enabled": diagnostics.get("enabled"),
        "token_configured": diagnostics.get("token_configured"),
        "token_secret_configured": diagnostics.get("token_secret_configured"),
        "allowed_guild_count": diagnostics.get("allowed_guild_count"),
        "allowed_channel_count": diagnostics.get("allowed_channel_count"),
        "deny_unbound_channels": diagnostics.get("deny_unbound_channels"),
        "bot_message_policy": diagnostics.get("bot_message_policy"),
        "direct_messages": diagnostics.get("direct_messages"),
        "free_response": diagnostics.get("free_response"),
        "inbound_replay": diagnostics.get("inbound_replay"),
        "slash_commands": diagnostics.get("slash_commands"),
        "cleanup": diagnostics.get("cleanup"),
    }


def sanitized_application_intents(intents):
    if not isinstance(intents, dict):
        return None

    return {
        "flags_present": intents.get("flags_present"),
        "message_content_intent_enabled": intents.get("message_content_intent_enabled"),
    }


def sanitized_trigger_mode(trigger_mode):
    if not isinstance(trigger_mode, dict):
        return None

    result = {
        "account_hash": safe_hash(trigger_mode.get("account_id")),
        "parent_channel_hash": safe_hash(trigger_mode.get("parent_channel_id")),
        "thread_hash": safe_hash(trigger_mode.get("thread_id")),
        "mode": trigger_mode.get("mode"),
        "key_shapes": trigger_mode.get("key_shapes"),
        "storage": trigger_mode.get("storage"),
    }

    if isinstance(trigger_mode.get("cleanup"), dict):
        result["cleanup"] = sanitized_trigger_mode(trigger_mode["cleanup"])

    return result


def safe_scope(value):
    if not value:
        return None

    scope = "".join(ch.lower() if ch.isalnum() else "_" for ch in str(value)).strip("_")
    return scope[:80] or None


def reason_kind_for(check):
    explicit = safe_scope(check.get("reason_kind"))

    if explicit:
        return explicit

    text = " ".join(
        str(check.get(key) or "")
        for key in ["reason_kind", "failure_hint", "setup_error"]
    ).lower()

    if "50007" in text or "cannot send messages to this user" in text:
        return "discord_dm_setup_refused"

    if "message_content_intent_declared=false" in text:
        return "discord_message_content_intent_or_delivery"

    if "no lemon reply" in text and "unmentioned" in text:
        return "discord_no_reply_for_unmentioned_message"

    if "message content intent" in text:
        return "discord_message_content_intent_or_delivery"

    if check.get("ok") is False:
        return "proof_failure"

    return None


def local_mix_json(marker, expression, label):
    command = ["mix", "run", "--no-start", "-e", expression]
    result = subprocess.run(command, cwd=Path(__file__).resolve().parents[1], capture_output=True, text=True)

    if result.returncode != 0:
        raise SystemExit(
            f"Failed to load local {label}: "
            + (result.stderr.strip() or result.stdout.strip())
        )

    try:
        line = next(
            line
            for line in reversed(result.stdout.splitlines())
            if line.startswith(marker + ":")
        )
        return json.loads(line.split(":", 1)[1])
    except (StopIteration, json.JSONDecodeError):
        raise SystemExit(f"Failed to parse local {label} JSON from mix output")


def run_kanban_slash_registration_update(token):
    app = application_identity(token)
    local_schema = local_kanban_command_schema()
    registered = register_global_command(token, app["id"], local_schema)
    check = run_kanban_slash_registration_check(token)

    check["registered_command_id"] = registered.get("id")
    check["registered_command_version"] = registered.get("version")
    check["schema_source"] = "LemonChannels.Adapters.Discord.Transport.kanban_command_schema/0"
    return check


def run_checkpoint_slash_registration_update(token):
    app = application_identity(token)
    local_schema = local_checkpoint_command_schema()
    registered = register_global_command(token, app["id"], local_schema)
    check = run_checkpoint_slash_registration_check(token)

    check["registered_command_id"] = registered.get("id")
    check["registered_command_version"] = registered.get("version")
    check["schema_source"] = "LemonChannels.Adapters.Discord.Transport.checkpoint_command_schema/0"
    return check


def run_rollback_slash_registration_update(token):
    app = application_identity(token)
    local_schema = local_rollback_command_schema()
    registered = register_global_command(token, app["id"], local_schema)
    check = run_rollback_slash_registration_check(token)

    check["registered_command_id"] = registered.get("id")
    check["registered_command_version"] = registered.get("version")
    check["schema_source"] = "LemonChannels.Adapters.Discord.Transport.rollback_command_schema/0"
    return check


def run_media_slash_registration_update(token):
    app = application_identity(token)
    local_schema = local_media_command_schema()
    registered = register_global_command(token, app["id"], local_schema)
    check = run_media_slash_registration_check(token)

    check["registered_command_id"] = registered.get("id")
    check["registered_command_version"] = registered.get("version")
    check["schema_source"] = "LemonChannels.Adapters.Discord.Transport.media_command_schema/0"
    return check


def run_kanban_slash_registration_check(token):
    app = application_identity(token)
    commands = list_global_commands(token, app["id"])
    kanban = find_message(commands, lambda command: command.get("name") == "kanban")
    validation = validate_kanban_command(kanban)

    return {
        "name": "discord_kanban_slash_registration",
        "ok": validation["ok"],
        "application": app,
        "command_id": None if kanban is None else kanban.get("id"),
        "command_version": None if kanban is None else kanban.get("version"),
        "summary": validation,
    }


def run_checkpoint_slash_registration_check(token):
    app = application_identity(token)
    commands = list_global_commands(token, app["id"])
    checkpoint = find_message(commands, lambda command: command.get("name") == "checkpoint")
    validation = validate_checkpoint_command(checkpoint)

    return {
        "name": "discord_checkpoint_slash_registration",
        "ok": validation["ok"],
        "application": app,
        "command_id": None if checkpoint is None else checkpoint.get("id"),
        "command_version": None if checkpoint is None else checkpoint.get("version"),
        "summary": validation,
    }


def run_rollback_slash_registration_check(token):
    app = application_identity(token)
    commands = list_global_commands(token, app["id"])
    rollback = find_message(commands, lambda command: command.get("name") == "rollback")
    validation = validate_checkpoint_command(rollback, command_name="rollback")

    return {
        "name": "discord_rollback_slash_registration",
        "ok": validation["ok"],
        "application": app,
        "command_id": None if rollback is None else rollback.get("id"),
        "command_version": None if rollback is None else rollback.get("version"),
        "summary": validation,
    }


def run_media_slash_registration_check(token):
    app = application_identity(token)
    commands = list_global_commands(token, app["id"])
    media = find_message(commands, lambda command: command.get("name") == "media")
    validation = validate_media_command(media)

    return {
        "name": "discord_media_slash_registration",
        "ok": validation["ok"],
        "application": app,
        "command_id": None if media is None else media.get("id"),
        "command_version": None if media is None else media.get("version"),
        "summary": validation,
    }


def run_all_slash_registration_check(token):
    app = application_identity(token)
    commands = list_global_commands(token, app["id"])
    expected = sorted(local_slash_command_names())
    registered = sorted(command.get("name") for command in commands if command.get("name"))
    missing = sorted(set(expected) - set(registered))

    return {
        "name": "discord_all_slash_registration",
        "ok": not missing,
        "application": app,
        "expected_command_count": len(expected),
        "registered_command_count": len(registered),
        "expected_commands": expected,
        "registered_commands": registered,
        "missing_commands": missing,
        "schema_source": "LemonChannels.Adapters.Discord.Transport.slash_commands/0",
        "proof_scope": "Discord application command registration only",
        "real_client_click_proof_required_for_broad_parity": True,
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


def create_dm_channel(token, recipient_id):
    return api(token, "POST", "/users/@me/channels", {"recipient_id": str(recipient_id)})


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


def validate_kanban_command(command):
    expected = {
        "boards": {"status", "owner", "limit"},
        "create": {"name", "workspace"},
        "show": {"board_id", "limit"},
        "archive": {"board_id"},
        "task_create": {"board_id", "title", "priority", "assignee", "worker_profile"},
        "task_update": {"task_id", "status", "priority", "assignee", "worker_profile"},
        "comment": {"task_id", "body"},
        "dispatch_start": {"board_id", "max_concurrency", "worker_profile"},
        "dispatch_status": {"board_id"},
        "dispatch_stop": {"board_id"},
    }

    if command is None:
        return {
            "ok": False,
            "missing_command": "kanban",
            "missing_subcommands": sorted(expected),
            "missing_options": {},
        }

    options = command.get("options") or []
    by_name = {option.get("name"): option for option in options}
    missing_subcommands = sorted(set(expected) - set(by_name))
    missing_options = {}

    for subcommand, option_names in expected.items():
        existing = by_name.get(subcommand, {}).get("options") or []
        existing_names = {option.get("name") for option in existing}
        missing = sorted(option_names - existing_names)

        if missing:
            missing_options[subcommand] = missing

    return {
        "ok": not missing_subcommands and not missing_options,
        "description": command.get("description"),
        "subcommands": sorted(by_name),
        "missing_subcommands": missing_subcommands,
        "missing_options": missing_options,
    }


def validate_checkpoint_command(command, command_name="checkpoint"):
    expected = {
        "status": set(),
        "events": {"limit"},
        "diff": {"checkpoint_id"},
        "restore": {"checkpoint_id", "confirm"},
    }

    if command is None:
        return {
            "ok": False,
            "missing_command": command_name,
            "missing_subcommands": sorted(expected),
            "missing_options": {},
            "wrong_option_types": {},
        }

    options = command.get("options") or []
    by_name = {option.get("name"): option for option in options}
    missing_subcommands = sorted(set(expected) - set(by_name))
    missing_options = {}
    wrong_option_types = {}

    for subcommand, option_names in expected.items():
        existing = by_name.get(subcommand, {}).get("options") or []
        existing_by_name = {option.get("name"): option for option in existing}
        missing = sorted(option_names - set(existing_by_name))

        if missing:
            missing_options[subcommand] = missing

        if subcommand == "restore":
            confirm = existing_by_name.get("confirm")

            if confirm and confirm.get("type") != 5:
                wrong_option_types["restore.confirm"] = confirm.get("type")

        if subcommand == "events":
            limit = existing_by_name.get("limit")

            if limit and limit.get("type") != 4:
                wrong_option_types["events.limit"] = limit.get("type")

    return {
        "ok": not missing_subcommands and not missing_options and not wrong_option_types,
        "description": command.get("description"),
        "subcommands": sorted(by_name),
        "missing_subcommands": missing_subcommands,
        "missing_options": missing_options,
        "wrong_option_types": wrong_option_types,
    }


def validate_media_command(command):
    expected = {"status": set()}

    if command is None:
        return {
            "ok": False,
            "missing_command": "media",
            "missing_subcommands": sorted(expected),
            "missing_options": {},
        }

    options = command.get("options") or []
    by_name = {option.get("name"): option for option in options}
    missing_subcommands = sorted(set(expected) - set(by_name))
    missing_options = {}

    for subcommand, option_names in expected.items():
        existing = by_name.get(subcommand, {}).get("options") or []
        existing_names = {option.get("name") for option in existing}
        missing = sorted(option_names - existing_names)

        if missing:
            missing_options[subcommand] = missing

    return {
        "ok": not missing_subcommands and not missing_options,
        "description": command.get("description"),
        "subcommands": sorted(by_name),
        "missing_subcommands": missing_subcommands,
        "missing_options": missing_options,
    }


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


def run_restart_seed(token, channel_id, bot_id, timeout_s, sender=None):
    nonce = f"lemon-discord-restart-seed-{int(time.time())}"
    prompt = f"{nonce} Discord restart replay seed: reply with exactly RESTART_SEED {nonce}"
    expected = f"RESTART_SEED {nonce}"
    check = run_user_prompt_check(
        token,
        channel_id,
        bot_id,
        timeout_s,
        name="discord_restart_replay_seed",
        nonce=nonce,
        prompt=prompt,
        expected_description=expected,
        validator=lambda messages, user_message: validate_exact_reply(messages, bot_id, user_message, expected),
        sender=sender,
    )
    check["restart_nonce"] = nonce
    check["restart_reply_id"] = (check.get("bot_reply") or {}).get("id") if check["ok"] else None
    check["proof_scope"] = "Discord live gateway restart seed"
    return check


def run_restart_verify(token, channel_id, bot_id, timeout_s, restart_nonce, restart_reply_id, sender=None):
    duplicate_window_s = min(timeout_s, 30)
    duplicate_deadline = time.time() + duplicate_window_s
    duplicates = []
    matched = []

    while time.time() < duplicate_deadline:
        recent = get_messages(token, channel_id, limit=100)
        matched = [
            summarize_message(message)
            for message in recent
            if restart_nonce in (message.get("content") or "")
            and message.get("author", {}).get("id") == bot_id
        ]
        duplicates = [
            row
            for row in matched
            if row.get("id") != restart_reply_id and id_after(row, restart_reply_id)
        ]

        if duplicates:
            break

        time.sleep(2)

    fresh_nonce = f"lemon-discord-restart-after-{int(time.time())}"
    fresh_expected = f"RESTART_AFTER {fresh_nonce}"
    fresh_prompt = (
        f"{fresh_nonce} Discord post-restart prompt: reply with exactly {fresh_expected}"
    )
    fresh_check = run_user_prompt_check(
        token,
        channel_id,
        bot_id,
        timeout_s,
        name="discord_restart_replay_fresh_prompt",
        nonce=fresh_nonce,
        prompt=fresh_prompt,
        expected_description=fresh_expected,
        validator=lambda messages, user_message: validate_exact_reply(
            messages, bot_id, user_message, fresh_expected
        ),
        sender=sender,
    )

    return {
        "name": "discord_restart_replay_verify",
        "ok": duplicates == [] and fresh_check["ok"],
        "channel_id": channel_id,
        "restart_nonce": restart_nonce,
        "restart_reply_id": restart_reply_id,
        "duplicate_window_s": duplicate_window_s,
        "duplicates": duplicates,
        "matched_restart_messages": matched[:8],
        "fresh_check": fresh_check,
        "proof_scope": "Discord live gateway restart verification",
        "manual_runtime_restart_required": True,
    }


def run_thread_inbound_wait(token, channel_id, bot_id, timeout_s, sender=None):
    nonce = f"lemon-discord-thread-{int(time.time())}"
    prompt = (
        f"{nonce} Discord thread matrix probe: this is an operator live-thread proof. "
        "Briefly confirm that zeebot is alive or operational in this thread."
    )
    return run_user_prompt_check(
        token,
        channel_id,
        bot_id,
        timeout_s,
        name="discord_thread_prompt_round_trip",
        nonce=nonce,
        prompt=prompt,
        expected_description="bot reply in thread confirms zeebot is alive or operational",
        validator=lambda messages, user_message: validate_thread_reply(messages, bot_id, user_message),
        sender=sender,
    )


def run_dm_inbound_wait(token, channel_id, bot_id, timeout_s, sender=None):
    nonce = f"lemon-discord-dm-{int(time.time())}"
    prompt = (
        f"{nonce} Discord DM matrix probe: this is an operator live-DM proof. "
        "Briefly confirm that zeebot is alive or operational in this DM."
    )
    return run_user_prompt_check(
        token,
        channel_id,
        bot_id,
        timeout_s,
        name="discord_dm_prompt_round_trip",
        nonce=nonce,
        prompt=prompt,
        expected_description="bot reply in DM confirms zeebot is alive or operational",
        validator=lambda messages, user_message: validate_thread_reply(messages, bot_id, user_message),
        sender=sender,
    )


def run_free_response_trigger_wait(token, channel_id, bot_id, timeout_s, sender=None):
    nonce = f"lemon-discord-free-response-{int(time.time())}"
    prompt = (
        f"{nonce} Discord free-response trigger proof: reply with FREE_RESPONSE {nonce}. "
        "This message intentionally does not mention the bot."
    )
    free_response_sender = without_mention_responder(sender)

    return run_user_prompt_check(
        token,
        channel_id,
        bot_id,
        timeout_s,
        name="discord_free_response_trigger_round_trip",
        nonce=nonce,
        prompt=prompt,
        expected_description=f"bot reply contains FREE_RESPONSE {nonce} without a mention",
        validator=lambda messages, user_message: validate_combined_reply(
            messages,
            bot_id,
            user_message,
            nonce,
            required=[f"FREE_RESPONSE {nonce}"],
        ),
        sender=free_response_sender,
    )


def run_free_response_message_content_preflight(token):
    diagnostics = local_discord_channel_diagnostics()
    application = application_identity(token)
    free_response = diagnostics.get("free_response") if isinstance(diagnostics, dict) else {}
    local_declared = (
        free_response.get("message_content_intent_declared") is True
        if isinstance(free_response, dict)
        else False
    )
    app_enabled = application.get("message_content_intent_enabled") is True
    flags_known = application.get("flags_present") is True

    check = {
        "name": "discord_free_response_message_content_preflight",
        "ok": local_declared and app_enabled,
        "proof_scope": "Discord free-response message content intent preflight",
        "local_channel_diagnostics": diagnostics,
        "application_intents": {
            "flags_present": application.get("flags_present"),
            "message_content_intent_enabled": application.get("message_content_intent_enabled"),
        },
    }

    if check["ok"]:
        return check

    check["reason_kind"] = "discord_message_content_intent_or_delivery"

    if not local_declared and app_enabled:
        check["failure_hint"] = (
            "Discord application flags show Message Content Intent enabled, but local "
            "Lemon config has not declared it. Set gateway.discord.message_content_intent_enabled = true "
            "only after confirming the Developer Portal setting, restart Lemon, and rerun the free-response matrix."
        )
    elif not flags_known:
        check["failure_hint"] = (
            "Discord application flags were unavailable, so the runner cannot verify Message Content Intent "
            "before waiting for an unmentioned-message proof. Use --skip-free-response-preflight for a diagnostic wait."
        )
    else:
        check["failure_hint"] = (
            "Discord Message Content Intent is not enabled or not declared. Enable the privileged intent "
            "in the Discord Developer Portal, set gateway.discord.message_content_intent_enabled = true "
            "after verifying it, restart Lemon, and rerun the free-response matrix."
        )

    return check


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


def run_generated_media_delivery_wait(token, channel_id, bot_id, timeout_s, sender=None):
    nonce = f"lemon-discord-generated-media-{int(time.time())}"
    filename = f"discord-generated-media-{nonce}.svg"
    prompt = (
        f"{nonce} Discord generated media delivery probe: use the media_generate_image tool "
        f"with provider local_svg, filename discord-generated-media-{nonce}, and sendToChannel true. "
        f"After the tool completes, reply with GENERATED_MEDIA_SENT {nonce}."
    )

    return run_user_prompt_check(
        token,
        channel_id,
        bot_id,
        timeout_s,
        name="discord_generated_media_delivery",
        nonce=nonce,
        prompt=prompt,
        expected_description=(
            f"bot reply contains GENERATED_MEDIA_SENT {nonce} and a generated SVG attachment"
        ),
        validator=lambda messages, user_message: validate_file_delivery(
            messages,
            bot_id,
            user_message,
            nonce,
            filename,
            required=[f"GENERATED_MEDIA_SENT {nonce}"],
        ),
        sender=sender,
    )


def run_generated_audio_delivery_wait(token, channel_id, bot_id, timeout_s, sender=None):
    nonce = f"lemon-discord-generated-audio-{int(time.time())}"
    filename = f"discord-generated-audio-{nonce}.wav"
    prompt = (
        f"{nonce} Discord generated audio delivery probe: use the media_generate_speech tool "
        f"with provider local_wav, text 'Lemon generated audio proof {nonce}', "
        f"filename discord-generated-audio-{nonce}, and sendToChannel true. "
        f"After the tool completes, reply with GENERATED_AUDIO_SENT {nonce}."
    )

    return run_user_prompt_check(
        token,
        channel_id,
        bot_id,
        timeout_s,
        name="discord_generated_audio_delivery",
        nonce=nonce,
        prompt=prompt,
        expected_description=(
            f"bot reply contains GENERATED_AUDIO_SENT {nonce} and a generated WAV attachment"
        ),
        validator=lambda messages, user_message: validate_file_delivery(
            messages,
            bot_id,
            user_message,
            nonce,
            filename,
            required=[f"GENERATED_AUDIO_SENT {nonce}"],
        ),
        sender=sender,
    )


def run_media_directive_delivery_wait(token, channel_id, bot_id, timeout_s, sender=None):
    nonce = f"lemon-discord-media-directive-{int(time.time())}"
    rel_path = f"tmp/discord-media-directive-{nonce}.txt"
    filename = f"discord-media-directive-{nonce}.txt"
    prompt = (
        f"{nonce} Discord MEDIA directive delivery probe: create a text file at {rel_path} "
        f"containing MEDIA_DIRECTIVE {nonce}. Finish with a final answer that includes "
        f"MEDIA_DIRECTIVE_SENT {nonce} and a separate line exactly MEDIA:{rel_path}. "
        f"Do not use a send-file tool or sendToChannel; rely on the final-answer MEDIA line."
    )

    return run_user_prompt_check(
        token,
        channel_id,
        bot_id,
        timeout_s,
        name="discord_media_directive_delivery",
        nonce=nonce,
        prompt=prompt,
        expected_description=(
            f"bot reply contains MEDIA_DIRECTIVE_SENT {nonce}, does not show MEDIA:, "
            f"and delivers {filename} as an attachment"
        ),
        validator=lambda messages, user_message: validate_media_directive_delivery(
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


def without_mention_responder(sender):
    if not sender:
        return None

    updated = dict(sender)
    updated["mention_responder"] = False
    return updated


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


def discord_session_key(args, channel_id, sender, peer_kind="group"):
    if peer_kind == "dm":
        return f"agent:{args.agent_id}:discord:{args.account_id}:dm:{channel_id}"

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


def maybe_reset_session(args, channel_id, sender, peer_kind="group"):
    if not args.reset_session_between_checks:
        return None

    session_key = discord_session_key(args, channel_id, sender, peer_kind=peer_kind)
    response = asyncio.run(reset_session_ws(args.control_plane_ws_url, session_key))

    return {
        "session_key": session_key,
        "control_plane_ws_url": args.control_plane_ws_url,
        "response": response.get("payload"),
    }


def set_trigger_mode(account_id, parent_channel_id, thread_id, mode):
    repo = Path(__file__).resolve().parents[1]
    scopes = [
        (int(parent_channel_id), int(thread_id)),
        (int(thread_id), int(thread_id)),
    ]
    scope_terms = ", ".join(f"{{{chat_id}, {topic_id}}}" for chat_id, topic_id in scopes)
    expression = f"""
Application.ensure_all_started(:lemon_core)
alias LemonChannels.Adapters.Discord.TriggerMode
for {{chat_id, topic_id}} <- [{scope_terms}] do
  scope = %LemonCore.ChatScope{{
    transport: :discord,
    chat_id: chat_id,
    topic_id: topic_id
  }}

  case "{mode}" do
    "clear" -> TriggerMode.clear_topic("{account_id}", chat_id, topic_id)
    value -> TriggerMode.set(scope, "{account_id}", String.to_existing_atom(value))
  end
end
"""
    result = subprocess.run(
        ["mix", "run", "--no-start", "-e", expression],
        cwd=repo,
        capture_output=True,
        text=True,
    )

    if result.returncode != 0:
        raise SystemExit(
            "Failed to set Discord trigger mode: "
            + (result.stderr.strip() or result.stdout.strip())
        )

    return {
        "account_id": account_id,
        "parent_channel_id": str(parent_channel_id),
        "thread_id": str(thread_id),
        "mode": mode,
        "key_shapes": ["parent_channel_thread", "thread_channel_thread"],
        "storage": "LemonChannels.Adapters.Discord.TriggerMode",
    }


def local_discord_channel_diagnostics():
    repo = Path(__file__).resolve().parents[1]
    expression = """
Application.ensure_all_started(:lemon_core)
status = LemonCore.Doctor.ChannelDiagnostics.status(project_dir: File.cwd!())
discord = Enum.find(status.transports, &(&1.transport == "discord"))
IO.puts("LEMON_DISCORD_DIAGNOSTICS_JSON:" <> Jason.encode!(discord || %{}))
"""
    result = subprocess.run(
        ["mix", "run", "--no-start", "-e", expression],
        cwd=repo,
        capture_output=True,
        text=True,
    )

    if result.returncode != 0:
        return {
            "ok": False,
            "error": "local_channel_diagnostics_failed",
            "stderr_present": bool(result.stderr.strip()),
            "stdout_present": bool(result.stdout.strip()),
        }

    try:
        line = next(
            line
            for line in reversed(result.stdout.splitlines())
            if line.startswith("LEMON_DISCORD_DIAGNOSTICS_JSON:")
        )
        decoded = json.loads(line.split(":", 1)[1])
    except (StopIteration, json.JSONDecodeError):
        return {
            "ok": False,
            "error": "local_channel_diagnostics_invalid_json",
            "stdout_present": bool(result.stdout.strip()),
        }

    return {
        "ok": True,
        "transport": decoded.get("transport"),
        "enabled": decoded.get("enabled"),
        "token_configured": decoded.get("token_configured"),
        "token_secret_configured": decoded.get("token_secret_configured"),
        "allowed_guild_count": decoded.get("allowed_guild_count"),
        "allowed_channel_count": decoded.get("allowed_channel_count"),
        "deny_unbound_channels": decoded.get("deny_unbound_channels"),
        "bot_message_policy": decoded.get("bot_message_policy"),
        "direct_messages": decoded.get("direct_messages"),
        "free_response": decoded.get("free_response"),
        "inbound_replay": decoded.get("inbound_replay"),
        "slash_commands": decoded.get("slash_commands"),
        "cleanup": {
            "includes_raw_bot_tokens": False,
            "includes_secret_names": False,
            "includes_channel_ids": False,
            "includes_guild_ids": False,
            "includes_message_bodies": False,
        },
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


def id_after(message, baseline_id):
    if not baseline_id:
        return True

    try:
        return int(message.get("id")) > int(baseline_id)
    except (TypeError, ValueError):
        return False


def validate_thread_reply(messages, bot_id, user_message):
    user_created = user_message.get("timestamp")

    bot_reply = find_message(
        messages,
        lambda message: message.get("author", {}).get("id") == bot_id
        and message.get("timestamp", "") >= user_created
        and any(
            marker in (message.get("content") or "").lower()
            for marker in ["alive", "operational", "working"]
        ),
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


def validate_file_delivery(
    messages,
    bot_id,
    user_message,
    nonce,
    filename,
    required=None,
):
    required = required or [f"FILE_SENT {nonce}"]
    combined = validate_combined_reply(
        messages,
        bot_id,
        user_message,
        nonce,
        required=required,
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


def validate_media_directive_delivery(messages, bot_id, user_message, nonce, filename):
    base = validate_file_delivery(
        messages,
        bot_id,
        user_message,
        nonce,
        filename,
        required=[f"MEDIA_DIRECTIVE_SENT {nonce}"],
    )
    user_created = user_message.get("timestamp")
    bot_messages = [
        message
        for message in messages
        if message.get("author", {}).get("id") == bot_id
        and message.get("timestamp", "") >= user_created
    ]
    directive_leaked = any("MEDIA:" in (message.get("content") or "") for message in bot_messages)
    marker_seen = any(
        f"MEDIA_DIRECTIVE_SENT {nonce}" in (message.get("content") or "")
        for message in bot_messages
    )

    return {
        "ok": base["ok"] and marker_seen and not directive_leaked,
        "summary": {
            **(base.get("summary") or {}),
            "directive_leaked": directive_leaked,
            "marker_seen": marker_seen,
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
    root.add_argument("--dm-channel-id")
    root.add_argument("--dm-recipient-id")
    root.add_argument("--list-channels", action="store_true")
    root.add_argument("--bot-api-smoke", action="store_true")
    root.add_argument("--wait-user-inbound", action="store_true")
    root.add_argument("--restart-seed", action="store_true")
    root.add_argument("--restart-verify", action="store_true")
    root.add_argument("--restart-nonce")
    root.add_argument("--restart-reply-id")
    root.add_argument("--restart-runtime-confirmed", action="store_true")
    root.add_argument("--wait-dm-inbound", action="store_true")
    root.add_argument("--wait-thread-inbound", action="store_true")
    root.add_argument("--wait-free-response-trigger", action="store_true")
    root.add_argument("--skip-free-response-preflight", action="store_true")
    root.add_argument("--wait-markdown", action="store_true")
    root.add_argument("--wait-long-output", action="store_true")
    root.add_argument("--wait-tool-rendering", action="store_true")
    root.add_argument("--wait-file-delivery", action="store_true")
    root.add_argument("--wait-generated-media-delivery", action="store_true")
    root.add_argument("--wait-generated-audio-delivery", action="store_true")
    root.add_argument("--wait-media-directive-delivery", action="store_true")
    root.add_argument("--manual-matrix", action="store_true")
    root.add_argument("--check-kanban-slash-registration", action="store_true")
    root.add_argument("--register-kanban-slash-command", action="store_true")
    root.add_argument("--check-checkpoint-slash-registration", action="store_true")
    root.add_argument("--register-checkpoint-slash-command", action="store_true")
    root.add_argument("--check-rollback-slash-registration", action="store_true")
    root.add_argument("--register-rollback-slash-command", action="store_true")
    root.add_argument("--check-media-slash-registration", action="store_true")
    root.add_argument("--register-media-slash-command", action="store_true")
    root.add_argument("--check-all-slash-registration", action="store_true")
    root.add_argument("--check-slash-client-click-proof", action="store_true")
    root.add_argument("--wait-slash-client-click-proof", action="store_true")
    root.add_argument("--slash-client-click-proof-path", type=Path, default=DEFAULT_SLASH_CLIENT_CLICK_PROOF)
    root.add_argument("--slash-client-click-command", default="/media status")
    root.add_argument("--skip-slash-client-click-instruction", action="store_true")
    root.add_argument("--continue-on-failure", action="store_true")
    root.add_argument("--result-path", type=Path)
    root.add_argument("--proof-path", type=Path)
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

    reset = maybe_reset_session(args, thread_id, run_check.sender)
    trigger_mode = None
    free_response_diagnostics = None

    if run_check.peer_kind == "free_response":
        free_response_diagnostics = local_discord_channel_diagnostics()
        trigger_mode = set_trigger_mode(args.account_id, args.channel_id, thread_id, "all")

    try:
        check = run_check(thread_id)
    finally:
        if trigger_mode:
            trigger_mode["cleanup"] = set_trigger_mode(
                args.account_id, args.channel_id, thread_id, "clear"
            )

    if reset:
        check["session_reset"] = reset

    check["parent_channel_id"] = args.channel_id
    check["thread"] = {
        "id": thread.get("id"),
        "name": thread.get("name"),
        "type": thread.get("type"),
        "parent_id": thread.get("parent_id"),
    }
    if free_response_diagnostics:
        check["local_channel_diagnostics"] = free_response_diagnostics

    if trigger_mode:
        check["trigger_mode"] = trigger_mode
        if not check.get("ok"):
            intent_declared = (
                free_response_diagnostics.get("free_response", {})
                if isinstance(free_response_diagnostics, dict)
                else {}
            ).get("message_content_intent_declared")
            intent_hint = (
                " Local channel diagnostics currently report "
                "message_content_intent_declared=false."
                if intent_declared is False
                else ""
            )
            check["failure_hint"] = (
                "No Lemon reply was observed for an unmentioned guild/thread message. "
                "Check Discord Message Content Intent, live gateway delivery for unmentioned "
                "messages, and trigger-mode store visibility before promoting free-response."
                + intent_hint
            )

    return check


def resolve_dm_channel_id(args, token):
    if args.dm_channel_id:
        return args.dm_channel_id

    if args.dm_recipient_id:
        channel = create_dm_channel(token, args.dm_recipient_id)
        channel_id = channel.get("id")

        if channel_id:
            return channel_id

        raise SystemExit(f"Discord DM channel creation returned no id: {json.dumps(channel)}")

    raise SystemExit("--wait-dm-inbound requires --dm-channel-id or --dm-recipient-id")


def run_in_dm_channel(args, run_check):
    reset = maybe_reset_session(args, run_check.channel_id, run_check.sender, peer_kind="dm")
    check = run_check(run_check.channel_id)

    if reset:
        check["session_reset"] = reset

    check["proof_scope"] = "discord direct message channel"
    return check


def write_result(args, result):
    if args.result_path:
        args.result_path.parent.mkdir(parents=True, exist_ok=True)
        args.result_path.write_text(json.dumps(result, indent=2) + "\n")

    if args.proof_path:
        args.proof_path.parent.mkdir(parents=True, exist_ok=True)
        args.proof_path.write_text(json.dumps(sanitized_live_proof(result), indent=2) + "\n")

    print(json.dumps(result, indent=2))


def write_dm_setup_failure(args, identity, sender, reason):
    reason_text = str(reason)
    reason_lower = reason_text.lower()
    failure_hint = "Discord refused DM channel setup."

    if "50007" in reason_text or "cannot send messages to this user" in reason_lower:
        failure_hint = (
            "Discord refused DM channel setup with code 50007 "
            "(Cannot send messages to this user). Use a human/open-DM channel "
            "before promoting Discord DM support."
        )

    result = {
        "ok": False,
        "bot": identity,
        "sender": sender_proof(sender),
        "channel_id": args.channel_id,
        "checks": [
            {
                "name": "discord_dm_prompt_round_trip",
                "ok": False,
                "proof_scope": "discord direct message channel setup",
                "setup_error": reason_text,
                "failure_hint": failure_hint,
                "dm_channel_id": args.dm_channel_id,
                "dm_recipient_id": args.dm_recipient_id,
                "local_channel_diagnostics": local_discord_channel_diagnostics(),
            }
        ],
    }

    write_result(args, result)


def main():
    args = parser().parse_args()

    if args.check_slash_client_click_proof:
        check = run_slash_client_click_proof_check(args.slash_client_click_proof_path)
        result = {
            "ok": check["ok"],
            "checks": [check],
        }

        write_result(args, result)
        raise SystemExit(0 if result["ok"] else 1)

    token = select_token(args)
    identity = bot_identity(token)
    sender = resolve_sender(args, identity)

    if args.wait_slash_client_click_proof:
        check = run_slash_client_click_proof_wait(args, token, identity)
        result = {
            "ok": check["ok"],
            "bot": identity,
            "channel_id": args.channel_id,
            "checks": [check],
        }

        write_result(args, result)
        raise SystemExit(0 if result["ok"] else 1)

    if args.wait_free_response_trigger and not args.skip_free_response_preflight:
        check = run_free_response_message_content_preflight(token)

        if not check["ok"]:
            result = {
                "ok": False,
                "bot": identity,
                "sender": sender_proof(without_mention_responder(sender)),
                "channel_id": args.channel_id,
                "checks": [check],
            }

            write_result(args, result)
            raise SystemExit(1)

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

    if (
        args.check_kanban_slash_registration
        or args.register_kanban_slash_command
        or args.check_checkpoint_slash_registration
        or args.register_checkpoint_slash_command
        or args.check_rollback_slash_registration
        or args.register_rollback_slash_command
        or args.check_media_slash_registration
        or args.register_media_slash_command
        or args.check_all_slash_registration
    ):
        checks = []

        if args.register_kanban_slash_command:
            checks.append(run_kanban_slash_registration_update(token))
        elif args.check_kanban_slash_registration:
            checks.append(run_kanban_slash_registration_check(token))

        if args.register_checkpoint_slash_command:
            checks.append(run_checkpoint_slash_registration_update(token))
        elif args.check_checkpoint_slash_registration:
            checks.append(run_checkpoint_slash_registration_check(token))

        if args.register_rollback_slash_command:
            checks.append(run_rollback_slash_registration_update(token))
        elif args.check_rollback_slash_registration:
            checks.append(run_rollback_slash_registration_check(token))

        if args.register_media_slash_command:
            checks.append(run_media_slash_registration_update(token))
        elif args.check_media_slash_registration:
            checks.append(run_media_slash_registration_check(token))

        if args.check_all_slash_registration:
            checks.append(run_all_slash_registration_check(token))

        result = {
            "ok": all(check["ok"] for check in checks),
            "bot": identity,
            "checks": checks,
        }

        write_result(args, result)
        raise SystemExit(0 if result["ok"] else 1)

    if not args.channel_id and not args.wait_dm_inbound:
        raise SystemExit("--channel-id is required unless --list-channels is used")

    selected = []

    if args.bot_api_smoke:
        selected.append(Check(lambda channel_id: run_bot_api_smoke(token, channel_id), None))

    if args.wait_user_inbound or args.manual_matrix:
        selected.append(Check(lambda channel_id: run_user_inbound_wait(token, channel_id, identity["id"], args.timeout, sender=sender), sender))

    if args.restart_seed:
        selected.append(Check(lambda channel_id: run_restart_seed(token, channel_id, identity["id"], args.timeout, sender=sender), sender))

    if args.restart_verify:
        if not args.restart_nonce:
            raise SystemExit("--restart-verify requires --restart-nonce")
        if not args.restart_runtime_confirmed:
            raise SystemExit("--restart-verify requires --restart-runtime-confirmed after restarting Lemon")

        selected.append(
            Check(
                lambda channel_id: run_restart_verify(
                    token,
                    channel_id,
                    identity["id"],
                    args.timeout,
                    args.restart_nonce,
                    args.restart_reply_id,
                    sender=sender,
                ),
                sender,
            )
        )

    if args.wait_dm_inbound:
        try:
            dm_channel_id = resolve_dm_channel_id(args, token)
        except SystemExit as error:
            write_dm_setup_failure(args, identity, sender, error)
            raise SystemExit(1)

        selected.append(Check(lambda channel_id: run_dm_inbound_wait(token, channel_id, identity["id"], args.timeout, sender=sender), sender, peer_kind="dm", channel_id=dm_channel_id))

    if args.wait_thread_inbound:
        if not args.per_check_thread:
            raise SystemExit("--wait-thread-inbound requires --per-check-thread")

        selected.append(Check(lambda channel_id: run_thread_inbound_wait(token, channel_id, identity["id"], args.timeout, sender=sender), sender))

    if args.wait_free_response_trigger:
        if not args.per_check_thread:
            raise SystemExit("--wait-free-response-trigger requires --per-check-thread")

        selected.append(Check(lambda channel_id: run_free_response_trigger_wait(token, channel_id, identity["id"], args.timeout, sender=sender), without_mention_responder(sender), peer_kind="free_response"))

    if args.wait_markdown or args.manual_matrix:
        selected.append(Check(lambda channel_id: run_markdown_wait(token, channel_id, identity["id"], args.timeout, sender=sender), sender))

    if args.wait_long_output or args.manual_matrix:
        selected.append(Check(lambda channel_id: run_long_output_wait(token, channel_id, identity["id"], args.timeout, sender=sender), sender))

    if args.wait_tool_rendering or args.manual_matrix:
        selected.append(Check(lambda channel_id: run_tool_rendering_wait(token, channel_id, identity["id"], args.timeout, sender=sender), sender))

    if args.wait_file_delivery or args.manual_matrix:
        selected.append(Check(lambda channel_id: run_file_delivery_wait(token, channel_id, identity["id"], args.timeout, sender=sender), sender))

    if args.wait_generated_media_delivery:
        selected.append(Check(lambda channel_id: run_generated_media_delivery_wait(token, channel_id, identity["id"], args.timeout, sender=sender), sender))

    if args.wait_generated_audio_delivery:
        selected.append(Check(lambda channel_id: run_generated_audio_delivery_wait(token, channel_id, identity["id"], args.timeout, sender=sender), sender))

    if args.wait_media_directive_delivery:
        selected.append(Check(lambda channel_id: run_media_directive_delivery_wait(token, channel_id, identity["id"], args.timeout, sender=sender), sender))

    if not selected:
        raise SystemExit(
            "Select at least one check: --bot-api-smoke, --wait-user-inbound, --restart-seed, --restart-verify, --wait-dm-inbound, --wait-thread-inbound, --wait-free-response-trigger, --wait-markdown, --wait-long-output, --wait-tool-rendering, --wait-file-delivery, --wait-generated-media-delivery, --wait-generated-audio-delivery, --wait-media-directive-delivery, --manual-matrix, --check-kanban-slash-registration, --register-kanban-slash-command, --check-checkpoint-slash-registration, --register-checkpoint-slash-command, --check-rollback-slash-registration, --register-rollback-slash-command, --check-media-slash-registration, --register-media-slash-command, --check-all-slash-registration, --check-slash-client-click-proof, or --wait-slash-client-click-proof"
        )

    checks = []

    for index, run_check in enumerate(selected, start=1):
        if run_check.peer_kind == "dm":
            check = run_in_dm_channel(args, run_check)
        else:
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

    write_result(args, result)
    raise SystemExit(0 if result["ok"] else 1)


if __name__ == "__main__":
    main()
