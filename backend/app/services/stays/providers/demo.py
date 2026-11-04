"""Deterministic sample data so the whole flow (matching, cheapest-of-N, click-out) works before any
affiliate account exists. Only ever enabled outside production, and every offer is flagged sample=True
so the UI labels it; fabricated prices must never be presented as real ones.
"""

from __future__ import annotations

import asyncio
import hashlib

from app.core.config import get_settings

from ..models import Offer, StayQuery

# (display name per provider is varied on purpose, to exercise the matcher)
_HOTELS = [
    ("Grand Plaza Hotel", "The Grand Plaza", 4.0, 90, 0.004, 0.002),
    ("Riverside Inn", "Riverside Inn & Suites", 3.0, 65, -0.006, 0.003),
    ("Hôtel du Lac", "Hotel Du Lac", 3.0, 80, 0.002, -0.007),
    ("Summit Lodge", "Summit Lodge", 4.0, 120, -0.003, -0.004),
    ("Pinecone Hostel", "Pinecone Hostel", 2.0, 28, 0.007, 0.006),
    ("Harbour View Resort", "Harbor View Resort", 5.0, 210, -0.009, 0.001),
]


class DemoProvider:
    link_hosts = ("example.com",)

    def __init__(self, id: str, label: str, price_bias: float, name_variant: int) -> None:
        self.id, self.label, self.bias, self.variant = id, label, price_bias, name_variant

    def enabled(self) -> bool:
        s = get_settings()
        return s.stays_demo and not s.is_production

    async def search(self, q: StayQuery) -> list[Offer]:
        await asyncio.sleep(0.05)
        offers = []
        for idx, (name_a, name_b, stars, nightly, dlat, dlon) in enumerate(_HOTELS):
            # +/- ~30 m of jitter between providers: same building, slightly different coordinates.
            jitter = (int(hashlib.sha256(f"{self.id}{idx}".encode()).hexdigest()[:4], 16) / 65535 - 0.5) * 0.0005
            wobble = 0.9 + (int(hashlib.sha256(f"{self.id}{idx}{q.check_in}".encode()).hexdigest()[:4], 16) / 65535) * 0.25
            total = round(nightly * q.nights * self.bias * wobble * 100)
            offers.append(
                Offer(
                    provider=self.id, provider_hotel_id=f"{self.id}-{idx}",
                    hotel_name=name_a if self.variant == 0 else name_b,
                    lat=q.lat + dlat + jitter, lon=q.lon + dlon + jitter, total_cents=total, currency=q.currency,
                    url=f"https://example.com/demo/{self.id}/{idx}", stars=stars,
                    free_cancellation=idx % 2 == 0, breakfast=idx % 3 == 0, live=True, sample=True,
                )
            )
        return offers


DEMO_PROVIDERS = [
    DemoProvider("demo_a", "Sample Travel A", 1.00, 0),
    DemoProvider("demo_b", "Sample Travel B", 0.94, 1),
    DemoProvider("demo_c", "Sample Travel C", 1.07, 0),
]
