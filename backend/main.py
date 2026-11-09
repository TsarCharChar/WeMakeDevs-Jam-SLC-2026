import asyncio
import hmac
import os
from contextlib import asynccontextmanager, suppress
from typing import Annotated

from fastapi import Depends, FastAPI, Header, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse

from backend.attendee import router as attendee_router
from backend.config import Settings
from backend.maintenance import expire_periodically
from backend.models import (
    ConversationSearch,
    ConversationWrite,
    Identifier,
    SearchResults,
    WriteResult,
)
from backend.session_search import router as session_search_router
from backend.vector_store import StoreError, VectorStore, create_client


def create_app(settings: Settings | None = None, store: VectorStore | None = None):
    settings = settings or Settings.from_env()

    @asynccontextmanager
    async def lifespan(app):
        app.state.store = store
        app.state.configuration_error = False
        client = None
        cleanup = None
        if store is None and settings.enabled:
            try:
                client = create_client(settings)
                app.state.store = VectorStore(settings, client)
                cleanup = asyncio.create_task(expire_periodically(app.state.store))
            except ValueError:
                app.state.configuration_error = True
        try:
            yield
        finally:
            if cleanup:
                cleanup.cancel()
                with suppress(asyncio.CancelledError):
                    await cleanup
            if client:
                await client.aclose()

    app = FastAPI(title="ConFellow API", lifespan=lifespan)

    @app.exception_handler(StoreError)
    async def store_error(_request, error):
        return JSONResponse(status_code=error.status, content={"detail": error.message})

    @app.exception_handler(RequestValidationError)
    async def validation_error(_request, error):
        # FastAPI's default response echoes invalid inputs, including transcripts.
        errors = [
            {key: value for key, value in item.items() if key in ("loc", "msg", "type")}
            for item in error.errors()
        ]
        return JSONResponse(status_code=422, content={"detail": errors})

    async def authorized_store(request: Request, authorization: Annotated[str | None, Header()] = None):
        if len(settings.service_token) < 32:
            raise StoreError(503, "Conversation API is not configured")
        expected = "Bearer " + settings.service_token
        if authorization is None or not hmac.compare_digest(authorization.encode(), expected.encode()):
            raise StoreError(401, "A valid service bearer token is required")
        current = request.app.state.store
        if current is None:
            raise StoreError(503, "Vector search is not configured")
        await current.ready()
        return current

    @app.get("/")
    def home():
        return {"message": "ConFellow backend is running", "version": os.getenv("APP_VERSION", "development")}

    @app.get("/healthz")
    def health():
        return {"status": "healthy"}

    @app.get("/readyz")
    async def readiness(request: Request):
        if request.app.state.configuration_error:
            raise StoreError(503, "Vector search configuration is incomplete or invalid")
        current = request.app.state.store
        if current is None:
            # Keep the existing preview available until credentials are provisioned.
            return {"status": "ready", "vector_search": "disabled"}
        await current.ready()
        return {"status": "ready", "vector_search": "ready"}

    @app.put("/conversations/{conversation_id}", response_model=WriteResult)
    async def put_conversation(
        conversation_id: Identifier,
        body: ConversationWrite,
        current: Annotated[VectorStore, Depends(authorized_store)],
    ):
        return await current.upsert(conversation_id, body)

    @app.post("/search", response_model=SearchResults)
    async def search(body: ConversationSearch, current: Annotated[VectorStore, Depends(authorized_store)]):
        return await current.search(body)

    @app.delete("/conversations/{conversation_id}", response_model=WriteResult)
    async def delete_conversation(
        conversation_id: Identifier,
        conference: Identifier,
        owner_id: Identifier,
        current: Annotated[VectorStore, Depends(authorized_store)],
    ):
        return await current.delete(conversation_id, conference, owner_id)

    app.include_router(session_search_router)
    app.include_router(attendee_router)

    return app


app = create_app()
