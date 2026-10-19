from __future__ import annotations

import re
from dataclasses import dataclass

from app.core.errors import ApiError

_SEG = re.compile(r"^[^/\x00-\x1f]{1,512}$")


def _segments(path: str) -> list[str]:
    if not isinstance(path, str) or not path:
        raise ApiError(400, "Invalid path")
    segs = path.strip("/").split("/")
    for s in segs:
        if not _SEG.match(s) or s in (".", "..") or (s.startswith("__") and s.endswith("__")):
            raise ApiError(400, "Invalid path")
    return segs


@dataclass(frozen=True, slots=True)
class DocPath:
    segs: tuple[str, ...]

    @property
    def path(self) -> str:
        return "/".join(self.segs)

    @property
    def parent(self) -> str:
        return "/".join(self.segs[:-1])

    @property
    def coll(self) -> str:
        return self.segs[-2]

    @property
    def id(self) -> str:
        return self.segs[-1]


def doc_path(path: str) -> DocPath:
    segs = _segments(path)
    if len(segs) % 2 != 0:
        raise ApiError(400, "Path must point at a document")
    return DocPath(tuple(segs))


def coll_path(path: str) -> tuple[str, ...]:
    segs = _segments(path)
    if len(segs) % 2 != 1:
        raise ApiError(400, "Path must point at a collection")
    return tuple(segs)
