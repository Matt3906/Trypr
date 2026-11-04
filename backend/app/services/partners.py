"""Affiliate partners shown to users as trip essentials (flights, car rental, eSIM, tours, ...).

The registry is the single source of truth. The API publishes labels and blurbs but never the affiliate URL:
/api/go/<id> looks the URL up here and redirects, so it cannot be abused as an open redirect and a link can
be swapped without redeploying the website. Add a partner by adding one entry; tests enforce the invariants.
"""

from __future__ import annotations

from dataclasses import dataclass
from urllib.parse import urlsplit

# Travelpayouts tracking domains. Every affiliate URL must be https on one of these.
ALLOWED_HOSTS = ("tp.st", "tp.media")

CATEGORIES: dict[str, str] = {
    "activities": "Things to do",
    "car": "Rent a car",
    "flights": "Book flights",
    "transfer": "Airport transfers",
    "esim": "Stay connected abroad",
    "luggage": "Store your bags",
    "bike": "Rent a bike or scooter",
    "claims": "Flight delayed or cancelled?",
}


@dataclass(frozen=True)
class Partner:
    id: str
    label: str
    category: str
    blurb: str
    url: str
    # Ranked higher when the trip is in one of these regions ("europe", "asia"); still shown elsewhere.
    prefer_regions: tuple[str, ...] = ()
    # Shown only when the trip touches one of these regions. Empty = worldwide.
    only_regions: tuple[str, ...] = ()


# Order within a category is the default ranking (best first).
PARTNERS: tuple[Partner, ...] = (
    Partner("tiqets", "Tiqets", "activities", "Museums, attractions and city sights, instant mobile tickets", "https://tiqets.tp.st/U14gZqLf"),
    Partner("klook", "Klook", "activities", "Tours, attractions and local experiences", "https://klook.tp.st/kbIoHgS2", prefer_regions=("asia",)),
    Partner("kkday", "KKday", "activities", "Tours, activities and tickets", "https://kkday.tp.st/L9aEcfnL", prefer_regions=("asia",)),
    Partner("gocity", "Go City", "activities", "One pass for many city attractions", "https://gocity.tp.st/d8D2lOZI"),
    Partner("wegotrip", "WeGoTrip", "activities", "Audio tours and guided experiences on your phone", "https://wegotrip.tp.st/i1Zt9HBs"),

    Partner("localrent", "Localrent", "car", "Car rental from local suppliers, strong in Europe", "https://localrent.tp.st/OdcmGBXW", prefer_regions=("europe",)),
    Partner("autoeurope", "Auto Europe", "car", "Car rental across Europe and the UK", "https://autoeurope.tp.st/zDsAEsEe", prefer_regions=("europe",), only_regions=("europe",)),
    Partner("economybookings", "EconomyBookings", "car", "Compare car rental prices worldwide", "https://economybookings.tp.st/KUFWPxfz"),
    Partner("getrentacar", "GetRentacar", "car", "Car rental comparison and booking", "https://getrentacar.tp.st/fugpZBpa"),
    Partner("qeeq", "QEEQ", "car", "Car rental with a savings membership", "https://qeeq.tp.st/17kD6E1r"),

    Partner("aviasales", "Aviasales", "flights", "Flight search across airlines", "https://aviasales.tp.st/u4TJYAuI"),
    Partner("kiwi", "Kiwi.com", "flights", "Flights, including creative multi-airline routes", "https://tp.media/click?shmarker=800312&promo_id=3673&source_type=link&type=click&campaign_id=111&sub_id=trypr"),

    Partner("kiwitaxi", "Kiwitaxi", "transfer", "Prebooked airport transfers and private rides", "https://kiwitaxi.tp.st/tfJYSEin"),
    Partner("welcomepickups", "Welcome Pickups", "transfer", "Airport pickup with a meet-and-greet driver", "https://tp.st/QXBtjigi"),
    Partner("gettransfer", "GetTransfer", "transfer", "Drivers bid on your transfer request", "https://gettransfer.tp.st/9gInoss1"),
    Partner("intui", "Intui Travel", "transfer", "Transfer and taxi booking marketplace", "https://intui.tp.st/lHjMQOUz"),

    Partner("airalo", "Airalo", "esim", "eSIM data plans for 200+ destinations", "https://airalo.tp.st/Sa5Ye3vW"),
    Partner("saily", "Saily", "esim", "Travel eSIM from the makers of NordVPN", "https://saily.tp.st/AZvx1B2e"),
    Partner("yesim", "Yesim", "esim", "eSIM data for travel abroad", "https://yesim.tp.st/0gIsyvu3"),
    Partner("gigsky", "GigSky", "esim", "Travel eSIM and data plans in many countries", "https://tp.media/click?shmarker=800312&promo_id=9150&source_type=link&type=click&campaign_id=636&sub_id=trypr"),
    Partner("drimsim", "Drimsim", "esim", "Travel SIM with one number and global roaming", "https://drimsim.tp.st/TvnvH7Yx"),

    Partner("radicalstorage", "Radical Storage", "luggage", "Luggage storage near the sights, so you can explore hands-free", "https://radicalstorage.tp.st/YDYwJVEC"),
    Partner("bikesbooking", "BikesBooking", "bike", "Motorcycle, scooter and bike rentals worldwide", "https://bikesbooking.tp.st/zItKiIlv"),
    Partner("airhelp", "AirHelp", "claims", "Claim compensation for delayed or cancelled flights", "https://airhelp.tp.st/QqDv5FR5"),
    Partner("compensair", "Compensair", "claims", "Flight compensation claims, fixed fee per claim", "https://compensair.tp.st/Cp5ac0i2"),
)

BY_ID: dict[str, Partner] = {p.id: p for p in PARTNERS}


def host_allowed(url: str) -> bool:
    parts = urlsplit(url)
    host = (parts.hostname or "").lower()
    return parts.scheme == "https" and any(host == h or host.endswith("." + h) for h in ALLOWED_HOSTS)


def public_view() -> list[dict]:
    """What the browser may see. Deliberately excludes the affiliate URL."""
    return [
        {"id": p.id, "label": p.label, "category": p.category, "categoryTitle": CATEGORIES[p.category], "blurb": p.blurb,
         "preferRegions": list(p.prefer_regions), "onlyRegions": list(p.only_regions)}
        for p in PARTNERS
    ]
