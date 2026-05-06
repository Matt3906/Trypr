#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request
from dataclasses import dataclass
from typing import Any

try:
    import psycopg2
except Exception:  # pragma: no cover
    psycopg2 = None


@dataclass
class Settings:
    cloud_run_url: str
    firebase_id_token: str
    game_id: str
    referee_uid: str
    gcp_project: str
    gcp_region: str
    stalwart_vm: str
    stalwart_zone: str
    db_host: str
    db_port: int
    db_name: str
    db_user: str
    db_password: str


def _env(name: str, default: str | None = None, *, required: bool = False) -> str:
    value = os.getenv(name, default)
    if required and not value:
        raise RuntimeError(f"Missing required environment variable: {name}")
    return value or ""


def load_settings() -> Settings:
    return Settings(
        cloud_run_url=_env("CLOUD_RUN_URL", "https://trypr-backend-kvucn5wbrq-nn.a.run.app"),
        firebase_id_token=_env("FIREBASE_ID_TOKEN", required=True),
        game_id=_env("SMOKE_GAME_ID", required=True),
        referee_uid=_env("SMOKE_REFEREE_UID", required=True),
        gcp_project=_env("GCP_PROJECT", "trypr-5ee47"),
        gcp_region=_env("GCP_REGION", "northamerica-northeast1"),
        stalwart_vm=_env("STALWART_VM_NAME", "trypr-stalwart"),
        stalwart_zone=_env("STALWART_VM_ZONE", "northamerica-northeast1-a"),
        db_host=_env("DB_HOST", required=True),
        db_port=int(_env("DB_PORT", "5432")),
        db_name=_env("DB_NAME", "postgres"),
        db_user=_env("DB_USER", "postgres"),
        db_password=_env("DB_PASSWORD", required=True),
    )


def http_request_json(method: str, url: str, *, headers: dict[str, str] | None = None, body: dict[str, Any] | None = None) -> tuple[int, Any]:
    data = None
    merged_headers = {"Accept": "application/json"}
    if headers:
        merged_headers.update(headers)
    if body is not None:
        data = json.dumps(body).encode("utf-8")
        merged_headers["Content-Type"] = "application/json"

    request = urllib.request.Request(url=url, method=method, headers=merged_headers, data=data)
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            payload = response.read().decode("utf-8")
            parsed = json.loads(payload) if payload else None
            return response.getcode(), parsed
    except urllib.error.HTTPError as error:
        payload = error.read().decode("utf-8", errors="replace")
        parsed: Any
        try:
            parsed = json.loads(payload)
        except Exception:
            parsed = payload
        return error.code, parsed


def _payload_preview(payload: Any) -> str:
    if isinstance(payload, str):
        return payload[:120].replace("\n", " ")
    return str(payload)


def check_health(url_base: str, *, strict_health: bool) -> None:
    slash_status, slash_payload = http_request_json("GET", f"{url_base.rstrip('/')}/healthz/")
    if slash_status != 200:
        raise RuntimeError(
            f"Health check failed for /healthz/: status={slash_status}, payload={_payload_preview(slash_payload)}"
        )
    if not isinstance(slash_payload, dict) or slash_payload.get("status") != "ok":
        raise RuntimeError(f"Health payload mismatch for /healthz/: {slash_payload}")
    print(f"[ok] /healthz/ => 200 {slash_payload}")

    noslash_status, noslash_payload = http_request_json("GET", f"{url_base.rstrip('/')}/healthz")
    if noslash_status == 200:
        if not isinstance(noslash_payload, dict) or noslash_payload.get("status") != "ok":
            raise RuntimeError(f"Health payload mismatch for /healthz: {noslash_payload}")
        print(f"[ok] /healthz => 200 {noslash_payload}")
        return

    if not strict_health and noslash_status == 404:
        print(
            "[warn] /healthz returned 404 from Cloud Run edge; "
            "canonical health endpoint /healthz/ is healthy"
        )
        return

    raise RuntimeError(
        f"Health check failed for /healthz: status={noslash_status}, payload={_payload_preview(noslash_payload)}"
    )


def create_assignment(settings: Settings) -> str:
    url = f"{settings.cloud_run_url.rstrip('/')}/api/ref-portal/assignments"
    status, payload = http_request_json(
        "POST",
        url,
        headers={"Authorization": f"Bearer {settings.firebase_id_token}"},
        body={"game_id": settings.game_id, "referee_uid": settings.referee_uid, "notes": "smoke-and-fire"},
    )
    if status != 201 or not isinstance(payload, dict) or not payload.get("assignment_id"):
        raise RuntimeError(f"Assignment API failed: status={status}, payload={payload}")
    assignment_id = str(payload["assignment_id"])
    print(f"[ok] assignment created: {assignment_id}")
    return assignment_id


def query_assignment(settings: Settings, assignment_id: str) -> tuple[dict[str, Any], str | None]:
    if psycopg2 is None:
        raise RuntimeError("psycopg2 is required. Install with: pip install psycopg2-binary")

    conn = psycopg2.connect(
        host=settings.db_host,
        port=settings.db_port,
        dbname=settings.db_name,
        user=settings.db_user,
        password=settings.db_password,
        connect_timeout=10,
    )
    try:
        with conn.cursor() as cur:
            cur.execute(
                """
                SELECT assignment_id, game_id, referee_uid, status, created_at
                FROM ref_portal.assignments
                WHERE assignment_id = %s
                """,
                (assignment_id,),
            )
            row = cur.fetchone()
            if not row:
                raise RuntimeError(f"Assignment {assignment_id} not found in Cloud SQL")

            cur.execute(
                """
                SELECT email
                FROM ref_portal.users
                WHERE user_id = %s
                """,
                (row[2],),
            )
            user_row = cur.fetchone()
            referee_email = user_row[0] if user_row else None

            print(
                "[ok] Cloud SQL row found: "
                f"assignment_id={row[0]}, game_id={row[1]}, referee_uid={row[2]}, status={row[3]}"
            )
            return {
                "assignment_id": row[0],
                "game_id": row[1],
                "referee_uid": row[2],
                "status": row[3],
                "created_at": row[4].isoformat() if row[4] else None,
            }, referee_email
    finally:
        conn.close()


def check_stalwart_logs(settings: Settings, referee_email: str | None) -> str:
    if not referee_email:
        raise RuntimeError("Referee email not found in SQL; cannot validate queued delivery log")

    command = [
        "gcloud",
        "compute",
        "ssh",
        settings.stalwart_vm,
        f"--project={settings.gcp_project}",
        f"--zone={settings.stalwart_zone}",
        "--tunnel-through-iap",
        "--command",
        "sudo docker exec stalwart-mail sh -lc \"grep -h 'queue.queue-message' /opt/stalwart/logs/stalwart.log* | tail -n 500\"",
    ]

    for attempt in range(1, 8):
        result = subprocess.run(command, capture_output=True, text=True)
        if result.returncode != 0:
            raise RuntimeError(f"Failed to read Stalwart logs: {result.stderr.strip()}")

        matching_lines = [
            line for line in result.stdout.splitlines() if referee_email in line and "queue.queue-message" in line
        ]
        if matching_lines:
            line = matching_lines[-1]
            print(f"[ok] queued delivery line found: {line}")
            return line

        if attempt < 7:
            time.sleep(3)

    raise RuntimeError(f"No queue.queue-message log found for recipient {referee_email}")


def main() -> int:
    parser = argparse.ArgumentParser(description="Smoke & Fire infrastructure verification")
    parser.add_argument(
        "--strict-health",
        action="store_true",
        help="Require both /healthz and /healthz/ to return 200",
    )
    parser.add_argument(
        "--strict-mode",
        action="store_true",
        help="Alias for --strict-health",
    )
    parser.add_argument(
        "--skip-api",
        action="store_true",
        help="Skip authenticated assignment creation (runs health check only)",
    )
    args = parser.parse_args()

    try:
        cloud_run_url = _env("CLOUD_RUN_URL", "https://trypr-backend-kvucn5wbrq-nn.a.run.app")
        print("[step] checking /healthz and /healthz/")
        check_health(cloud_run_url, strict_health=(args.strict_health or args.strict_mode))

        if args.skip_api:
            print("[done] health verification passed (API/DB/SMTP checks skipped by --skip-api)")
            return 0

        settings = load_settings()

        print("[step] creating test assignment")
        assignment_id = create_assignment(settings)

        print("[step] verifying Cloud SQL row")
        _, referee_email = query_assignment(settings, assignment_id)

        print("[step] checking Stalwart queue logs via IAP")
        check_stalwart_logs(settings, referee_email)

        print("[done] infrastructure verification passed")
        return 0
    except Exception as exc:
        print(f"[fail] {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
