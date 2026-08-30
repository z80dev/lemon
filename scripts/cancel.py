"""Launch task then cancel it."""
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
    # Fresh session
    s0 = await C.send_message(B, "/new")
    await asyncio.sleep(5)
    # Launch something slow
    s1 = await C.send_message(B, "Write a 2000-word essay about artificial intelligence history, covering every decade from 1950 to 2020.")
    print(">>> Sent long task, waiting 3s then cancelling...")
    await asyncio.sleep(3)
    s2 = await C.send_message(B, "/cancel")
    print(">>> Sent /cancel")
    seen, last = set(), time.time()
    for _ in range(30):
        await asyncio.sleep(2)
        for m in await C.get_messages(B, limit=20):
            if m.id > s0.id and m.sender_id != me.id and m.id not in seen:
                seen.add(m.id)
                last = time.time()
                print(f"[{m.id}] {m.text[:250]}")
        if seen and time.time() - last > 12: break
    await C.disconnect()
asyncio.run(go())
