from fastapi import APIRouter

from backend.attendee import feed, graph, me, moments, search

router = APIRouter()
for module in (me, moments, graph, search, feed):
    router.include_router(module.router)
