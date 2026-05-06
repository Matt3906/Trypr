from fastapi import APIRouter

from app.api import ref_portal, trypr

api_router = APIRouter(prefix="/api")
api_router.include_router(trypr.router)
api_router.include_router(ref_portal.router)
