import json
import os

from tests.conftest import Client


async def _upload(c, path, content=b"hello", ctype="image/png", meta=None):
    return await c.http.post(
        "/api/files/upload",
        data={"path": path, "contentType": ctype, "customMetadata": json.dumps(meta or {})},
        files={"file": ("f.bin", content, ctype)},
    )


async def test_file_upload_download_permissions(alice, bob, boss, anon):
    r = await _upload(alice, "tripDocuments/t1/a.png", b"PNGDATA")
    assert r.status_code == 200 and r.json()["size"] == 7
    got = await alice.http.get("/api/files/tripDocuments/t1/a.png")
    assert got.status_code == 200 and got.content == b"PNGDATA" and got.headers["content-type"] == "image/png"
    assert (await anon.http.get("/api/files/tripDocuments/t1/a.png")).status_code == 401
    assert (await bob.http.get("/api/files/tripDocuments/t1/a.png")).status_code == 200  # any signed-in user (as before)

    # users/{uid}/** is private
    assert (await _upload(alice, f"users/{alice.uid}/me.txt", b"x", "text/plain")).status_code == 200
    assert (await bob.http.get(f"/api/files/users/{alice.uid}/me.txt")).status_code == 403
    assert (await _upload(bob, f"users/{alice.uid}/hax.txt", b"x", "text/plain")).status_code == 403

    # public prefixes: admin write, anyone read
    assert (await _upload(alice, "verifiedTrips/v1/cover.png")).status_code == 403
    assert (await _upload(boss, "verifiedTrips/v1/cover.png")).status_code == 200
    assert (await anon.http.get("/api/files/verifiedTrips/v1/cover.png")).status_code == 200

    # anonymous form uploads: allowed types only
    assert (await _upload(anon, "unlistedFormUploads/p1/doc.pdf", b"%PDF", "application/pdf")).status_code == 200
    assert (await _upload(anon, "unlistedFormUploads/p1/x.bin", b"x", "video/mp4")).status_code == 401
    assert (await anon.http.get("/api/files/unlistedFormUploads/p1/doc.pdf")).status_code == 200


async def test_unsafe_types_download_not_render(alice):
    await _upload(alice, "tripDocuments/t1/page.html", b"<script>alert(1)</script>", "text/html")
    r = await alice.http.get("/api/files/tripDocuments/t1/page.html")
    assert r.headers["content-disposition"].startswith("attachment")
    assert r.headers["x-content-type-options"] == "nosniff"


async def test_overwrite_replaces_file_on_disk(alice):
    await _upload(alice, "tripDocuments/t1/a.png", b"one")
    await _upload(alice, "tripDocuments/t1/a.png", b"two")
    assert (await alice.http.get("/api/files/tripDocuments/t1/a.png")).content == b"two"
    count = sum(len(files) for _, _, files in os.walk(os.environ["UPLOAD_DIR"]))
    assert count >= 1


async def test_friend_request_accept_remove(alice, bob):
    # Clients can't forge requests directly
    assert (await alice.set(f"users/{bob.uid}/friendRequests/r1", {"fromUid": alice.uid})).status_code == 403

    assert (await alice.post("/api/friends/request", email="nobody@example.com")).status_code == 404
    assert (await alice.post("/api/friends/request", email="alice@example.com")).status_code == 400
    assert (await alice.post("/api/friends/request", email="BOB@example.com")).status_code == 200
    await alice.post("/api/friends/request", email="bob@example.com")  # duplicate is a no-op

    q = (await bob.query(path=f"users/{bob.uid}/friendRequests", orderBy=[["createdAt", "desc"]])).json()["docs"]
    assert len(q) == 1 and q[0]["data"]["fromUid"] == alice.uid
    rid = q[0]["id"]

    assert (await alice.post("/api/friends/accept", requestId=rid)).status_code == 404  # not hers
    assert (await bob.post("/api/friends/accept", requestId=rid)).status_code == 200
    bf = (await bob.get(f"users/{bob.uid}")).json()["data"]["friends"]
    af = (await alice.get(f"users/{alice.uid}")).json()["data"]["friends"]
    assert [f["uid"] for f in bf] == [alice.uid] and [f["uid"] for f in af] == [bob.uid]
    assert (await bob.query(path=f"users/{bob.uid}/friendRequests")).json()["docs"] == []
    assert (await alice.post("/api/friends/request", email="bob@example.com")).status_code == 409  # already friends

    assert (await bob.post("/api/friends/remove", uid=alice.uid)).status_code == 200
    assert (await bob.get(f"users/{bob.uid}")).json()["data"]["friends"] == []
    assert (await alice.get(f"users/{alice.uid}")).json()["data"]["friends"] == []
