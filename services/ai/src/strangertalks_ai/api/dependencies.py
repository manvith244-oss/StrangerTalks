from __future__ import annotations

from fastapi import Request

from strangertalks_ai.config import Settings


def get_settings(request: Request) -> Settings:
    settings = getattr(request.app.state, "settings", None)
    if settings is None:
        settings = Settings.from_env()
        request.app.state.settings = settings
    return settings
