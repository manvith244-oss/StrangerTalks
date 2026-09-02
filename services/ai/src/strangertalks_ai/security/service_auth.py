from __future__ import annotations

import hmac
from typing import Annotated

from fastapi import Depends, Header

from strangertalks_ai.api.dependencies import get_settings
from strangertalks_ai.api.errors import AIServiceError
from strangertalks_ai.config import Settings
from strangertalks_ai.contracts.errors import ErrorCode


async def require_service_auth(
    authorization: Annotated[str | None, Header()] = None,
    settings: Settings = Depends(get_settings),
) -> None:
    expected = settings.service_credential
    if expected is None or authorization is None or not authorization.startswith("Bearer "):
        raise AIServiceError(ErrorCode.AI_AUTH_FAILED)

    supplied = authorization.removeprefix("Bearer ")
    if not hmac.compare_digest(supplied, expected.get_secret_value()):
        raise AIServiceError(ErrorCode.AI_AUTH_FAILED)
