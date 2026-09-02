from __future__ import annotations

from typing import Literal
from uuid import UUID

from pydantic import BaseModel, ConfigDict, Field, model_validator

from .errors import ErrorCode


STRICT_MODEL_CONFIG = ConfigDict(extra="forbid", strict=True)


class EmptyCapabilityPayload(BaseModel):
    model_config = STRICT_MODEL_CONFIG


class BoundaryResult(BaseModel):
    model_config = STRICT_MODEL_CONFIG

    value: str = Field(min_length=1, max_length=128)


class BoundaryEnvelope(BaseModel):
    model_config = STRICT_MODEL_CONFIG

    request_id: UUID
    status: Literal["ok", "error"]
    result: BoundaryResult | None
    error_code: ErrorCode | None
    error_message: str | None = Field(default=None, max_length=256)

    @model_validator(mode="after")
    def validate_status_shape(self) -> "BoundaryEnvelope":
        if self.status == "ok":
            if self.result is None or self.error_code is not None or self.error_message is not None:
                raise ValueError("invalid success envelope")
        elif self.result is not None or self.error_code is None or self.error_message is None:
            raise ValueError("invalid error envelope")
        return self
