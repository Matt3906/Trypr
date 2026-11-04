from urllib.parse import parse_qs, urlsplit

from app.core.db import get_pool
from app.services import partners


def test_registry_invariants():
    ids = [p.id for p in partners.PARTNERS]
    assert len(ids) == len(set(ids))
    for p in partners.PARTNERS:
        assert p.category in partners.CATEGORIES, p.id
        assert partners.host_allowed(p.url), f"{p.id} must be an https Travelpayouts link"
        assert p.label and p.blurb


def test_every_link_carries_the_partners_own_account_not_someone_elses():
    for p in partners.PARTNERS:
        qs = parse_qs(urlsplit(p.url).query)
        if "shmarker" in qs:
            assert qs["shmarker"] == ["800312"], f"{p.id} is tagged with a different account"


def test_host_check_rejects_lookalikes_and_plain_http():
    assert partners.host_allowed("https://klook.tp.st/abc")
    assert partners.host_allowed("https://tp.st/abc")
    assert not partners.host_allowed("http://klook.tp.st/abc")
    assert not partners.host_allowed("https://evil-tp.st/abc")
    assert not partners.host_allowed("https://tp.st.evil.com/abc")


async def test_partner_list_never_exposes_affiliate_urls(anon):
    r = await anon.http.get("/api/partners")
    assert r.status_code == 200
    body = r.json()["partners"]
    assert {p["id"] for p in body} == {p.id for p in partners.PARTNERS}
    assert "tp.st" not in r.text and "tp.media" not in r.text and "url" not in body[0]


async def test_go_redirects_and_logs_click(alice):
    await get_pool().execute("TRUNCATE partner_clicks")
    r = await alice.http.get("/api/go/klook", params={"from": "Trip Detail!!"}, follow_redirects=False)
    assert r.status_code == 302 and r.headers["location"] == "https://klook.tp.st/kbIoHgS2"
    row = await get_pool().fetchrow("SELECT * FROM partner_clicks")
    assert (row["uid"], row["partner"], row["category"], row["placement"]) == (alice.uid, "klook", "activities", "tripdetail")


async def test_go_works_signed_out_and_rejects_unknown_partner(anon):
    assert (await anon.http.get("/api/go/airalo", follow_redirects=False)).status_code == 302
    for bad in ("nope", "https://evil.test", "..%2Fx"):
        assert (await anon.http.get(f"/api/go/{bad}", follow_redirects=False)).status_code == 404
