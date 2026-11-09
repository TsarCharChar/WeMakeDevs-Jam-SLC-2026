"""Bounded retention cleanup using the same replica-safe writes as ingestion."""

import asyncio
import logging

from elastic_transport import TransportError
from elasticsearch import ApiError

from backend.attendee.locations import purge_expired
from backend.elastic_client import get_elasticsearch_client
from backend.vector_store import StoreError

logger = logging.getLogger(__name__)


async def purge_locations_once(client):
    try:
        async with asyncio.timeout(30):
            await asyncio.to_thread(purge_expired, client)
    except (ApiError, TransportError, TimeoutError):
        logger.warning("Location purge failed; retrying on the next interval")


async def purge_locations_periodically():
    client = get_elasticsearch_client()
    if client is None:
        return
    while True:
        await asyncio.sleep(60)
        await purge_locations_once(client)


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
