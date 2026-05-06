#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
from dataclasses import asdict, dataclass


@dataclass(slots=True)
class DnsRecord:
    host: str
    record_type: str
    value: str
    ttl: int


def _normalize_domain(domain: str) -> str:
    value = domain.strip().lower().rstrip(".")
    if not value or "." not in value:
        raise ValueError("A valid sending domain is required (for example: refportal.trypr.com)")
    return value


def build_records(
    *,
    domain: str,
    stalwart_ip: str,
    dkim_selector: str,
    dkim_public_key: str,
    dmarc_policy: str,
    rua_email: str | None,
    ttl: int,
) -> list[DnsRecord]:
    normalized_domain = _normalize_domain(domain)

    spf_value = f"v=spf1 ip4:{stalwart_ip} -all"
    dkim_value = f"v=DKIM1; k=rsa; p={dkim_public_key.strip()}"

    dmarc_parts = [
        "v=DMARC1",
        f"p={dmarc_policy}",
        "adkim=s",
        "aspf=s",
        "fo=1",
        "pct=100",
    ]
    if rua_email:
        dmarc_parts.append(f"rua=mailto:{rua_email.strip()}")
    dmarc_value = "; ".join(dmarc_parts)

    return [
        DnsRecord(host=normalized_domain, record_type="TXT", value=spf_value, ttl=ttl),
        DnsRecord(
            host=f"{dkim_selector.strip()}._domainkey.{normalized_domain}",
            record_type="TXT",
            value=dkim_value,
            ttl=ttl,
        ),
        DnsRecord(host=f"_dmarc.{normalized_domain}", record_type="TXT", value=dmarc_value, ttl=ttl),
    ]


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Generate SPF, DKIM, and DMARC TXT records for Stalwart-backed outbound email"
    )
    parser.add_argument("--domain", required=True, help="Sending domain (for example: refportal.trypr.com)")
    parser.add_argument(
        "--stalwart-ip",
        default="10.162.0.2",
        help="Stalwart SMTP host IP to authorize in SPF (default: 10.162.0.2)",
    )
    parser.add_argument("--dkim-selector", default="mail", help="DKIM selector prefix (default: mail)")
    parser.add_argument(
        "--dkim-public-key",
        required=True,
        help="DKIM RSA public key (single line, omit BEGIN/END markers)",
    )
    parser.add_argument(
        "--dmarc-policy",
        default="quarantine",
        choices=["none", "quarantine", "reject"],
        help="DMARC policy (default: quarantine)",
    )
    parser.add_argument(
        "--rua-email",
        default=None,
        help="Optional aggregate-report mailbox for DMARC rua=mailto:<email>",
    )
    parser.add_argument("--ttl", type=int, default=3600, help="DNS TTL in seconds (default: 3600)")
    parser.add_argument(
        "--json",
        action="store_true",
        help="Print machine-readable JSON instead of table output",
    )
    args = parser.parse_args()

    records = build_records(
        domain=args.domain,
        stalwart_ip=args.stalwart_ip,
        dkim_selector=args.dkim_selector,
        dkim_public_key=args.dkim_public_key,
        dmarc_policy=args.dmarc_policy,
        rua_email=args.rua_email,
        ttl=args.ttl,
    )

    if args.json:
        print(json.dumps([asdict(record) for record in records], indent=2))
    else:
        print("DNS records to publish:\n")
        for record in records:
            print(f"Host:  {record.host}")
            print(f"Type:  {record.record_type}")
            print(f"TTL:   {record.ttl}")
            print(f"Value: {record.value}\n")

    print(
        "Note: If this domain sends mail to the public internet, make sure the SPF IP "
        "is the externally visible egress IP used by Stalwart."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
