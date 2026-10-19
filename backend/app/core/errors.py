from __future__ import annotations

from fastapi import HTTPException

# Maps HTTP status -> the Firebase-style error code the frontend shim exposes as `err.code`.
CODE_BY_STATUS = {
    400: "invalid-argument",
    401: "unauthenticated",
    403: "permission-denied",
    404: "not-found",
    409: "already-exists",
    412: "failed-precondition",
    413: "invalid-argument",
    429: "resource-exhausted",
}


class ApiError(HTTPException):
    def __init__(self, status_code: int, detail: str, code: str | None = None) -> None:
        super().__init__(status_code=status_code, detail=detail)
        self.code = code or CODE_BY_STATUS.get(status_code, "internal")
