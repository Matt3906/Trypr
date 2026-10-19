"""aiSuggest's Claude path, with the Anthropic client stubbed (no network)."""

from types import SimpleNamespace

import pytest

from app.core.config import get_settings
from app.services import ai
from tests.conftest import Client

SUGGEST = {"module": "accommodations", "destinationName": "Banff, Alberta", "lat": 51.17, "lon": -115.57,
           "startDate": "2026-07-01", "endDate": "2026-07-05", "preferences": {"stayType": "hostel"}}


class FakeMessages:
    def __init__(self, outcome):
        self.outcome, self.calls = outcome, []

    async def create(self, **kw):
        self.calls.append(kw)
        if isinstance(self.outcome, Exception):
            raise self.outcome
        return self.outcome


def install(monkeypatch, outcome):
    fake = FakeMessages(outcome)
    monkeypatch.setattr(get_settings(), "anthropic_api_key", "sk-test")
    monkeypatch.setattr(ai.anthropic, "AsyncAnthropic", lambda **kw: SimpleNamespace(messages=fake))
    return fake


def reply(text, stop="end_turn"):
    return SimpleNamespace(stop_reason=stop, content=[SimpleNamespace(type="text", text=text)])


async def call(boss):
    r = await boss.http.post("/api/fn/aiSuggest", json={"data": SUGGEST})
    assert r.status_code == 200, r.text
    return r.json()["data"]["suggestions"]


async def test_claude_json_is_parsed_and_sanitised(boss, monkeypatch):
    fake = install(monkeypatch, reply('```json\n[{"name":"Mountain Hostel","address":"1 Main","price_estimate":"55","rating":9,"stayType":"hostel"},{"name":"B","rating":"x"}]\n```'))
    s = await call(boss)
    assert s[0] == {"name": "Mountain Hostel", "address": "1 Main", "price": 55.0, "rating": 5.0, "stayType": "hostel"}
    assert s[1]["rating"] == 0.0 and s[1]["price"] == 0.0
    kw = fake.calls[0]
    assert kw["model"] == get_settings().ai_model and "stay_type=hostel" in kw["messages"][0]["content"]
    assert kw["system"] == ai.SYSTEM_ACCOMMODATIONS and kw["extra_body"] == {"output_config": {"effort": "low"}}
    assert "temperature" not in kw and "thinking" not in kw  # rejected/removed on current models


@pytest.mark.parametrize("outcome", [reply("not json"), reply("[]", stop="refusal"), reply("[]", stop="max_tokens"), RuntimeError("boom")])
async def test_any_failure_falls_back(boss, monkeypatch, outcome):
    install(monkeypatch, outcome)
    s = await call(boss)
    assert len(s) == 3 and all(x["stayType"] == "hostel" for x in s)


def test_city_label_strips_regions_streets_and_pois():
    assert ai.city_label("123 Main St, Banff, Alberta, Canada") == "Banff"
    assert ai.city_label("Banff National Park, Banff, Alberta") == "Banff"
    assert ai.city_label("Ontario") == "Nearby City" and ai.city_label("") == "Nearby City"
