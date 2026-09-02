from __future__ import annotations

from uuid import uuid4

import pytest
from httpx import ASGITransport, AsyncClient

from strangertalks_ai.app import create_app
from strangertalks_ai.config import Settings
from strangertalks_ai.contracts.errors import ErrorCode

from .conftest import OPENAI_KEY, PARTICIPANT_TOKEN, SERVICE_TOKEN

TRACEPARENT = "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"


def headers(token: str = SERVICE_TOKEN) -> dict[str, str]:
    return {
        "X-ST-Request-ID": str(uuid4()),
        "Authorization": f"Bearer {token}",
        "traceparent": TRACEPARENT,
    }


@pytest.mark.anyio
async def test_probe_success_echoes_request_id_and_keeps_payload_empty(client, probe_state):
    request_headers = headers()
    response = await client.post("/v1/boundary/probe", json={}, headers=request_headers)

    assert response.status_code == 200
    assert response.headers["X-ST-Request-ID"] == request_headers["X-ST-Request-ID"]
    assert response.json() == {
        "request_id": request_headers["X-ST-Request-ID"],
        "status": "ok",
        "result": {"value": "boundary-ok"},
        "error_code": None,
        "error_message": None,
    }
    assert probe_state.provider_calls == 1
    assert probe_state.payloads == [{}]


@pytest.mark.anyio
@pytest.mark.parametrize("token", [PARTICIPANT_TOKEN, OPENAI_KEY, "wrong-service-token"])
async def test_non_service_credentials_are_rejected_before_provider_logic(client, probe_state, token):
    request_headers = headers(token)
    response = await client.post("/v1/boundary/probe", json={}, headers=request_headers)
    assert response.status_code == 401
    assert response.headers["X-ST-Request-ID"] == request_headers["X-ST-Request-ID"]
    assert response.json()["error_code"] == ErrorCode.AI_AUTH_FAILED
    assert probe_state.provider_calls == 0


@pytest.mark.anyio
async def test_missing_service_credential_is_rejected_before_provider_logic(client, probe_state):
    request_headers = headers()
    request_headers.pop("Authorization")
    response = await client.post("/v1/boundary/probe", json={}, headers=request_headers)
    assert response.status_code == 401
    assert response.json()["error_code"] == ErrorCode.AI_AUTH_FAILED
    assert probe_state.provider_calls == 0


@pytest.mark.anyio
async def test_unknown_payload_field_is_invalid_request(client, probe_state):
    response = await client.post("/v1/boundary/probe", json={"prompt": "must not be accepted"}, headers=headers())
    assert response.status_code == 400
    assert response.json()["error_code"] == ErrorCode.AI_INVALID_REQUEST
    assert probe_state.provider_calls == 0


@pytest.mark.anyio
@pytest.mark.parametrize(
    ("fault", "status", "code"),
    [
        ("rate_limited", 429, ErrorCode.AI_PROVIDER_RATE_LIMITED),
        ("provider_unavailable", 502, ErrorCode.AI_PROVIDER_UNAVAILABLE),
        ("internal_error", 500, ErrorCode.AI_INTERNAL_ERROR),
    ],
)
async def test_error_mapping_is_sanitized_and_exactly_one_provider_call(client, probe_state, fault, status, code):
    probe_state.fault = fault
    response = await client.post("/v1/boundary/probe", json={}, headers=headers())
    assert response.status_code == status
    body = response.json()
    assert body["status"] == "error"
    assert body["result"] is None
    assert body["error_code"] == code
    assert "deliberately hidden" not in body["error_message"]
    assert probe_state.provider_calls == 1


@pytest.mark.anyio
async def test_production_app_has_no_probe_route_or_openapi_entry():
    production = create_app(Settings())
    assert "/v1/boundary/probe" not in production.openapi()["paths"]
    async with AsyncClient(transport=ASGITransport(app=production), base_url="http://prod") as client:
        response = await client.post("/v1/boundary/probe", json={})
        unsupported = await client.post("/v2/boundary/probe", json={})
    assert response.status_code == 404
    assert unsupported.status_code == 404
