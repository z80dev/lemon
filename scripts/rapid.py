"""Send 3 messages rapidly, collect replies."""
import asyncio, os, time
from telethon import TelegramClient
from telethon.sessions import StringSession
C = TelegramClient(
    StringSession(os.environ["LEMON_TELEGRAM_TEST_SESSION"]),
    int(os.environ["LEMON_TELEGRAM_API_ID"]),
    os.environ["LEMON_TELEGRAM_API_HASH"],
)
B = os.getenv("LEMON_TELEGRAM_TEST_BOT", "lemon_debug_bot")
async def go():
    await C.start()
    me = await C.get_me()
    s1 = await C.send_message(B, "First part:")
    await asyncio.sleep(0.3)
    await C.send_message(B, "what is the")
    await asyncio.sleep(0.3)
    await C.send_message(B, "capital of France?")
    seen, last = set(), time.time()
    for _ in range(30):
        await asyncio.sleep(2)
        for m in await C.get_messages(B, limit=15):
            if m.id > s1.id and m.sender_id != me.id and m.id not in seen:
                seen.add(m.id)
                last = time.time()
                print(f"[{m.id}] {m.text}")
        if seen and time.time() - last > 12: break
    await C.disconnect()
asyncio.run(go())
