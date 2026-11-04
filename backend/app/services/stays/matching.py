"""Entity resolution: decide which offers from different providers are the same physical hotel.

This is the part that makes "cheapest across all sites" meaningful. Two offers match when they are
close together AND their names are similar; the allowed distance shrinks as the name match weakens.
Candidates come from a spatial grid so the cost stays roughly linear in the number of offers, and
clusters are built with union-find, so the result does not depend on the order providers answered in.
"""

from __future__ import annotations

import math
import re
import unicodedata
from collections import defaultdict
from difflib import SequenceMatcher

from .models import Offer

# Words that carry no identity ("Hotel Le Marais" vs "Le Marais").
_STOP = {"the", "a", "an", "and", "by", "at", "of", "de", "la", "le", "el", "hotel", "hotels", "hostel"}
_CELL_M = 400.0
_EARTH_R_M = 6_371_000.0

# (max distance m, min name similarity)
_TIERS = ((120.0, 0.60), (400.0, 0.85))


def name_tokens(name: str) -> tuple[str, ...]:
    ascii_ = unicodedata.normalize("NFKD", name).encode("ascii", "ignore").decode().casefold()
    words = re.sub(r"[^a-z0-9]+", " ", ascii_).split()
    return tuple(w for w in words if w not in _STOP) or tuple(words)


def name_similarity(a: tuple[str, ...], b: tuple[str, ...]) -> float:
    if not a or not b:
        return 0.0
    sa, sb = set(a), set(b)
    jaccard = len(sa & sb) / len(sa | sb)
    # Order-insensitive character ratio catches "Grand Plaza" ~ "Plaza Grand" and small typos.
    ratio = SequenceMatcher(None, " ".join(sorted(a)), " ".join(sorted(b))).ratio()
    return max(jaccard, ratio)


def haversine_m(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dp, dl = p2 - p1, math.radians(lon2 - lon1)
    h = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * _EARTH_R_M * math.asin(math.sqrt(h))


def _same_hotel(a: Offer, ta: tuple[str, ...], b: Offer, tb: tuple[str, ...]) -> bool:
    if a.stars is not None and b.stars is not None and abs(a.stars - b.stars) > 1:
        return False
    dist = haversine_m(a.lat, a.lon, b.lat, b.lon)
    sim = name_similarity(ta, tb)
    return any(dist <= max_dist and sim >= min_sim for max_dist, min_sim in _TIERS)


class _UnionFind:
    def __init__(self, n: int) -> None:
        self.parent = list(range(n))

    def find(self, x: int) -> int:
        while self.parent[x] != x:
            self.parent[x] = self.parent[self.parent[x]]
            x = self.parent[x]
        return x

    def union(self, a: int, b: int) -> None:
        ra, rb = self.find(a), self.find(b)
        if ra != rb:
            self.parent[max(ra, rb)] = min(ra, rb)


def cluster_offers(offers: list[Offer]) -> list[list[Offer]]:
    """Groups offers describing the same hotel. Clusters and the offers in them keep input order."""
    n = len(offers)
    if n == 0:
        return []
    lat0 = sum(o.lat for o in offers) / n
    kx = math.radians(1) * _EARTH_R_M * math.cos(math.radians(lat0))
    ky = math.radians(1) * _EARTH_R_M

    tokens = [name_tokens(o.hotel_name) for o in offers]
    grid: dict[tuple[int, int], list[int]] = defaultdict(list)
    cells: list[tuple[int, int]] = []
    for i, o in enumerate(offers):
        cell = (int(o.lon * kx // _CELL_M), int(o.lat * ky // _CELL_M))
        cells.append(cell)
        grid[cell].append(i)

    uf = _UnionFind(n)
    for i in range(n):
        cx, cy = cells[i]
        for dx in (-1, 0, 1):
            for dy in (-1, 0, 1):
                for j in grid.get((cx + dx, cy + dy), ()):
                    if j > i and uf.find(i) != uf.find(j) and _same_hotel(offers[i], tokens[i], offers[j], tokens[j]):
                        uf.union(i, j)

    groups: dict[int, list[Offer]] = {}
    for i, o in enumerate(offers):
        groups.setdefault(uf.find(i), []).append(o)
    return list(groups.values())
