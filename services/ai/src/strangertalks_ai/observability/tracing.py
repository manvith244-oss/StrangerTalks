from __future__ import annotations

from contextlib import AbstractContextManager
from opentelemetry import trace
from opentelemetry.propagators.textmap import CarrierT
from opentelemetry.trace import Span
from opentelemetry.trace.propagation.tracecontext import TraceContextTextMapPropagator


def start_request_span(
    name: str,
    *,
    request_id: str,
    traceparent: str,
    tracestate: str | None,
    capability: str,
) -> AbstractContextManager[Span]:
    carrier: CarrierT = {"traceparent": traceparent}
    if tracestate:
        carrier["tracestate"] = tracestate
    parent = TraceContextTextMapPropagator().extract(carrier=carrier)
    tracer = trace.get_tracer("strangertalks.ai")
    return tracer.start_as_current_span(
        name,
        context=parent,
        attributes={
            "st.request_id": request_id,
            "st.capability": capability,
        },
    )
