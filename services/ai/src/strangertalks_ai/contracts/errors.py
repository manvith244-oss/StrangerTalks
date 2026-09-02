from __future__ import annotations

from enum import StrEnum


class ErrorCode(StrEnum):
    AI_INVALID_REQUEST = "AI_INVALID_REQUEST"
    AI_CONTRACT_UNSUPPORTED = "AI_CONTRACT_UNSUPPORTED"
    AI_AUTH_FAILED = "AI_AUTH_FAILED"
    AI_CAPABILITY_DISABLED = "AI_CAPABILITY_DISABLED"
    AI_PROVIDER_RATE_LIMITED = "AI_PROVIDER_RATE_LIMITED"
    AI_PROVIDER_UNAVAILABLE = "AI_PROVIDER_UNAVAILABLE"
    AI_PROVIDER_TIMEOUT = "AI_PROVIDER_TIMEOUT"
    AI_OUTPUT_REJECTED = "AI_OUTPUT_REJECTED"
    AI_OUTPUT_INVALID = "AI_OUTPUT_INVALID"
    AI_INTERNAL_ERROR = "AI_INTERNAL_ERROR"


HTTP_STATUS_BY_ERROR: dict[ErrorCode, int] = {
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

SANITIZED_ERROR_MESSAGES: dict[ErrorCode, str] = {
    ErrorCode.AI_INVALID_REQUEST: "request rejected",
    ErrorCode.AI_CONTRACT_UNSUPPORTED: "contract unsupported",
    ErrorCode.AI_AUTH_FAILED: "service authentication failed",
    ErrorCode.AI_CAPABILITY_DISABLED: "capability disabled",
    ErrorCode.AI_PROVIDER_RATE_LIMITED: "provider rate limited",
    ErrorCode.AI_PROVIDER_UNAVAILABLE: "provider unavailable",
    ErrorCode.AI_PROVIDER_TIMEOUT: "provider timed out",
    ErrorCode.AI_OUTPUT_REJECTED: "output rejected",
    ErrorCode.AI_OUTPUT_INVALID: "output invalid",
    ErrorCode.AI_INTERNAL_ERROR: "internal service error",
}
