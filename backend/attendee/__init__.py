from fastapi import APIRouter

from backend.attendee import feed, graph, locations, matches, me, moments, rooms, search, sharing, transcripts

router = APIRouter()
for module in (me, moments, graph, search, feed, transcripts, sharing, matches, locations, rooms):
    router.include_router(module.router)
