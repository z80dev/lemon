"""Ping 5 messages via Telethon."""
import asyncio
import os
from telethon import TelegramClient

# Get credentials from environment or replace with your values
API_ID = int(os.getenv('TG_API_ID', '12345'))
API_HASH = os.getenv('TG_API_HASH', 'your_api_hash')
SESSION_NAME = os.getenv('TG_SESSION', 'session_name')
CHAT = os.getenv('TG_CHAT', 'me')  # 'me' = saved messages, or use username/chat_id

async def main():
    async with TelegramClient(SESSION_NAME, API_ID, API_HASH) as client:
        for i in range(1, 6):
            msg = f"Ping {i}/5"
            await client.send_message(CHAT, msg)
            print(f"Sent: {msg}")
            await asyncio.sleep(0.5)
        print("Done! 5 pings sent.")

if __name__ == "__main__":
    asyncio.run(main())
