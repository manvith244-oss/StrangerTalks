from __future__ import annotations

from fastapi import APIRouter, Depends
from fastapi.responses import JSONResponse

from strangertalks_ai.api.dependencies import get_settings
from strangertalks_ai.config import Settings

router = APIRouter(tags=["health"])


@router.get("/health/live")
async def live() -> dict[str, str]:
    return {"status": "live"}


@router.get("/health/ready")
async def ready(settings: Settings = Depends(get_settings)) -> JSONResponse:
    if settings.readiness_errors():
        return JSONResponse(status_code=503, content={"status": "not_ready"})
    return JSONResponse(status_code=200, content={"status": "ready"})
