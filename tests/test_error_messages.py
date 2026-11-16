from pathlib import Path

import gspread
import httpx
import pytest
from google.auth.exceptions import RefreshError
from google.genai.errors import APIError as GeminiAPIError

from app import fetch
from app.config import settings
from app.errors import (
    GEMINI_BUSY_MESSAGE,
    GEMINI_QUOTA_MESSAGE,
    friendly_message,
    http_status_for,
)


def _gemini(code, message, status="X"):
    return GeminiAPIError(code, {"error": {"code": code, "message": message, "status": status}})


def _sheets(code):
    class FakeResponse:
        status_code = code
        text = ""

        def json(self):
            return {"error": {"code": code, "message": "nope"}}

    return gspread.exceptions.APIError(FakeResponse())


def test_gemini_errors_are_specific():
    assert friendly_message(_gemini(429, "RESOURCE_EXHAUSTED")) == GEMINI_QUOTA_MESSAGE
    assert friendly_message(_gemini(503, "The model is overloaded")) == GEMINI_BUSY_MESSAGE
    assert "API key" in friendly_message(_gemini(400, "API key not valid. Please pass a valid API key."))
    assert "GEMINI_MODEL" in friendly_message(_gemini(404, "models/x is not found"))
    assert http_status_for(_gemini(503, "overloaded")) == 503


def test_non_gemini_timeouts_are_not_blamed_on_gemini():
    message = friendly_message(RuntimeError("That site took too long to respond. Try again shortly."))
    assert message != GEMINI_BUSY_MESSAGE
    assert "Sheets" in friendly_message(_sheets(503))
    assert http_status_for(_sheets(503)) == 502


def test_sheets_and_credentials():
    assert "shared" in friendly_message(_sheets(403))
    assert "rate-limiting" in friendly_message(_sheets(429))
    assert "service account key" in friendly_message(RefreshError("invalid_grant: Invalid JWT Signature."))


def test_unknown_bug_gets_generic_message():
    assert friendly_message(KeyError("x")) == "Something went wrong on the server. Try again."


def _apify(monkeypatch, response):
    settings.apify_api_token = "token"
    monkeypatch.setattr(fetch.httpx, "post", lambda *a, **k: response)


def _response(status, payload):
    return httpx.Response(status, json=payload, request=httpx.Request("POST", "https://api.apify.com"))


@pytest.mark.parametrize(
    "status,payload,expected",
    [
        (401, {"error": {"type": "user-or-token-not-found", "message": "token is not valid"}}, "rejected the API token"),
        (402, {"error": {"message": "Monthly usage hard limit exceeded"}}, "monthly usage limit"),
        (503, {"error": {"message": "down"}}, "having trouble"),
        (200, [], "found nothing"),
        (200, [{"error": "restricted_page", "errorDescription": "Page is private"}], "private"),
        (200, [{"error": "not_found", "errorDescription": "Post does not exist"}], "wasn't found"),
    ],
)
def test_apify_failures_say_what_happened(monkeypatch, tmp_path: Path, status, payload, expected):
    _apify(monkeypatch, _response(status, payload))
    with pytest.raises(RuntimeError) as info:
        fetch.fetch_post("https://www.instagram.com/reel/abc", tmp_path)
    assert expected in str(info.value)


def test_page_fetch_status_messages():
    assert "blocked" in fetch._page_status_message(403)
    assert "doesn't exist" in fetch._page_status_message(404)


def test_video_error_messages():
    assert "private" in fetch._video_error_message("ERROR: [youtube] abc: Private video")
    assert "signed-in" in fetch._video_error_message("ERROR: Sign in to confirm your age")
    assert "isn't available" in fetch._video_error_message("ERROR: Video unavailable")


def test_unhandled_endpoint_error_returns_readable_detail(monkeypatch):
    from fastapi.testclient import TestClient

    from app import main

    def boom():
        raise RefreshError("invalid_grant")

    monkeypatch.setattr(main, "get_medicines", boom)
    client = TestClient(main.app, raise_server_exceptions=False)
    response = client.get("/api/medicines")
    assert response.status_code == 502
    assert "service account key" in response.json()["detail"]
