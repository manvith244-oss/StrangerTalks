from __future__ import annotations

import pytest
from fastapi import FastAPI
from fastapi.exceptions import RequestValidationError
from httpx import ASGITransport, AsyncClient
from pydantic import SecretStr

from strangertalks_ai.api.errors import AIServiceError, ai_service_error_handler, validation_error_handler
from strangertalks_ai.api.health import router as health_router
from strangertalks_ai.config import Settings

from .probe_fixture import ProbeState, register_probe_route

SERVICE_TOKEN = "test-ai-service-token"
PARTICIPANT_TOKEN = "participant-token-must-not-work"
OPENAI_KEY = "provider-key-must-not-work"


@pytest.fixture
def probe_state() -> ProbeState:
    return ProbeState()


@pytest.fixture
def test_app(probe_state: ProbeState) -> FastAPI:
    app = FastAPI()
    app.state.settings = Settings(
        service_credential=SecretStr(SERVICE_TOKEN),
        openai_api_key=SecretStr(OPENAI_KEY),
        enabled_capabilities=frozenset(),
    )
    app.add_exception_handler(AIServiceError, ai_service_error_handler)
    app.add_exception_handler(RequestValidationError, validation_error_handler)
    app.include_router(health_router)
    register_probe_route(app, probe_state)
    return app


@pytest.fixture
async def client(test_app: FastAPI):
    async with AsyncClient(transport=ASGITransport(app=test_app), base_url="http://test") as http_client:
        yield http_client


@pytest.fixture
def anyio_backend():
    return "asyncio"
