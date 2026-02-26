#!/usr/bin/env python3
"""
Telethon ping script - sends "ping 2" message via Telegram.

Usage:
    uv run ping.py <target> [api_id] [api_hash] [phone]

Arguments:
    target    Target username, phone number, or chat ID to send message to
    api_id    Telegram API ID (optional, defaults to env var TELEGRAM_API_ID)
    api_hash  Telegram API hash (optional, defaults to env var TELEGRAM_API_HASH)
    phone     Phone number for authentication (optional, defaults to env var TELEGRAM_PHONE)
"""

import asyncio
import os
import sys
from telethon import TelegramClient
from telethon.errors import SessionPasswordNeededError


async def amain():
    """Async main function."""
    # Get configuration from arguments or environment variables
    if len(sys.argv) < 2:
        print("Usage: ping2 <target> [api_id] [api_hash] [phone]")
        print("  target: username, phone number, or chat ID")
        sys.exit(1)

    target = sys.argv[1]
    api_id = int(sys.argv[2]) if len(sys.argv) > 2 else int(os.environ.get("TELEGRAM_API_ID", 0))
    api_hash = sys.argv[3] if len(sys.argv) > 3 else os.environ.get("TELEGRAM_API_HASH", "")
    phone = sys.argv[4] if len(sys.argv) > 4 else os.environ.get("TELEGRAM_PHONE", "")

    if not api_id or not api_hash:
        print("Error: API ID and API hash are required.")
        print("Set TELEGRAM_API_ID and TELEGRAM_API_HASH environment variables")
        print("or pass them as arguments.")
        sys.exit(1)

    # Initialize the client
    session_name = "ping_session"
    client = TelegramClient(session_name, api_id, api_hash)

    try:
        await client.start(phone=phone if phone else None)

        # Handle 2FA if needed
        if await client.is_user_authorized():
            print("Authenticated successfully!")
        else:
            print("Please check your phone for the login code.")
            await client.sign_in(phone, input("Enter the code: "))

        # Send the ping message
        print(f"Sending 'ping 2' to {target}...")
        await client.send_message(target, "ping 2")
        print("Message sent successfully!")

    except SessionPasswordNeededError:
        password = input("Two-factor authentication enabled. Enter your password: ")
        await client.sign_in(password=password)
        await client.send_message(target, "ping 2")
        print("Message sent successfully!")

    except Exception as e:
        print(f"Error: {e}")
        sys.exit(1)

    finally:
        await client.disconnect()


def main():
    """Entry point for the ping2 command."""
    asyncio.run(amain())


def ping4_entry():
    """Entry point for the ping4 command."""
    asyncio.run(ping4_async())


async def ping4_async():
    """Async main function for ping4 - sends 4 ping messages."""
    # Get configuration from arguments or environment variables
    if len(sys.argv) < 2:
        print("Usage: ping4 <target> [api_id] [api_hash] [phone]")
        print("  target: username, phone number, or chat ID")
        sys.exit(1)

    target = sys.argv[1]
    api_id = int(sys.argv[2]) if len(sys.argv) > 2 else int(os.environ.get("TELEGRAM_API_ID", 0))
    api_hash = sys.argv[3] if len(sys.argv) > 3 else os.environ.get("TELEGRAM_API_HASH", "")
    phone = sys.argv[4] if len(sys.argv) > 4 else os.environ.get("TELEGRAM_PHONE", "")

    if not api_id or not api_hash:
        print("Error: API ID and API hash are required.")
        print("Set TELEGRAM_API_ID and TELEGRAM_API_HASH environment variables")
        print("or pass them as arguments.")
        sys.exit(1)

    # Initialize the client
    session_name = "ping4_session"
    client = TelegramClient(session_name, api_id, api_hash)

    try:
        await client.start(phone=phone if phone else None)

        # Handle 2FA if needed
        if await client.is_user_authorized():
            print("Authenticated successfully!")
        else:
            print("Please check your phone for the login code.")
            await client.sign_in(phone, input("Enter the code: "))

        # Send 4 ping messages
        print(f"Sending 4 pings to {target}...")
        for i in range(1, 5):
            msg = f"ping 4/{i}"
            await client.send_message(target, msg)
            print(f"Sent: {msg}")
            await asyncio.sleep(0.5)
        print("All 4 messages sent successfully!")

    except SessionPasswordNeededError:
        password = input("Two-factor authentication enabled. Enter your password: ")
        await client.sign_in(password=password)
        for i in range(1, 5):
            msg = f"ping 4/{i}"
            await client.send_message(target, msg)
            print(f"Sent: {msg}")
            await asyncio.sleep(0.5)
        print("All 4 messages sent successfully!")

    except Exception as e:
        print(f"Error: {e}")
        sys.exit(1)

    finally:
        await client.disconnect()


if __name__ == "__main__":
    main()
