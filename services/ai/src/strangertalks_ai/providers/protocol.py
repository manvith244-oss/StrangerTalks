from __future__ import annotations

from typing import Protocol, runtime_checkable

import httpx2
from openai import AsyncOpenAI
from pydantic import BaseModel, ConfigDict

OPENAI_STORE = False
OPENAI_MAX_RETRIES = 0


class ProviderResult(BaseModel):
    model_config = ConfigDict(extra="forbid", strict=True)

    value: str


@runtime_checkable
class Provider(Protocol):
    async def generate(self) -> ProviderResult: ...


def create_openai_client(
    *,
    api_key: str,
    http_client: httpx2.AsyncClient,
    timeout_seconds: float,
) -> AsyncOpenAI:
    if timeout_seconds <= 0:
        raise ValueError("timeout_seconds must be positive")
    return AsyncOpenAI(
        api_key=api_key,
        max_retries=OPENAI_MAX_RETRIES,
        timeout=timeout_seconds,
        http_client=http_client,
    )
