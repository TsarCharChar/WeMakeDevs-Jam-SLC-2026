from fastapi import APIRouter

from backend.attendee import feed, graph, matches, me, moments, search, sharing, transcripts

router = APIRouter()
for module in (me, moments, graph, search, feed, transcripts, sharing, matches):
    router.include_router(module.router)
