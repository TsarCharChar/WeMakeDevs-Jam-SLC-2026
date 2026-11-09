"""Bounded retention cleanup using the same replica-safe writes as ingestion."""

import asyncio
import logging

from backend.vector_store import StoreError

logger = logging.getLogger(__name__)


async def expire_periodically(store):
    while True:
        await asyncio.sleep(300)
        try:
            # Each replica processes at most 100 records per pass. CAS handles overlap.
            async with asyncio.timeout(180):
                await store.ready()
                result = await store.expire(limit=100)
            if result["expired"]:
                logger.info("Expired %s conversations", result["expired"])
        except (StoreError, TimeoutError):
            # No source text, ES response bodies, or credentials in logs.
            logger.warning("Conversation expiry pass failed; retrying on the next interval")
