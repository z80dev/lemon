"""Send long task then steer mid-run."""
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
    s1 = await C.send_message(B, "Write a 500-word essay about the history of pizza.")
    print(">>> Sent essay request, waiting 5s then steering...")
    await asyncio.sleep(5)
    await C.send_message(B, "/steer Actually, make it about sushi instead of pizza.")
    print(">>> Sent steer")
    seen, last = set(), time.time()
    for _ in range(45):
        await asyncio.sleep(2)
        for m in await C.get_messages(B, limit=20):
            if m.id > s1.id and m.sender_id != me.id and m.id not in seen:
                seen.add(m.id)
                last = time.time()
                print(f"[{m.id}] {m.text[:300]}")
        if seen and time.time() - last > 15: break
    await C.disconnect()
asyncio.run(go())
