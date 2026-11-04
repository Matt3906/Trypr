from fastapi import APIRouter

from app.api import auth, db, files, fn, friends, partners, stays

api_router = APIRouter(prefix="/api")
api_router.include_router(stays.router)
api_router.include_router(partners.router)
api_router.include_router(auth.router)
api_router.include_router(db.router)
api_router.include_router(files.router)
api_router.include_router(friends.router)
api_router.include_router(fn.router)
