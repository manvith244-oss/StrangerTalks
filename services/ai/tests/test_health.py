from __future__ import annotations

import pytest
from httpx import ASGITransport, AsyncClient

from strangertalks_ai.app import create_app
from strangertalks_ai.config import Settings


@pytest.mark.anyio
async def test_liveness_and_readiness_do_not_call_a_provider():
    app = create_app(Settings())
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        live = await client.get("/health/live")
        ready = await client.get("/health/ready")
    assert live.status_code == 200
    assert live.json() == {"status": "live"}
    assert ready.status_code == 200
    assert ready.json() == {"status": "ready"}


@pytest.mark.anyio
async def test_readiness_fails_closed_on_missing_credentials_for_enabled_capability_without_network():
    app = create_app(Settings(enabled_capabilities=frozenset({"safety"})))
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        response = await client.get("/health/ready")
    assert response.status_code == 503
    assert response.json() == {"status": "not_ready"}
