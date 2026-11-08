"""Item 7: plans are proposals, and an AI sentence with an invented number never reaches the screen."""
import time

from fastapi.testclient import TestClient

import main
from app import risk
from app.handoff import build_handoff, spoken

T = 1791419400
IMPERATIVE_STARTS = ("send ", "shut in ", "dispatch ", "cheapest fix")


def test_spoken_and_action_text_are_proposals():
    tri = main.run_triage(main.ds_for("full_week"), T)
    for a in tri["alerts"]:
        for text in (spoken(a), spoken(a, words=False), a["action_text"]):
            assert "Proposed" in text or "already reached shutdown" in text, text
            for sentence in text.split(". "):
                assert not sentence.strip().lower().startswith(IMPERATIVE_STARTS), sentence
    h = build_handoff(tri)
    assert "Nothing here operates equipment" in h["text"]
    assert "Cheapest fix" not in h["text"] + h["spoken_text"]


def _with_ai(monkeypatch, money_sentence):
    ds = main.ds_for("full_week")
    tri = main.run_triage(ds, T)
    rules = risk.rules_risk(tri)
    risk._ai_cache[risk._ai_key(tri, rules)] = (
        {"available": True, "level": "red", "headline": "", "why": "", "money": money_sentence}, time.time())
    return risk.assess(ds, T, use_ai=True)


def test_invented_number_rejected(monkeypatch):
    out = _with_ai(monkeypatch, "Proposed plan for supervisor approval: send 3 trucks, $1,234.")
    assert out["money"]["from_ai"] is False
    assert out["money"]["text"].startswith("Proposed plan for supervisor approval: $")


def test_spelled_out_invented_number_rejected(monkeypatch):
    out = _with_ai(monkeypatch, "Proposed plan for supervisor approval: send seventeen trucks.")
    assert out["money"]["from_ai"] is False


def test_true_numbers_accepted(monkeypatch):
    ds = main.ds_for("full_week")
    m = risk._money(main.run_triage(ds, T))
    r = m["rows"][0]
    out = _with_ai(monkeypatch, f"Proposed plan for supervisor approval: ${r['cost']:,}. Doing nothing: ${r['do_nothing']:,}.")
    assert out["money"]["from_ai"] is True


def test_numbers_ok_unit():
    allowed = risk.allowed_numbers({"cost": 905, "trucks": 1, "text": "4.3 hours"})
    assert risk.numbers_ok("Send one truck for $905 within 4.3 hours.", allowed)
    assert not risk.numbers_ok("Send two trucks.", allowed)
    assert not risk.numbers_ok("About 5 hours left.", allowed)
