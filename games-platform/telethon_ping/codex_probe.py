#!/usr/bin/env python3
"""Quick probe: send /codex directive and watch for result."""
import asyncio, os, sys
from telethon import TelegramClient, events
from telethon.sessions import StringSession

CHAT_ID = -1003842984060

async def main():
    api_id = int(os.environ["TELEGRAM_API_ID"])
    api_hash = os.environ["TELEGRAM_API_HASH"]
    session = os.environ["TELEGRAM_SESSION_STRING"]

    client = TelegramClient(StringSession(session), api_id, api_hash)
    await client.start()
    print(f"Connected as {(await client.get_me()).username}")

    # Create a topic for this probe
    from telethon.tl.functions.channels import CreateForumTopicRequest
    result = await client(CreateForumTopicRequest(
        channel=CHAT_ID,
        title="[Probe] D01 codex retest",
        random_id=int.from_bytes(os.urandom(4), 'big')
    ))
    topic_id = result.updates[1].message.id
    print(f"Created probe topic: {topic_id}")

    # Set up reply listener
    reply_event = asyncio.Event()
    replies = []

    @client.on(events.NewMessage(chats=CHAT_ID))
    async def handler(event):
        if getattr(event.message, 'reply_to', None):
            tid = getattr(event.message.reply_to, 'reply_to_top_id', None) or getattr(event.message.reply_to, 'reply_to_msg_id', None)
            if tid == topic_id:
                replies.append(event.message)
                print(f"  Reply #{len(replies)} (msg {event.message.id}): {event.message.text[:200] if event.message.text else '<no text>'}")
                reply_event.set()

    # Send /codex prompt
    from telethon.tl.types import InputPeerChannel
    msg = await client.send_message(
        CHAT_ID,
        "/codex What is 2+2? Reply with just the number.",
        reply_to=topic_id
    )
    print(f"Sent /codex probe: msg_id={msg.id}")

    # Wait up to 5 minutes for reply
    try:
        await asyncio.wait_for(reply_event.wait(), timeout=300)
        print(f"\nGot {len(replies)} reply(ies)")
        for r in replies:
            print(f"  msg_id={r.id}: {r.text[:500] if r.text else '<no text>'}")
    except asyncio.TimeoutError:
        print("\nTimed out waiting for codex reply (300s)")

    await client.disconnect()

asyncio.run(main())
