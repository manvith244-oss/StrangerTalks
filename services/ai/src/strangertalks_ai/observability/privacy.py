from __future__ import annotations

from collections.abc import Mapping
from typing import Any

_LOG_FORBIDDEN_KEYS = {
    "message",
    "content",
    "participant_id",
    "conversation_id",
    "report_id",
    "authorization",
    "credential",
    "credentials",
    "api_key",
    "openai_api_key",
}
_LOG_ID_ALLOWLIST = {"request_id", "trace_id", "span_id"}


def sanitize_log_fields(fields: Mapping[str, Any]) -> dict[str, Any]:
    sanitized: dict[str, Any] = {}
    for key, value in fields.items():
        lowered = key.lower()
        if lowered in _LOG_FORBIDDEN_KEYS:
            continue
        if lowered.endswith("_id") and lowered not in _LOG_ID_ALLOWLIST:
            continue
        if isinstance(value, Mapping):
            sanitized[key] = sanitize_log_fields(value)
        else:
            sanitized[key] = value
    return sanitized


def metric_attributes(*, capability: str, result: str, error_code: str | None) -> dict[str, str]:
    attrs = {"capability": capability, "result": result}
    if error_code is not None:
        attrs["error_code"] = error_code
    return attrs


def assert_metric_privacy(attributes: Mapping[str, object]) -> None:
    for key in attributes:
        lowered = key.lower()
        if lowered.endswith("_id") or lowered in _LOG_FORBIDDEN_KEYS:
            raise ValueError("unbounded or sensitive metric attribute")
