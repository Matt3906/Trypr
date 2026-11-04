from __future__ import annotations

from typing import Protocol

from ..models import Offer, StayQuery


class Provider(Protocol):
    """One source of hotel prices. Adding a vendor means adding one file that implements this."""

    id: str
    label: str
    # Domains the deeplinks may point at; the click-out endpoint refuses anything else.
    link_hosts: tuple[str, ...]

    def enabled(self) -> bool:
        """False when credentials are missing; the engine then skips the provider silently."""

    async def search(self, q: StayQuery) -> list[Offer]:
        """Prices for the whole stay, quoted in q.currency. Raise on failure; the engine isolates it."""
