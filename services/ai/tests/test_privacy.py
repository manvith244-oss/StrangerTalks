from __future__ import annotations

import pytest

from strangertalks_ai.observability.privacy import (
    assert_metric_privacy,
    metric_attributes,
    sanitize_log_fields,
)


def test_log_sanitizer_keeps_request_correlation_but_drops_identity_content_and_credentials():
    fields = sanitize_log_fields(
        {
            "request_id": "safe-correlation",
            "participant_id": "forbidden",
            "conversation_id": "forbidden",
            "report_id": "forbidden",
            "content": "secret user text",
            "message": "secret user text",
            "authorization": "Bearer secret",
            "api_key": "secret",
            "result": "ok",
        }
    )
    assert fields == {"request_id": "safe-correlation", "result": "ok"}


def test_metric_attributes_are_bounded_and_request_id_free():
    attrs = metric_attributes(capability="boundary_probe", result="error", error_code="AI_PROVIDER_TIMEOUT")
    assert attrs == {
        "capability": "boundary_probe",
        "result": "error",
        "error_code": "AI_PROVIDER_TIMEOUT",
    }
    assert_metric_privacy(attrs)
    assert "request_id" not in attrs


@pytest.mark.parametrize("bad_key", ["request_id", "participant_id", "conversation_id", "content", "authorization"])
def test_metric_privacy_rejects_identity_or_content_labels(bad_key):
    with pytest.raises(ValueError):
        assert_metric_privacy({bad_key: "nope"})
