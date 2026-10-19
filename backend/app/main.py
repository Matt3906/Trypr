import asyncio
import contextlib
import logging
from urllib.parse import urlparse

from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from starlette.exceptions import HTTPException as StarletteHTTPException

from app.api.router import api_router
from app.core.config import get_settings
from app.core.db import close_pool, get_pool, init_pool
from app.core.errors import CODE_BY_STATUS
from app.core.sessions import purge_expired

settings = get_settings()
logging.basicConfig(
    level=getattr(logging, settings.log_level.upper(), logging.INFO),
    format="%(asctime)s %(levelname)s %(name)s: %(message)s",
)
logger = logging.getLogger(__name__)


async def _janitor() -> None:
    while True:
        await asyncio.sleep(3600)
        try:
            await purge_expired()
        except Exception:  # keep the loop alive
            logger.exception("Session cleanup failed")


@contextlib.asynccontextmanager
async def lifespan(_: FastAPI):
    await init_pool()
    task = asyncio.create_task(_janitor())
    try:
        yield
    finally:
        task.cancel()
        await close_pool()


app = FastAPI(title=settings.app_name, lifespan=lifespan, docs_url=None, redoc_url=None, openapi_url=None)

allowed_origins = settings.cors_origin_list
logger.info("CORS allow_origins=%s", allowed_origins)

# allow_credentials=True so the browser sends the HttpOnly session cookie on cross-origin XHR;
# that forbids a wildcard origin, hence the explicit list.
app.add_middleware(
    CORSMiddleware,
    allow_origins=allowed_origins,
    allow_credentials=True,
    allow_methods=["GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"],
    allow_headers=["Content-Type", "Authorization"],
    max_age=600,
)


@app.middleware("http")
async def origin_guard(request: Request, call_next):
    """CSRF defence in depth: browsers always send Origin on cross-site unsafe requests."""
    if request.method not in ("GET", "HEAD", "OPTIONS"):
        origin = request.headers.get("origin")
        if origin:
            o = urlparse(origin)
            normalised = f"{o.scheme}://{o.netloc}"
            if normalised not in allowed_origins:
                return JSONResponse({"detail": "Origin not allowed", "code": "permission-denied"}, status_code=403)
    response = await call_next(request)
    response.headers.setdefault("X-Content-Type-Options", "nosniff")
    return response


@app.exception_handler(StarletteHTTPException)
async def http_error(_: Request, exc: StarletteHTTPException):
    code = getattr(exc, "code", None) or CODE_BY_STATUS.get(exc.status_code, "internal")
    return JSONResponse(
        {"detail": exc.detail, "message": exc.detail, "code": code},
        status_code=exc.status_code,
        headers=getattr(exc, "headers", None),
    )


@app.exception_handler(RequestValidationError)
async def validation_error(_: Request, exc: RequestValidationError):
    first = exc.errors()[0] if exc.errors() else {}
    loc = ".".join(str(p) for p in first.get("loc", []) if p != "body")
    msg = f"{loc}: {first.get('msg', 'invalid request')}" if loc else first.get("msg", "invalid request")
    return JSONResponse({"detail": msg, "message": msg, "code": "invalid-argument"}, status_code=422)


@app.get("/")
async def root() -> dict[str, str]:
    return {"service": settings.app_name, "status": "ok"}


@app.get("/healthz")
@app.get("/healthz/", include_in_schema=False)
async def healthcheck() -> dict[str, str]:
    await get_pool().fetchval("SELECT 1")
    return {"status": "ok"}


app.include_router(api_router)
