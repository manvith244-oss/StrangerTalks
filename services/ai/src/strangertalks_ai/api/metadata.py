from __future__ import annotations

import re
from uuid import UUID

from fastapi import Request
from pydantic import BaseModel, ConfigDict

from strangertalks_ai.api.errors import AIServiceError
from strangertalks_ai.contracts.errors import ErrorCode

_TRACEPARENT_RE = re.compile(r"^00-([0-9a-f]{32})-([0-9a-f]{16})-([0-9a-f]{2})$")


class RequestMetadata(BaseModel):
    model_config = ConfigDict(extra="forbid", strict=True, frozen=True)

    request_id: UUID
    traceparent: str
    tracestate: str | None = None


async def require_metadata(request: Request) -> RequestMetadata:
    request_id_raw = request.headers.get("X-ST-Request-ID")
    traceparent = request.headers.get("traceparent")
    tracestate = request.headers.get("tracestate")

    if request_id_raw is None or traceparent is None:
        raise AIServiceError(ErrorCode.AI_INVALID_REQUEST)

    try:
        request_id = UUID(request_id_raw)
    except ValueError as exc:
        raise AIServiceError(ErrorCode.AI_INVALID_REQUEST) from exc

    match = _TRACEPARENT_RE.fullmatch(traceparent)
    if match is None or match.group(1) == "0" * 32 or match.group(2) == "0" * 16:
        raise AIServiceError(ErrorCode.AI_INVALID_REQUEST)

    metadata = RequestMetadata(
        request_id=request_id,
        traceparent=traceparent,
        tracestate=tracestate,
    )
    request.state.ai_metadata = metadata
    return metadata
