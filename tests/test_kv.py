import json

import pytest

from app import kv, store
from app.config import settings


class FakeUpstash:
    """Just enough of Upstash's REST API: HGETALL, HSET, HSETNX on one hash."""

    def __init__(self):
        self.hashes: dict[str, dict[str, str]] = {}
        self.calls: list[list[str]] = []

    def post(self, url, headers=None, json=None, timeout=None):
        import httpx

        self.calls.append(json)
        command, key, *rest = json
        data = self.hashes.setdefault(key, {})
        if command == "HGETALL":
            result = [item for pair in data.items() for item in pair]
        elif command == "HSET":
            for field, value in zip(rest[0::2], rest[1::2]):
                data[field] = value
            result = len(rest) // 2
        elif command == "HSETNX":
            field, value = rest
            result = 0 if field in data else 1
            data.setdefault(field, value)
        else:  # pragma: no cover
            raise AssertionError(command)
        return httpx.Response(200, json={"result": result}, request=httpx.Request("POST", url))


@pytest.fixture
def upstash(monkeypatch):
    fake = FakeUpstash()
    monkeypatch.setattr(settings, "kv_rest_api_url", "https://example.upstash.io")
    monkeypatch.setattr(settings, "kv_rest_api_token", "token")
    monkeypatch.setattr(kv.httpx, "post", fake.post)
    return fake


def test_first_read_copies_the_sheet_state_once(upstash, monkeypatch):
    sheet_reads = {"n": 0}

    def sheet_state():
        sheet_reads["n"] += 1
        return {"tasks": [{"id": "1", "title": "Pay rent"}], "have": ["salt"]}

    monkeypatch.setattr(store, "_fetch_app_state", sheet_state)
    assert store._read_app_state() == {"tasks": [{"id": "1", "title": "Pay rent"}], "have": ["salt"]}
    assert store._read_app_state()["have"] == ["salt"]
    assert sheet_reads["n"] == 1
    assert store.app_state_backend() == "upstash"


def test_writes_only_touch_their_own_fields(upstash, monkeypatch):
    monkeypatch.setattr(store, "_fetch_app_state", lambda: {"tasks": [], "medicines": [{"id": "m"}]})
    store._read_app_state()
    store._write_app_state(tasks=[{"id": "t"}])
    state = store._read_app_state()
    assert state["tasks"] == [{"id": "t"}]
    assert state["medicines"] == [{"id": "m"}]
    hset = [call for call in upstash.calls if call[0] == "HSET"]
    assert hset == [["HSET", kv.STATE_KEY, "tasks", json.dumps([{"id": "t"}])]]


def test_copy_never_overwrites_a_newer_save(upstash, monkeypatch):
    # A save landing before the copy wins over older Sheet data.
    upstash.hashes[kv.STATE_KEY] = {}
    monkeypatch.setattr(store, "_fetch_app_state", lambda: {"tasks": ["old"]})

    original = kv._command

    def racing(*args):
        if args[0] == "HSETNX" and args[2] == "tasks":
            upstash.hashes[kv.STATE_KEY]["tasks"] = json.dumps(["new"])
        return original(*args)

    monkeypatch.setattr(kv, "_command", racing)
    assert store._read_app_state()["tasks"] == ["new"]


def test_tasks_round_trip_through_upstash(upstash, monkeypatch):
    monkeypatch.setattr(store, "_fetch_app_state", lambda: {})
    items, lists = store.save_tasks([{"id": "a", "title": "Book flights", "list": "India"}])
    assert store.get_tasks() == (items, lists)


def test_bad_token_says_so(monkeypatch):
    import httpx

    monkeypatch.setattr(settings, "kv_rest_api_url", "https://example.upstash.io")
    monkeypatch.setattr(settings, "kv_rest_api_token", "old")
    monkeypatch.setattr(
        kv.httpx,
        "post",
        lambda *a, **k: httpx.Response(401, json={"error": "WRONGPASS"}, request=httpx.Request("POST", "https://x")),
    )
    with pytest.raises(kv.KVError, match="rejected its token"):
        store._read_app_state()


def test_without_upstash_the_sheet_is_used(monkeypatch):
    monkeypatch.setattr(settings, "kv_rest_api_url", "")
    monkeypatch.setattr(settings, "upstash_redis_rest_url", "")
    assert store.app_state_backend() == "google-sheet"
