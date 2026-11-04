"""Data types shared by the stay-price providers, the matcher and the engine."""

from __future__ import annotations

from dataclasses import dataclass
from datetime import date


@dataclass(frozen=True)
class StayQuery:
    """One search. Frozen + hashable: it is also the cache key (with the provider id)."""

    lat: float
    lon: float
    check_in: date
    check_out: date
    adults: int = 2
    currency: str = "USD"  # ISO 4217, upper case. Providers must quote in this currency.
    radius_km: float = 15.0
    name: str = ""  # human label for the area ("Banff"); some providers search by name, not coordinates

    @property
    def nights(self) -> int:
        return (self.check_out - self.check_in).days


@dataclass(frozen=True)
class Offer:
    """One provider's price for one hotel. Money is integer minor units (cents) to keep sums exact."""

    provider: str
    provider_hotel_id: str
    hotel_name: str
    lat: float
    lon: float
    total_cents: int  # whole stay, for the party in the query
    currency: str
    url: str  # partner deeplink (affiliate-tagged). Never sent to the browser as-is; see links.py
    stars: float | None = None
    address: str | None = None
    image: str | None = None
    taxes_included: bool | None = None  # None = provider does not say
    free_cancellation: bool | None = None
    breakfast: bool | None = None
    # True: a real-time quote. False: a cached "from" price that the partner re-checks on click-out.
    live: bool = False
    # True only for the dev-mode demo provider, so the UI can never pass sample data off as real.
    sample: bool = False


@dataclass
class ProviderResult:
    status: str  # "ok" | "error"
    offers: list[Offer]
    error: str | None = None
