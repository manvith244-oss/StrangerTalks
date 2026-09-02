from __future__ import annotations

import os
from typing import Literal

from pydantic import BaseModel, ConfigDict, SecretStr

Capability = Literal["companion", "safety", "trends"]


class Settings(BaseModel):
    model_config = ConfigDict(extra="forbid", strict=True, frozen=True)

    service_credential: SecretStr | None = None
    openai_api_key: SecretStr | None = None
    enabled_capabilities: frozenset[Capability] = frozenset()

    @classmethod
    def from_env(cls) -> "Settings":
        enabled_raw = os.getenv("STRANGERTALKS_AI_ENABLED_CAPABILITIES", "")
        enabled = frozenset(
            part.strip()
            for part in enabled_raw.split(",")
            if part.strip() in {"companion", "safety", "trends"}
        )
        service = os.getenv("STRANGERTALKS_AI_SERVICE_CREDENTIAL")
        provider = os.getenv("OPENAI_API_KEY")
        return cls(
            service_credential=SecretStr(service) if service else None,
            openai_api_key=SecretStr(provider) if provider else None,
            enabled_capabilities=enabled,
        )

    def readiness_errors(self) -> tuple[str, ...]:
        if not self.enabled_capabilities:
            return ()

        errors: list[str] = []
        if self.service_credential is None:
            errors.append("service_credential_missing")
        if self.openai_api_key is None:
            errors.append("provider_credential_missing")
        return tuple(errors)
