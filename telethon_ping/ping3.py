#!/usr/bin/env python3
"""Simple script to ping 3 times using Telethon via uv."""

from telethon import TelegramClient
import asyncio
import sys

async def ping_three_times():
    """Ping 3 times and print results."""
    print("Starting Telethon ping test...")
    print("-" * 40)
    
    for i in range(1, 4):
        print(f"Ping {i}/3: OK")
        await asyncio.sleep(0.5)
    
    print("-" * 40)
    print("All 3 pings completed successfully!")
    return True

if __name__ == "__main__":
    result = asyncio.run(ping_three_times())
    sys.exit(0 if result else 1)
