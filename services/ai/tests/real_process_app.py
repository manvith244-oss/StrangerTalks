from __future__ import annotations

import os
from pathlib import Path

from opentelemetry import trace
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import ConsoleSpanExporter, SimpleSpanProcessor
from pydantic import SecretStr

from strangertalks_ai.app import create_app
from strangertalks_ai.config import Settings

from probe_fixture import ProbeState, register_probe_route


def _configure_test_tracing() -> None:
    provider = TracerProvider(resource=Resource.create({"service.name": "strangertalks-ai-boundary-test"}))
    provider.add_span_processor(SimpleSpanProcessor(ConsoleSpanExporter()))
    trace.set_tracer_provider(provider)


_configure_test_tracing()
state = ProbeState(
    fault=os.getenv("ST_AI_TEST_FAULT", "success"),
    provider_attempt_file=(
        Path(os.environ["ST_AI_PROVIDER_ATTEMPT_FILE"])
        if os.getenv("ST_AI_PROVIDER_ATTEMPT_FILE")
        else None
    ),
)

service_token = os.environ.get("STRANGERTALKS_AI_SERVICE_CREDENTIAL", "boundary-service-secret")
app = create_app(
    Settings(
        service_credential=SecretStr(service_token),
        openai_api_key=None,
        enabled_capabilities=frozenset(),
    )
)
register_probe_route(app, state)
