from fastapi import APIRouter

from backend.attendee import feed, graph, me, moments, search, transcripts

router = APIRouter()
for module in (me, moments, graph, search, feed, transcripts):
    router.include_router(module.router)
