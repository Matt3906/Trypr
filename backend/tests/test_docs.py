from tests.conftest import SERVER_TS, ts


async def test_set_get_roundtrip_and_sentinels(alice):
    path = f"users/{alice.uid}"
    r = await alice.set(path, {"email": "alice@example.com", "createdAt": SERVER_TS, "visited": ["CA"], "n": {"$op": "increment", "n": 2}}, merge=True)
    assert r.status_code == 200
    d = (await alice.get(path)).json()
    assert d["exists"] and d["data"]["email"] == "alice@example.com"
    assert d["data"]["createdAt"]["$ts"].endswith("Z") and len(d["data"]["createdAt"]["$ts"]) == 24
    assert d["data"]["n"] == 2

    # merge keeps other fields; arrayUnion dedupes; arrayRemove; increment; deleteField
    await alice.set(path, {"visited": {"$op": "arrayUnion", "v": ["CA", "US"]}, "n": {"$op": "increment", "n": 3}, "email": {"$op": "deleteField"}}, merge=True)
    d = (await alice.get(path)).json()["data"]
    assert d["visited"] == ["CA", "US"] and d["n"] == 5 and "email" not in d and "createdAt" in d
    await alice.write({"op": "update", "path": path, "data": {"visited": {"$op": "arrayRemove", "v": ["CA"]}}})
    assert (await alice.get(path)).json()["data"]["visited"] == ["US"]


async def test_update_dotted_paths_and_missing(alice):
    path = f"users/{alice.uid}/trips/t1"
    await alice.set(path, {"name": "T", "meta": {"a": 1, "b": 2}})
    await alice.write({"op": "update", "path": path, "data": {"meta.a": 9, "name": "T2"}})
    d = (await alice.get(path)).json()["data"]
    assert d == {"name": "T2", "meta": {"a": 9, "b": 2}}
    r = await alice.write({"op": "update", "path": f"users/{alice.uid}/trips/none", "data": {"x": 1}})
    assert r.status_code == 404


async def test_user_docs_are_private(alice, bob, boss):
    await alice.set(f"users/{alice.uid}", {"email": "alice@example.com"}, merge=True)
    assert (await bob.get(f"users/{alice.uid}")).status_code == 403
    assert (await bob.set(f"users/{alice.uid}", {"x": 1}, merge=True)).status_code == 403
    assert (await boss.get(f"users/{alice.uid}")).status_code == 200  # admin
    # Missing docs just report not-exists
    assert (await bob.get(f"users/{bob.uid}")).json()["exists"] is False


async def test_server_managed_fields_cannot_be_self_granted(alice, boss):
    path = f"users/{alice.uid}"
    await alice.set(path, {"displayName": "Al", "subscription": "premium", "subscriptionStatus": "premium"}, merge=True)
    d = (await alice.get(path)).json()["data"]
    assert d == {"displayName": "Al"}
    # Entitlements are admin-write only
    assert (await alice.set(f"userEntitlements/{alice.uid}", {"subscription": "premium"})).status_code == 403
    assert (await boss.set(f"userEntitlements/{alice.uid}", {"subscription": "premium"})).status_code == 200
    assert (await alice.get(f"userEntitlements/{alice.uid}")).json()["data"]["subscription"] == "premium"


async def test_admin_marker_cannot_be_self_created(alice):
    assert (await alice.set(f"admins/{alice.uid}", {"x": 1})).status_code == 403


async def test_trip_share_and_subcollections(alice, bob, anon):
    trip = f"users/{alice.uid}/trips/t1"
    await alice.set(trip, {"name": "Trip", "sharedWith": [], "createdAt": SERVER_TS})
    assert (await bob.get(trip)).status_code == 403
    assert (await anon.get(trip)).status_code == 403
    assert (await bob.set(f"{trip}/messages/m1", {"senderUid": bob.uid, "text": "hi", "createdAt": SERVER_TS})).status_code == 403

    # share link makes it publicly readable; sharedWith grants edit + chat
    await alice.write({"op": "update", "path": trip, "data": {"shareLinkEnabled": True}})
    assert (await anon.get(trip)).status_code == 200
    await alice.write({"op": "update", "path": trip, "data": {"sharedWith": {"$op": "arrayUnion", "v": [bob.uid]}}})
    assert (await bob.write({"op": "update", "path": trip, "data": {"name": "Renamed"}})).status_code == 200
    assert (await bob.write({"op": "delete", "path": trip})).status_code == 403  # only owner deletes

    ok = await bob.set(f"{trip}/messages/m1", {"senderUid": bob.uid, "text": "hi", "createdAt": SERVER_TS})
    assert ok.status_code == 200
    spoof = await bob.set(f"{trip}/messages/m2", {"senderUid": alice.uid, "text": "hi", "createdAt": SERVER_TS})
    assert spoof.status_code == 403
    toolong = await bob.set(f"{trip}/messages/m3", {"senderUid": bob.uid, "text": "x" * 2001, "createdAt": SERVER_TS})
    assert toolong.status_code == 403
    assert (await bob.write({"op": "update", "path": f"{trip}/messages/m1", "data": {"text": "edit"}})).status_code == 403
    assert (await bob.write({"op": "delete", "path": f"{trip}/messages/m1"})).status_code == 403

    q = await bob.query(path=f"{trip}/messages", orderBy=[["createdAt", "desc"]])
    assert q.status_code == 200 and [d["id"] for d in q.json()["docs"]] == ["m1"]


async def test_expense_and_packing_validation(alice):
    trip = f"users/{alice.uid}/trips/t1"
    await alice.set(trip, {"name": "T"})
    good = {"title": "Gas", "amount": 20, "splitMode": "group", "createdAt": SERVER_TS, "createdByUid": alice.uid}
    assert (await alice.set(f"{trip}/expenses/e1", good)).status_code == 200
    assert (await alice.set(f"{trip}/expenses/e2", {**good, "amount": 0})).status_code == 403
    assert (await alice.set(f"{trip}/expenses/e3", {**good, "splitMode": "weird"})).status_code == 403
    # createdAt/createdByUid immutable on update
    base = (await alice.get(f"{trip}/expenses/e1")).json()["data"]
    assert (await alice.set(f"{trip}/expenses/e1", {**base, "amount": 25})).status_code == 200
    assert (await alice.set(f"{trip}/expenses/e1", {**base, "createdByUid": "someone"})).status_code == 403
    assert (await alice.set(f"{trip}/packing/p1", {"name": "Tent", "createdAt": SERVER_TS})).status_code == 200
    assert (await alice.set(f"{trip}/packing/p2", {"name": "Tent"})).status_code == 403  # createdAt required


async def test_queries_order_where_limit_etag(alice):
    col = f"users/{alice.uid}/trips"
    for i, name in enumerate(["b", "a", "c"]):
        await alice.set(f"{col}/{name}", {"name": name, "n": i, "createdAt": ts(f"2026-01-0{i + 1}T00:00:00.000Z"), "tags": ["x"] if i else ["y"]})
    await alice.set(f"{col}/nofield", {"name": "z"})

    r = (await alice.query(path=col, orderBy=[["createdAt", "desc"]])).json()
    assert [d["id"] for d in r["docs"]] == ["c", "a", "b"]  # doc without the field is excluded
    r2 = (await alice.query(path=col, orderBy=[["n", "asc"]], limit=2)).json()
    assert [d["id"] for d in r2["docs"]] == ["b", "a"]
    assert [d["id"] for d in (await alice.query(path=col, where=[["name", "==", "a"]])).json()["docs"]] == ["a"]
    assert {d["id"] for d in (await alice.query(path=col, where=[["n", ">=", 1]])).json()["docs"]} == {"a", "c"}
    assert {d["id"] for d in (await alice.query(path=col, where=[["tags", "array-contains", "y"]])).json()["docs"]} == {"b"}
    assert {d["id"] for d in (await alice.query(path=col, where=[["name", "in", ["a", "c"]]])).json()["docs"]} == {"a", "c"}

    again = (await alice.query(path=col, orderBy=[["createdAt", "desc"]], etag=r["etag"])).json()
    assert again == {"notModified": True, "etag": r["etag"]}
    await alice.write({"op": "update", "path": f"{col}/a", "data": {"name": "A"}})
    changed = (await alice.query(path=col, orderBy=[["createdAt", "desc"]], etag=r["etag"])).json()
    assert "docs" in changed and changed["etag"] != r["etag"]


async def test_list_permissions(alice, bob, boss, anon):
    await alice.set(f"users/{alice.uid}/trips/t1", {"name": "T", "createdAt": SERVER_TS})
    await alice.set(f"users/{bob.uid}/sharedTrips/t1", {"ownerUid": alice.uid, "tripRef": f"users/{alice.uid}/trips/t1",
                                                        "tripName": "T", "ownerName": "A", "createdAt": SERVER_TS})
    assert (await bob.query(path=f"users/{alice.uid}/trips")).status_code == 403
    assert (await anon.query(path="users")).status_code == 403
    assert (await bob.query(path="users")).status_code == 403
    assert (await boss.query(path="users")).status_code == 200
    assert (await bob.query(group="trips")).status_code == 403
    r = await boss.query(group="trips")
    assert [d["path"] for d in r.json()["docs"]] == [f"users/{alice.uid}/trips/t1"]
    assert (await bob.query(path=f"users/{bob.uid}/sharedTrips")).status_code == 200
    assert (await alice.query(path=f"users/{bob.uid}/sharedTrips")).status_code == 403


async def test_verified_trips_public_read_admin_write(alice, boss, anon):
    assert (await alice.set("verifiedTrips/v1", {"title": "x"})).status_code == 403
    assert (await boss.set("verifiedTrips/v1", {"title": "x", "createdAt": SERVER_TS})).status_code == 200
    assert (await anon.get("verifiedTrips/v1")).json()["exists"] is True
    assert (await anon.query(path="verifiedTrips", orderBy=[["createdAt", "desc"]], limit=3)).status_code == 200


async def test_public_users_and_unlisted_pages(alice, bob, anon, boss):
    await alice.set(f"publicUsers/{alice.uid}", {"displayName": "Al"}, merge=True)
    assert (await bob.get(f"publicUsers/{alice.uid}")).status_code == 200
    assert (await anon.get(f"publicUsers/{alice.uid}")).status_code == 403
    assert (await bob.set(f"publicUsers/{alice.uid}", {"displayName": "Hax"}, merge=True)).status_code == 403

    await boss.set("unlistedPages/p1", {"title": "Page"})
    assert (await anon.get("unlistedPages/p1")).status_code == 200
    assert (await anon.set("unlistedPages/p1", {"title": "Hax"})).status_code == 403
    assert (await anon.set("unlistedPages/p1/responses/r1", {"answer": "yes"})).status_code == 200  # public form submit
    assert (await anon.get("unlistedPages/p1/responses/r1")).status_code == 403
    assert (await boss.get("unlistedPages/p1/responses/r1")).status_code == 200


async def test_join_request_flow(alice, bob):
    trip = f"users/{alice.uid}/trips/t1"
    await alice.set(trip, {"name": "T", "sharedWith": []})
    rid = f"{alice.uid}_t1_{bob.uid}"
    req = {"tripRef": trip, "ownerUid": alice.uid, "tripId": "t1", "requesterUid": bob.uid,
           "requesterName": "Bob", "status": "pending", "createdAt": SERVER_TS}
    assert (await bob.set(f"tripJoinRequests/{rid}", {**req, "status": "approved"})).status_code == 403
    assert (await bob.set(f"tripJoinRequests/{rid}", req)).status_code == 200
    # owner sees requests for the trip, requester sees own, nobody else
    q = await alice.query(path="tripJoinRequests", where=[["tripRef", "==", trip]])
    assert [d["id"] for d in q.json()["docs"]] == [rid]
    assert (await bob.get(f"tripJoinRequests/{rid}")).status_code == 200
    # requester can't approve themselves; owner can, but only status/handledAt
    assert (await bob.write({"op": "update", "path": f"tripJoinRequests/{rid}", "data": {"status": "approved"}})).status_code == 403
    assert (await alice.write({"op": "update", "path": f"tripJoinRequests/{rid}", "data": {"requesterName": "X"}})).status_code == 403
    assert (await alice.write({"op": "update", "path": f"tripJoinRequests/{rid}", "data": {"status": "approved", "handledAt": SERVER_TS}})).status_code == 200
    # owner inbox write for the recipient
    inbox = {"ownerUid": alice.uid, "ownerName": "Al", "tripRef": trip, "tripName": "T", "createdAt": SERVER_TS}
    assert (await alice.set(f"users/{bob.uid}/sharedTrips/t1", inbox, merge=True)).status_code == 200
    assert (await alice.set(f"users/{bob.uid}/sharedTrips/t1", inbox, merge=True)).status_code == 200  # re-share
    assert (await bob.set(f"users/{alice.uid}/sharedTrips/t1", {**inbox, "ownerUid": bob.uid}, merge=True)).status_code == 403


async def test_transaction_preconditions(alice):
    path = f"users/{alice.uid}"
    await alice.set(path, {"friends": []}, merge=True)
    rev = (await alice.get(path)).json()["rev"]
    ok = await alice.write({"op": "set", "path": path, "data": {"friends": ["a"]}, "merge": True},
                           preconditions=[{"path": path, "rev": rev}])
    assert ok.status_code == 200
    stale = await alice.write({"op": "set", "path": path, "data": {"friends": ["b"]}, "merge": True},
                              preconditions=[{"path": path, "rev": rev}])
    assert stale.status_code == 409 and stale.json()["code"] == "aborted"
    assert (await alice.get(path)).json()["data"]["friends"] == ["a"]
    # must-not-exist precondition
    missing = await alice.write({"op": "set", "path": f"{path}/trips/new", "data": {"a": 1}},
                                preconditions=[{"path": f"{path}/trips/new", "rev": None}])
    assert missing.status_code == 200


async def test_batch_is_atomic(alice, bob):
    r = await alice.write(
        {"op": "set", "path": f"users/{alice.uid}/trips/ok", "data": {"a": 1}},
        {"op": "set", "path": f"users/{bob.uid}/trips/nope", "data": {"a": 1}},
    )
    assert r.status_code == 403
    assert (await alice.get(f"users/{alice.uid}/trips/ok")).json()["exists"] is False


async def test_create_only_and_bad_paths(alice):
    p = f"users/{alice.uid}/trips/c1"
    assert (await alice.write({"op": "set", "path": p, "data": {}, "createOnly": True})).status_code == 200
    assert (await alice.write({"op": "set", "path": p, "data": {}, "createOnly": True})).status_code == 409
    assert (await alice.get("users")).status_code == 400  # collection path, not a doc
    assert (await alice.get("users//x")).status_code == 400
    assert (await alice.get("users/../x")).status_code == 400
    assert (await alice.set(p, {"x": {"$op": "bogus"}})).status_code == 400
    assert (await alice.set(p, {"x": {"$ts": "not-a-date"}})).status_code == 400
