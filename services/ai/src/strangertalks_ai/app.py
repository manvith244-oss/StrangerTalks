from __future__ import annotations

from fastapi import FastAPI
from fastapi.exceptions import RequestValidationError

from strangertalks_ai.api.errors import AIServiceError, ai_service_error_handler, validation_error_handler
from strangertalks_ai.api.health import router as health_router
from strangertalks_ai.config import Settings
from strangertalks_ai.observability.logging import configure_logging


def create_app(settings: Settings | None = None) -> FastAPI:
    configure_logging()
    app = FastAPI(title="StrangerTalks AI Service", version="1")
    app.state.settings = settings or Settings.from_env()
    app.add_exception_handler(AIServiceError, ai_service_error_handler)
    app.add_exception_handler(RequestValidationError, validation_error_handler)
    app.include_router(health_router)
    return app


app = create_app()
