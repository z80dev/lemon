---
name: telegram-gateway-debug-loop
description: "Debug and stress-test lemon gateway behavior by acting as both sides of Telegram conversations: run lemon-gateway with debug logs, then use Telethon with user credentials to send/reply messages in a dedicated topic while watching gateway logs and runtime state. Use for stuck runs, delivery failures, scheduler/lock contention, async delegation bugs, and context overflows."
disable-model-invocation: true
argument-hint: "[description of issue to debug]"
allowed-tools: Read, Grep, Bash, Glob, Write
---

# Telegram Gateway Debug Loop

Use this skill to run end-to-end repros with real Telegram traffic.

## Setup

1. Load Telegram credentials from `~/.zeebot/api_keys/telegram.txt`.
   - Read the file to get `api_id`, `api_hash`, and phone number.
   - NEVER print, echo, or commit these values. Hold them in memory only.

2. Start gateway with debug logging:
   ```bash
   cd /Users/z80/dev/lemon
   LOG_LEVEL=debug ./bin/lemon-gateway --debug --sname lemon_gateway_debug
   ```
   Run this in the background and monitor its output.

3. Optionally attach a remote shell for live introspection:
   ```bash
   iex --sname lemon_attach --cookie lemon_gateway_dev_cookie --remsh lemon_gateway_debug@$(hostname -s)
   ```

## Sending Messages via Telethon

4. Use Telethon through `uv` (no global install needed):
   ```bash
   uv run --with telethon python <script.py>
   ```
   Write a temporary Python script that:
   - Connects with the user's Telegram credentials
   - Sends messages into a dedicated debug topic/thread
   - Keeps all probes in that thread

5. Stress async behavior with prompts that trigger delegation/tool runs:
   - `agent_id=coder` delegation
   - Async poll loops
   - Multi-step tool workflows

## Inspecting Runtime State

6. While traffic is active, inspect runtime state via the remote shell:
   - `:sys.get_state(LemonGateway.Scheduler)` — scheduler state
   - `:sys.get_state(LemonGateway.EngineLock)` — lock state
   - `DynamicSupervisor.which_children(LemonGateway.ThreadWorkerSupervisor)` — active workers

## Watching for Failures

7. Watch gateway logs for high-value failure signatures:
   - `:unknown_channel` — message routed to unknown channel
   - Scheduler stalls or lock starvation
   - Context overflow/trim failures
   - Delivery retries/timeouts

## Capturing Repros

8. For each repro, capture:
   - The exact prompt(s) sent
   - Thread ID
   - Timestamps
   - State snapshots from the remote shell
   - Relevant log lines

If `$ARGUMENTS` is provided, focus the debug session on reproducing that specific issue.

## Secrets + Safety

- NEVER print or commit API keys, session strings, OTPs, or phone numbers.
- Keep credentials in local secret files only.
- If session auth is invalid, re-auth locally and update only local secret files.
- Do not include credentials in any script files that get written to disk — pass them via environment variables or read them at runtime.
