from __future__ import annotations

from dataclasses import dataclass
from uuid import UUID, uuid4

from fastapi import Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse

from strangertalks_ai.contracts.common import BoundaryEnvelope
from strangertalks_ai.contracts.errors import (
    HTTP_STATUS_BY_ERROR,
    SANITIZED_ERROR_MESSAGES,
    ErrorCode,
)


@dataclass(frozen=True, slots=True)
class AIServiceError(Exception):
    code: ErrorCode


def request_id_for_error(request: Request) -> UUID:
    metadata = getattr(request.state, "ai_metadata", None)
    if metadata is not None:
        return metadata.request_id

    raw = request.headers.get("X-ST-Request-ID")
    if raw:
        try:
            return UUID(raw)
        except ValueError:
            pass
    return uuid4()


def error_response(request: Request, code: ErrorCode) -> JSONResponse:
    request_id = request_id_for_error(request)
    envelope = BoundaryEnvelope(
        request_id=request_id,
        status="error",
        result=None,
        error_code=code,
        error_message=SANITIZED_ERROR_MESSAGES[code],
    )
    return JSONResponse(
        status_code=HTTP_STATUS_BY_ERROR[code],
        content=envelope.model_dump(mode="json"),
        headers={"X-ST-Request-ID": str(request_id)},
    )


async def ai_service_error_handler(request: Request, exc: AIServiceError) -> JSONResponse:
    return error_response(request, exc.code)


async def validation_error_handler(request: Request, _exc: RequestValidationError) -> JSONResponse:
    return error_response(request, ErrorCode.AI_INVALID_REQUEST)
