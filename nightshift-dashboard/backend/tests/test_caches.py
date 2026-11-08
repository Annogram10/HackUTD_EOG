"""Item 12: caches are bounded."""
from app import agent, evidence, risk, triage
from app.lru import LRU


def test_lru_evicts_oldest():
    c = LRU(3)
    for i in range(5):
        c[i] = i
    assert len(c) == 3 and c.get(0) is None and c.get(4) == 4
    c.get(2)
    c[5] = 5
    assert c.get(3) is None and c.get(2) == 2


def test_caches_are_bounded():
    for cache in (triage._cache, risk._ai_cache, risk._timeline_cache, evidence._cache, agent._runs):
        assert isinstance(cache, LRU) and cache.maxsize <= 256
