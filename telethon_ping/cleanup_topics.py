#!/usr/bin/env python3
"""Delete all test/stress/mega topics from the Telegram group."""
from __future__ import annotations
import asyncio
import os
import logging

from telethon import TelegramClient
from telethon.sessions import StringSession
from telethon.tl.functions.messages import GetForumTopicsRequest, DeleteTopicHistoryRequest

CHAT_ID = -1003842984060

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(message)s", datefmt="%H:%M:%S")
log = logging.getLogger("cleanup")


def is_test_topic(title: str) -> bool:
    t = title.lower()
    prefixes = ["[asynctest]", "[test]", "[async_test]", "[stress", "[mega",
                "[enginematrix", "lemon stress"]
    keywords = ["mega", "stress test", "stress_test", "test mission", "mission #",
                "ping", "nonblock", "async test", "enginematrix"]
    if any(t.startswith(p) for p in prefixes):
        return True
    if any(kw in t for kw in keywords):
        return True
    return False


async def main():
    api_id = int(os.environ["TELEGRAM_API_ID"])
    api_hash = os.environ["TELEGRAM_API_HASH"]
    session_str = os.environ["TELEGRAM_SESSION_STRING"]

    client = TelegramClient(StringSession(session_str), api_id, api_hash)
    await client.start()
    me = await client.get_me()
    log.info(f"Authenticated as {me.username}")

    entity = await client.get_entity(CHAT_ID)

    # Collect all topics across pages
    all_topics = []
    offset_id = 0
    offset_date = 0
    offset_topic = 0
    while True:
        result = await client(GetForumTopicsRequest(
            peer=entity,
            offset_date=offset_date,
            offset_id=offset_id,
            offset_topic=offset_topic,
            limit=100,
        ))
        if not result.topics:
            break
        all_topics.extend(result.topics)
        if len(result.topics) < 100:
            break
        last = result.topics[-1]
        offset_id = last.id
        offset_topic = last.id
        offset_date = getattr(last, "date", 0)

    log.info(f"Total topics found: {len(all_topics)}")

    # Show all topics and mark which will be deleted
    topics_to_delete = []
    for topic in all_topics:
        title = getattr(topic, "title", "")
        if is_test_topic(title):
            topics_to_delete.append((topic.id, title))

    log.info(f"Topics to delete: {len(topics_to_delete)}")
    for tid, title in topics_to_delete:
        log.info(f"  will delete: {title} (id={tid})")

    deleted = 0
    for topic_id, title in topics_to_delete:
        try:
            await client(DeleteTopicHistoryRequest(
                peer=entity,
                top_msg_id=topic_id,
            ))
            deleted += 1
            log.info(f"  Deleted: {title} (id={topic_id})")
        except Exception as e:
            log.warning(f"  Failed: {title} (id={topic_id}): {e}")
        await asyncio.sleep(0.5)

    log.info(f"Done! Deleted {deleted}/{len(topics_to_delete)} topics")
    await client.disconnect()


if __name__ == "__main__":
    asyncio.run(main())
