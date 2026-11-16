from fastapi.testclient import TestClient

from app import main, store


def _memory_state(monkeypatch):
    state = {}
    monkeypatch.setattr(store, "_read_app_state", lambda: state)
    monkeypatch.setattr(store, "_write_app_state", lambda **updates: state.update(updates))
    return state


def test_tasks_round_trip(monkeypatch):
    _memory_state(monkeypatch)
    client = TestClient(main.app)
    assert client.get("/api/tasks").json() == {"items": [], "lists": ["Home", "Errands", "Trip", "India", "Other"]}
    body = {
        "items": [
            {"id": "a", "title": "  Renew   passport ", "due": "2026-12-01T00:00:00Z", "list": "Trip"},
            {"id": "b", "title": "Water plants", "done": True, "list": "Garden"},
            {"id": "c", "title": "   "},
        ]
    }
    data = client.put("/api/tasks", json=body).json()
    a, b = data["items"]
    assert a["title"] == "Renew passport" and a["due"] == "2026-12-01" and a["list"] == "Trip"
    assert a["done"] is False and a["done_at"] is None and a["created_at"]
    assert b["done"] is True and b["done_at"]
    assert data["lists"] == ["Home", "Errands", "Trip", "India", "Garden", "Other"]
    assert client.get("/api/tasks").json()["items"] == data["items"]


def test_unticking_clears_done_at_and_default_list_is_other(monkeypatch):
    _memory_state(monkeypatch)
    items, _ = store.save_tasks([{"id": "x", "title": "Call bank", "done": False, "done_at": "2026-01-01T00:00:00+00:00"}])
    assert items[0]["done_at"] is None
    assert items[0]["list"] == "Other"


def test_client_list_replaces_saved_lists_but_keeps_used_ones(monkeypatch):
    _memory_state(monkeypatch)
    _, lists = store.save_tasks([{"id": "1", "title": "Pack", "list": "Trip"}], lists=["Work", "Other"])
    assert lists == ["Work", "Trip", "Other"]


def test_overflow_drops_oldest_done_tasks_only(monkeypatch):
    _memory_state(monkeypatch)
    monkeypatch.setattr(store, "_MAX_TASKS", 3)
    items, _ = store.save_tasks([
        {"id": "open1", "title": "a"},
        {"id": "open2", "title": "b"},
        {"id": "old", "title": "c", "done": True, "done_at": "2026-01-01T00:00:00+00:00"},
        {"id": "new", "title": "d", "done": True, "done_at": "2026-06-01T00:00:00+00:00"},
    ])
    assert [t["id"] for t in items] == ["open1", "open2", "new"]
