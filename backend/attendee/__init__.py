from fastapi import APIRouter

from backend.attendee import feed, graph, me, moments, recommend, search, transcripts

router = APIRouter()
for module in (me, moments, graph, search, recommend, feed, transcripts):
    router.include_router(module.router)
