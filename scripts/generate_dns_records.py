#!/usr/bin/env python3
from __future__ import annotations

import argparse
import ipaddress


def build_spf(domain: str, mail_host: str, public_ip: str | None) -> str:
    mechanisms = ["v=spf1", f"a:{mail_host}", "mx"]
    if public_ip:
        ip_obj = ipaddress.ip_address(public_ip)
        if ip_obj.is_private:
            print("[warn] private IP provided; SPF cannot publish RFC1918 addresses. Skipping ip4 mechanism.")
        else:
            mechanisms.append(f"ip4:{public_ip}")
    mechanisms.append("-all")
    return " ".join(mechanisms)


def build_dkim(selector: str, dkim_public_key: str) -> str:
    compact_key = "".join(dkim_public_key.split())
    return f"v=DKIM1; k=rsa; p={compact_key}"


def build_dmarc(policy: str, rua: str | None, ruf: str | None) -> str:
    parts = ["v=DMARC1", f"p={policy}", "adkim=s", "aspf=s", "pct=100"]
    if rua:
        parts.append(f"rua=mailto:{rua}")
    if ruf:
        parts.append(f"ruf=mailto:{ruf}")
    parts.append("fo=1")
    return "; ".join(parts)


def main() -> int:
    parser = argparse.ArgumentParser(description="Generate SPF, DKIM, and DMARC TXT records")
    parser.add_argument("--domain", required=True, help="Sending domain, e.g. mail.example.com")
    parser.add_argument("--mail-host", default=None, help="SMTP host FQDN (defaults to mail.<domain>)")
    parser.add_argument("--public-ip", default=None, help="Public egress IP for SMTP (optional)")
    parser.add_argument("--selector", default="stalwart", help="DKIM selector")
    parser.add_argument("--dkim-public-key", required=True, help="DKIM RSA public key (base64, no headers)")
    parser.add_argument("--dmarc-policy", default="quarantine", choices=["none", "quarantine", "reject"])
    parser.add_argument("--rua", default=None, help="Aggregate DMARC report mailbox")
    parser.add_argument("--ruf", default=None, help="Forensic DMARC report mailbox")
    args = parser.parse_args()

    domain = args.domain.strip().lower()
    mail_host = args.mail_host.strip().lower() if args.mail_host else f"mail.{domain}"

    spf = build_spf(domain=domain, mail_host=mail_host, public_ip=args.public_ip)
    dkim = build_dkim(selector=args.selector, dkim_public_key=args.dkim_public_key)
    dmarc = build_dmarc(policy=args.dmarc_policy, rua=args.rua, ruf=args.ruf)

    print("\nDNS TXT records to publish:\n")
    print(f"Host: {domain}")
    print(f"Type: TXT")
    print(f"Value: {spf}\n")

    print(f"Host: {args.selector}._domainkey.{domain}")
    print("Type: TXT")
    print(f"Value: {dkim}\n")

    print(f"Host: _dmarc.{domain}")
    print("Type: TXT")
    print(f"Value: {dmarc}\n")

    print("Note: 10.162.0.2 is a private VPC address and cannot be published directly in public SPF records.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
