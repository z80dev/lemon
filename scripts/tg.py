"""Tiny helper: send a message to lemon_debug_bot and print replies."""
import asyncio, os, sys, time
from telethon import TelegramClient
from telethon.sessions import StringSession

C = TelegramClient(
    StringSession(os.environ["LEMON_TELEGRAM_TEST_SESSION"]),
    int(os.environ["LEMON_TELEGRAM_API_ID"]),
    os.environ["LEMON_TELEGRAM_API_HASH"],
)
B = os.getenv("LEMON_TELEGRAM_TEST_BOT", "lemon_debug_bot")

async def go(msg, timeout=90, settle=15):
    await C.start()
    me = await C.get_me()
    sent = await C.send_message(B, msg)
    replies, seen, last = [], set(), time.time()
    end = time.time() + timeout
    while time.time() < end:
        await asyncio.sleep(2)
        for m in await C.get_messages(B, limit=20):
            if m.id > sent.id and m.sender_id != me.id and m.id not in seen:
                seen.add(m.id)
                replies.append(m.text or "")
                last = time.time()
                print(f"[{m.id}] {m.text}")
        if replies and time.time() - last > settle:
            break
    if not replies: print("(no reply)")
    await C.disconnect()

asyncio.run(go(sys.argv[1], int(sys.argv[2]) if len(sys.argv)>2 else 90, int(sys.argv[3]) if len(sys.argv)>3 else 15))
