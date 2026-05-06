import logging

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from app.api.router import api_router
from app.core.config import get_settings


settings = get_settings()
logger = logging.getLogger(__name__)

app = FastAPI(title=settings.app_name)

origins = [o.strip() for o in settings.cors_origins.split(",") if o.strip()]
allowed_origins = origins or [settings.frontend_base_url, "http://localhost:5173", "http://127.0.0.1:5173"]

logger.info("Configured CORS allow_origins=%s", allowed_origins)
logger.info("Configured Firebase project_id=%s", settings.firebase_project_id)

app.add_middleware(
    CORSMiddleware,
    allow_origins=allowed_origins,
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


@app.get("/")
async def root() -> dict[str, str]:
    return {"service": settings.app_name, "status": "ok"}


@app.get("/healthz")
@app.get("/healthz/", include_in_schema=False)
async def healthcheck() -> dict[str, str]:
    return {"status": "ok"}


app.include_router(api_router)
