import asyncio
import time
from telethon import TelegramClient
from telethon.sessions import StringSession

# Use Telegram's test environment - no real credentials needed for basic connectivity test
# These are public test credentials that Telegram provides
TEST_API_ID = 17349  # Telegram's test API ID
TEST_API_HASH = "344583e45741c457fe1862106095a5eb"  # Telegram's test API hash

# Telegram test DC
TEST_DC_IP = "149.154.167.40"
TEST_DC_PORT = 443

async def ping_telegram():
    """Ping Telegram server using Telethon"""
    client = None
    try:
        # Create client with test credentials
        client = TelegramClient(
            StringSession(),  # Memory-only session
            api_id=TEST_API_ID,
            api_hash=TEST_API_HASH,
            connection_retries=1,
            request_retries=1
        )
        
        start_time = time.time()
        
        # Try to connect - this establishes TCP connection and does handshake
        await client.connect()
        
        end_time = time.time()
        latency_ms = (end_time - start_time) * 1000
        
        is_connected = client.is_connected()
        await client.disconnect()
        
        if is_connected:
            return True, latency_ms
        return False, "Connection failed"
        
    except Exception as e:
        if client:
            try:
                await client.disconnect()
            except:
                pass
        return False, str(e)

async def main():
    print("Pinging Telegram servers 5 times via Telethon...")
    print(f"Using Telegram test API credentials")
    print("-" * 50)
    
    results = []
    for i in range(1, 6):
        success, result = await ping_telegram()
        results.append((success, result))
        if success:
            print(f"Ping {i}: ✓ {result:.2f} ms")
        else:
            print(f"Ping {i}: ✗ Failed ({result})")
        await asyncio.sleep(0.5)
    
    print("-" * 50)
    
    # Summary
    successful = [r for r in results if r[0]]
    if successful:
        avg_latency = sum(r[1] for r in successful) / len(successful)
        print(f"Success: {len(successful)}/5, Avg latency: {avg_latency:.2f} ms")
    else:
        print("All pings failed")
    print("Done!")

if __name__ == "__main__":
    asyncio.run(main())
