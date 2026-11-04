"""Registry of price providers. To add a vendor: write providers/<vendor>.py and list it here."""

from __future__ import annotations

from .base import Provider
from .demo import DEMO_PROVIDERS
from .hotellook import HotellookProvider

ALL_PROVIDERS: list[Provider] = [HotellookProvider(), *DEMO_PROVIDERS]


def enabled_providers() -> list[Provider]:
    return [p for p in ALL_PROVIDERS if p.enabled()]


def link_hosts() -> dict[str, tuple[str, ...]]:
    return {p.id: p.link_hosts for p in ALL_PROVIDERS}
