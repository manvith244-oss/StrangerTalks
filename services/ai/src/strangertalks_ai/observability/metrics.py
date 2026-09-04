from __future__ import annotations

from opentelemetry import metrics

from .privacy import assert_metric_privacy, metric_attributes

_meter = metrics.get_meter("strangertalks.ai")
_requests = _meter.create_counter("strangertalks.ai.requests")
_latency_ms = _meter.create_histogram("strangertalks.ai.duration_ms", unit="ms")


def record_request(*, capability: str, result: str, error_code: str | None, duration_ms: float) -> None:
    attrs = metric_attributes(capability=capability, result=result, error_code=error_code)
    assert_metric_privacy(attrs)
    _requests.add(1, attrs)
    _latency_ms.record(duration_ms, attrs)
