from __future__ import annotations

from uuid import uuid4

import pytest
from hypothesis import given, strategies as st
from pydantic import ValidationError

from strangertalks_ai.contracts.common import BoundaryEnvelope, BoundaryResult, EmptyCapabilityPayload
from strangertalks_ai.contracts.errors import HTTP_STATUS_BY_ERROR, ErrorCode


@given(st.dictionaries(st.text(min_size=1, max_size=24), st.integers(), min_size=1, max_size=4))
def test_empty_payload_rejects_every_unknown_field(payload):
    with pytest.raises(ValidationError):
        EmptyCapabilityPayload.model_validate(payload)


@pytest.mark.parametrize("value", [1, True, [], {}, None])
def test_provider_result_rejects_type_coercion(value):
    with pytest.raises(ValidationError):
        BoundaryResult.model_validate({"value": value})


@pytest.mark.parametrize(
    "body",
    [
        {"request_id": str(uuid4()), "status": "ok", "result": {"value": "ok"}, "error_code": None},
        {"request_id": 3, "status": "ok", "result": {"value": "ok"}, "error_code": None, "error_message": None},
        {"request_id": str(uuid4()), "status": "ok", "result": {"value": "ok", "extra": 1}, "error_code": None, "error_message": None},
        {"request_id": str(uuid4()), "status": "error", "result": {"value": "should-be-null"}, "error_code": "AI_INTERNAL_ERROR", "error_message": "internal service error"},
    ],
)
def test_envelope_rejects_malformed_nested_missing_and_extra_shapes(body):
    with pytest.raises(ValidationError):
        BoundaryEnvelope.model_validate(body)


def test_error_to_http_status_contract_is_exact():
    assert HTTP_STATUS_BY_ERROR == {
        ErrorCode.AI_INVALID_REQUEST: 400,
        ErrorCode.AI_CONTRACT_UNSUPPORTED: 400,
        ErrorCode.AI_AUTH_FAILED: 401,
        ErrorCode.AI_CAPABILITY_DISABLED: 403,
        ErrorCode.AI_PROVIDER_RATE_LIMITED: 429,
        ErrorCode.AI_PROVIDER_UNAVAILABLE: 502,
        ErrorCode.AI_PROVIDER_TIMEOUT: 504,
        ErrorCode.AI_OUTPUT_REJECTED: 422,
        ErrorCode.AI_OUTPUT_INVALID: 422,
        ErrorCode.AI_INTERNAL_ERROR: 500,
    }
