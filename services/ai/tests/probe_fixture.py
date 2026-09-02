from __future__ import annotations

import anyio
import os
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Literal

from fastapi import Depends, FastAPI, Request
from fastapi.responses import JSONResponse, PlainTextResponse, StreamingResponse

from strangertalks_ai.api.errors import AIServiceError
from strangertalks_ai.api.metadata import RequestMetadata, require_metadata
from strangertalks_ai.contracts.common import BoundaryEnvelope, BoundaryResult, EmptyCapabilityPayload
from strangertalks_ai.contracts.errors import HTTP_STATUS_BY_ERROR, SANITIZED_ERROR_MESSAGES, ErrorCode
from strangertalks_ai.observability.logging import get_logger
from strangertalks_ai.observability.metrics import record_request
from strangertalks_ai.observability.tracing import start_request_span
from strangertalks_ai.security.service_auth import require_service_auth

Fault = Literal[
    "success",
    "rate_limited",
    "provider_unavailable",
    "provider_timeout",
    "internal_error",
    "invalid_json",
    "wrong_types",
    "missing_field",
    "extra_field",
    "oversized_body",
    "slow_trickle",
]

PYTHON_DEADLINE_SECONDS = 15.0


@dataclass(slots=True)
class ProbeState:
    fault: Fault = "success"
    provider_calls: int = 0
    payloads: list[dict[str, object]] = field(default_factory=list)
    provider_attempt_file: Path | None = None

    def mark_provider_call(self, payload: EmptyCapabilityPayload) -> None:
        self.provider_calls += 1
        self.payloads.append(payload.model_dump(mode="json"))
        if self.provider_attempt_file is not None:
            with self.provider_attempt_file.open("a", encoding="utf-8") as handle:
                handle.write("1\n")


class DeterministicProbeProvider:
    def __init__(self, state: ProbeState) -> None:
        self.state = state

    async def run(self, payload: EmptyCapabilityPayload) -> BoundaryResult:
        self.state.mark_provider_call(payload)
        fault = self.state.fault
        if fault == "provider_timeout":
            await anyio.sleep(PYTHON_DEADLINE_SECONDS + 2.0)
            return BoundaryResult(value="unreachable")
        if fault == "rate_limited":
            raise AIServiceError(ErrorCode.AI_PROVIDER_RATE_LIMITED)
        if fault == "provider_unavailable":
            raise AIServiceError(ErrorCode.AI_PROVIDER_UNAVAILABLE)
        if fault == "internal_error":
            raise RuntimeError("deliberately hidden provider failure")
        return BoundaryResult(value="boundary-ok")


def _record_http_attempt() -> None:
    path = os.getenv("ST_AI_HTTP_ATTEMPT_FILE")
    if path:
        with Path(path).open("a", encoding="utf-8") as handle:
            handle.write("1\n")


def register_probe_route(app: FastAPI, state: ProbeState) -> None:
    provider = DeterministicProbeProvider(state)

    @app.post("/v1/boundary/probe", include_in_schema=False)
    async def probe(
        request: Request,
        payload: EmptyCapabilityPayload,
        metadata: RequestMetadata = Depends(require_metadata),
        _auth: None = Depends(require_service_auth),
    ):
        _record_http_attempt()
        fault = state.fault
        request_id = str(metadata.request_id)

        if fault == "invalid_json":
            return PlainTextResponse("{", status_code=200, headers={"X-ST-Request-ID": request_id})
        if fault == "wrong_types":
            return JSONResponse(
                {"request_id": 123, "status": "ok", "result": {"value": "boundary-ok"}, "error_code": None, "error_message": None},
                headers={"X-ST-Request-ID": request_id},
            )
        if fault == "missing_field":
            return JSONResponse(
                {"request_id": request_id, "status": "ok", "result": {"value": "boundary-ok"}, "error_code": None},
                headers={"X-ST-Request-ID": request_id},
            )
        if fault == "extra_field":
            return JSONResponse(
                {"request_id": request_id, "status": "ok", "result": {"value": "boundary-ok"}, "error_code": None, "error_message": None, "extra": True},
                headers={"X-ST-Request-ID": request_id},
            )
        if fault == "oversized_body":
            return JSONResponse(
                {"request_id": request_id, "status": "ok", "result": {"value": "x" * 70_000}, "error_code": None, "error_message": None},
                headers={"X-ST-Request-ID": request_id},
            )
        if fault == "slow_trickle":
            async def body():
                yield b'{"request_id":"'
                await anyio.sleep(30)
                yield request_id.encode("ascii") + b'","status":"ok","result":{"value":"boundary-ok"},"error_code":null,"error_message":null}'

            return StreamingResponse(body(), media_type="application/json", headers={"X-ST-Request-ID": request_id})

        started = time.monotonic()
        code: ErrorCode | None = None
        logger = get_logger().bind(request_id=request_id, capability="boundary_probe")
        logger.info("ai_boundary_request_started")

        with start_request_span(
            "ai.boundary.probe",
            request_id=request_id,
            traceparent=metadata.traceparent,
            tracestate=metadata.tracestate,
            capability="boundary_probe",
        ):
            try:
                with anyio.fail_after(PYTHON_DEADLINE_SECONDS):
                    result = await provider.run(payload)
            except TimeoutError:
                code = ErrorCode.AI_PROVIDER_TIMEOUT
                result = None
            except AIServiceError as exc:
                code = exc.code
                result = None
            except Exception:
                code = ErrorCode.AI_INTERNAL_ERROR
                result = None

        elapsed_ms = (time.monotonic() - started) * 1000
        if code is None:
            envelope = BoundaryEnvelope(
                request_id=metadata.request_id,
                status="ok",
                result=result,
                error_code=None,
                error_message=None,
            )
            record_request(capability="boundary_probe", result="ok", error_code=None, duration_ms=elapsed_ms)
            logger.info("ai_boundary_request_finished", result="ok")
            return JSONResponse(
                status_code=200,
                content=envelope.model_dump(mode="json"),
                headers={"X-ST-Request-ID": request_id},
            )

        envelope = BoundaryEnvelope(
            request_id=metadata.request_id,
            status="error",
            result=None,
            error_code=code,
            error_message=SANITIZED_ERROR_MESSAGES[code],
        )
        record_request(capability="boundary_probe", result="error", error_code=code.value, duration_ms=elapsed_ms)
        logger.info("ai_boundary_request_finished", result="error", error_code=code.value)
        return JSONResponse(
            status_code=HTTP_STATUS_BY_ERROR[code],
            content=envelope.model_dump(mode="json"),
            headers={"X-ST-Request-ID": request_id},
        )
