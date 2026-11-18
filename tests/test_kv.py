import json

import pytest

from app import kv, store
from app.config import settings


class FakeUpstash:
    """Just enough of Upstash's REST API for app/kv.py."""

    def __init__(self):
        self.hashes: dict[str, dict[str, str]] = {}
        self.strings: dict[str, str] = {}
        self.lists: dict[str, list[str]] = {}
        self.calls: list[list[str]] = []

    def run(self, command, key, *rest):
        data = self.hashes.setdefault(key, {})
        lst = self.lists.setdefault(key, [])
        if command == "HGETALL":
            return [item for pair in data.items() for item in pair]
        if command == "HSET":
            for field, value in zip(rest[0::2], rest[1::2]):
                data[field] = value
            return len(rest) // 2
        if command == "HSETNX":
            field, value = rest
            created = field not in data
            data.setdefault(field, value)
            return int(created)
        if command == "HGET":
            return data.get(rest[0])
        if command == "HDEL":
            return int(data.pop(rest[0], None) is not None)
        if command == "GET":
            return self.strings.get(key)
        if command == "SET":
            if "NX" in rest and key in self.strings:
                return None
            self.strings[key] = rest[0]
            return "OK"
        if command == "DEL":
            existed = key in self.strings
            self.strings.pop(key, None)
            return int(existed)
        if command == "INCR":
            self.strings[key] = str(int(self.strings.get(key, "0")) + 1)
            return int(self.strings[key])
        if command == "RPUSH":
            lst.extend(rest)
            return len(lst)
        if command == "LPUSH":
            for value in rest:
                lst.insert(0, value)
            return len(lst)
        if command == "LTRIM":
            start, stop = int(rest[0]), int(rest[1])
            n = len(lst)
            start = max(n + start, 0) if start < 0 else start
            stop = n + stop if stop < 0 else stop
            lst[:] = lst[start : stop + 1]
            return "OK"
        if command == "LRANGE":
            start, stop = int(rest[0]), int(rest[1])
            n = len(lst)
            start = max(n + start, 0) if start < 0 else start
            stop = n + stop if stop < 0 else stop
            return lst[start : stop + 1]
        raise AssertionError(command)

    def post(self, url, headers=None, json=None, timeout=None):
        import httpx

        self.calls.append(json)
        result = self.run(*json)
        return httpx.Response(200, json={"result": result}, request=httpx.Request("POST", url))


@pytest.fixture
def upstash(monkeypatch):
    fake = FakeUpstash()
    monkeypatch.setattr(settings, "kv_rest_api_url", "https://example.upstash.io")
    monkeypatch.setattr(settings, "kv_rest_api_token", "token")
    monkeypatch.setattr(kv.httpx, "post", fake.post)
    kv._migrated.clear()
    yield fake
    kv._migrated.clear()


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


SHEET_ROWS = [
    {"Title": "Dal", "Ingredients": "- 1 cup lentils", "Steps": "1. Boil", "Source": "https://example.com/dal",
     "Confidence": "high", "Saved at": "2026-01-01 10:00 UTC", "Tags": "Indian", "Favorite": "TRUE",
     "Notes": "", "Course": "Main course", "Photo": ""},
    {"Title": "", "Ingredients": "", "Steps": "", "Source": "", "Confidence": "", "Saved at": "",
     "Tags": "", "Favorite": "", "Notes": "", "Course": "", "Photo": ""},  # a deleted row
    {"Title": "Brownies", "Ingredients": "- chocolate", "Steps": "1. Bake", "Source": "",
     "Confidence": "high", "Saved at": "2026-02-01 10:00 UTC", "Tags": "", "Favorite": "",
     "Notes": "", "Course": "Desserts", "Photo": "abc"},
]


def test_recipes_are_copied_with_their_sheet_row_ids(upstash, monkeypatch):
    monkeypatch.setattr(store, "_sheet_recipe_rows", lambda: SHEET_ROWS)
    recipes = store.list_recipes()
    assert [(r["id"], r["title"]) for r in recipes] == [(4, "Brownies"), (2, "Dal")]
    assert recipes[1]["favorite"] is True and recipes[0]["photo_id"] == "abc"
    assert store.get_recipe(2)["ingredients"] == ["1 cup lentils"]
    assert store.get_recipe(3) is None  # the deleted row stays gone
    assert store.source_exists("https://example.com/dal")


def test_new_recipes_continue_after_the_last_sheet_row_and_ids_are_never_reused(upstash, monkeypatch):
    monkeypatch.setattr(store, "_sheet_recipe_rows", lambda: SHEET_ROWS)
    created = store.create_recipe(title="Toast", ingredients=["bread"], steps=["toast"],
                                  course="Main course", tags=[], notes="")
    assert created["id"] == 5
    assert store.delete_recipe(5)
    assert store.get_recipe(5) is None
    again = store.create_recipe(title="Tea", ingredients=["tea"], steps=["brew"],
                                course="Main course", tags=[], notes="")
    assert again["id"] == 6


def test_editing_a_recipe_keeps_untouched_fields(upstash, monkeypatch):
    monkeypatch.setattr(store, "_sheet_recipe_rows", lambda: SHEET_ROWS)
    updated = store.update_recipe(2, favorite=False, notes="extra salt")
    assert updated["favorite"] is False and updated["notes"] == "extra salt"
    fresh = store.get_recipe(2)
    assert fresh["favorite"] is False and fresh["notes"] == "extra salt"
    assert fresh["tags"] == ["indian"] and fresh["saved_at"] == "2026-01-01 10:00 UTC"


def test_the_sheet_is_read_once_for_recipes(upstash, monkeypatch):
    reads = {"n": 0}

    def rows():
        reads["n"] += 1
        return SHEET_ROWS

    monkeypatch.setattr(store, "_sheet_recipe_rows", rows)
    store.list_recipes()
    kv._migrated.clear()  # a fresh server instance still sees the marker
    store.list_recipes()
    store.get_recipe(2)
    assert reads["n"] == 1


def test_import_log_is_copied_then_appended(upstash, monkeypatch):
    sheet_log = [
        ["timestamp", "url", "status", "reason", "used_backup", "model"],
        ["01-11-2026 10:00 CET", "https://a", "saved", "Dal", "FALSE", "gemini-3.6-flash"],
    ]
    monkeypatch.setattr(store, "_sheet_import_log_values", lambda: sheet_log)
    store.log_import("https://b", "error", "Apify found nothing at that link.")
    rows = store.get_recent_imports()
    assert [row["url"] for row in rows] == ["https://b", "https://a"]
    assert rows[1]["timestamp"] == "01-11-26 10:00 CET"
    assert rows[0]["status"] == "error"


def test_health_reports_upstash(upstash):
    from fastapi.testclient import TestClient

    from app import main

    assert TestClient(main.app).get("/health").json()["storage"] == "upstash"


def test_new_photos_are_stored_in_the_database(upstash, monkeypatch):
    from fastapi.testclient import TestClient

    from app import main

    monkeypatch.setattr(store, "_sheet_recipe_rows", lambda: SHEET_ROWS)
    jpeg = b"\xff\xd8\xff" + b"x" * 1000
    created = store.create_recipe(title="Mom's dal", ingredients=["dal"], steps=["cook"],
                                  course="Main course", tags=[], notes="", photo_bytes=jpeg)
    assert created["photo_id"].startswith("kv:")
    response = TestClient(main.app).get(f"/api/recipes/{created['id']}/photo")
    assert response.status_code == 200 and response.content == jpeg
    assert response.headers["content-type"] == "image/jpeg"
    old_id = created["photo_id"]
    replaced = store.update_recipe(created["id"], photo_bytes=b"\xff\xd8\xffnew")
    assert replaced["photo_id"] != old_id
    assert kv.get_photo(old_id) is None  # the replaced photo is deleted
    store.delete_recipe(created["id"])
    assert kv.get_photo(replaced["photo_id"]) is None


def test_an_old_drive_photo_is_copied_on_first_view(upstash, monkeypatch):
    from app import photos

    monkeypatch.setattr(store, "_sheet_recipe_rows", lambda: SHEET_ROWS)  # recipe 4 has Photo "abc"
    drive_reads = {"n": 0}
    real_download = photos.download_recipe_photo

    def download(file_id):
        if file_id == "abc":
            drive_reads["n"] += 1
            return b"drive-bytes", "image/jpeg"
        return real_download(file_id)

    monkeypatch.setattr(photos, "download_recipe_photo", download)
    assert store.recipe_photo(4) == (b"drive-bytes", "image/jpeg")
    assert store.get_recipe(4)["photo_id"].startswith("kv:")
    assert store.recipe_photo(4) == (b"drive-bytes", "image/jpeg")
    assert drive_reads["n"] == 1


def test_listing_recipes_never_downloads_photos(upstash, monkeypatch):
    monkeypatch.setattr(store, "_sheet_recipe_rows", lambda: SHEET_ROWS)
    store.create_recipe(title="Card", ingredients=["x"], steps=["y"], course="Main course",
                        tags=[], notes="", photo_bytes=b"\xff\xd8\xffphoto")
    upstash.calls.clear()
    store.list_recipes()
    assert all(not str(call[1]).startswith(kv.PHOTO_KEY_PREFIX) for call in upstash.calls)
