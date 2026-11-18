import gspread
import pytest

from app import store


class _Resp:
    def __init__(self, code):
        self.status_code = code
        self.text = ""
        self._code = code

    def json(self):
        return {"error": {"code": self._code, "message": "slow down"}}


def _api_error(code):
    return gspread.exceptions.APIError(_Resp(code))


def test_rate_limit_waits_longer_and_eventually_succeeds(monkeypatch):
    pauses = []
    monkeypatch.setattr(store.time, "sleep", pauses.append)
    calls = {"n": 0}

    def op():
        calls["n"] += 1
        if calls["n"] < 4:
            raise _api_error(429)
        return "ok"

    assert store.retry_sheets_call(op) == "ok"
    assert pauses == [2.0, 4.0, 8.0]


def test_rate_limit_gives_up_after_about_half_a_minute(monkeypatch):
    pauses = []
    monkeypatch.setattr(store.time, "sleep", pauses.append)

    def op():
        raise _api_error(429)

    with pytest.raises(gspread.exceptions.APIError):
        store.retry_sheets_call(op)
    assert pauses == [2.0, 4.0, 8.0, 16.0]


def test_server_blips_keep_the_short_backoff(monkeypatch):
    pauses = []
    monkeypatch.setattr(store.time, "sleep", pauses.append)

    def op():
        raise _api_error(503)

    with pytest.raises(gspread.exceptions.APIError):
        store.retry_sheets_call(op)
    assert len(pauses) == 3 and pauses[0] == 0.7


def test_app_state_reads_share_one_sheet_call_but_writes_read_fresh(monkeypatch):
    cell = {"value": '{"a": 1}'}
    reads = {"n": 0}

    class Cell:
        @property
        def value(self):
            reads["n"] += 1
            return cell["value"]

    class Sheet:
        def acell(self, _):
            return Cell()

        def update(self, _range, values, value_input_option=None):
            cell["value"] = values[0][0]

    monkeypatch.setattr(store, "_state_worksheet", lambda: Sheet())
    store._app_state_cache.update(at=0.0, data=None)
    first = store._read_app_state()
    first["a"] = 99  # editing a returned copy must not change the cache
    assert store._read_app_state() == {"a": 1}
    assert reads["n"] == 1
    store._write_app_state(b=2)
    assert reads["n"] == 2  # the write merged into a fresh read
    assert store._read_app_state() == {"a": 1, "b": 2}
    assert reads["n"] == 2  # and refreshed the cache
    store._app_state_cache.update(at=0.0, data=None)
