"""Turns a raw exception into the same user-facing message everywhere it can
happen, instead of each call site inventing its own wording or leaking a bare
status code / raw API error dump. Used by both the /ingest pipeline (link
saves) and the /api/extract-photo endpoint (photo saves) so a Gemini quota
hit or an Apify limit reads the same way no matter which path triggered it.
"""

from __future__ import annotations

import json

import httpx
from google.genai.errors import APIError as GeminiAPIError

# Primary free-tier daily cap, plus the fallback model's own (much higher)
# cap. Combined for the quota-exhausted error and the Settings "Imports today"
# bar. Used is still the self-tracked Gemini call count for today.
GEMINI_PRIMARY_DAILY_QUOTA = 20
GEMINI_FALLBACK_DAILY_QUOTA = 500
GEMINI_DAILY_QUOTA = GEMINI_PRIMARY_DAILY_QUOTA + GEMINI_FALLBACK_DAILY_QUOTA

GEMINI_QUOTA_MESSAGE = (
    f"Gemini's daily quota ({GEMINI_DAILY_QUOTA} requests/day) is used up. "
    "Try again after it resets around 9 am CET."
)

GEMINI_BUSY_MESSAGE = (
    "Gemini is busy right now. Wait a few seconds and try again."
)

NOT_A_RECIPE_MESSAGE = "That didn't look like a recipe."

GEMINI_UNREADABLE_MESSAGE = "Gemini's answer came back garbled. Try again."

# Shortcut / iOS closed the HTTP request before /ingest could respond.
# Distinct from GEMINI_BUSY_MESSAGE, which is a timeout talking to Gemini
# that the pipeline still caught and returned as JSON.
REQUEST_TIMEOUT_MESSAGE = "Request timed out."


def gemini_is_busy(exc: Exception) -> bool:
    """Capacity blips (503 / 'high demand' / 504 DEADLINE_EXCEEDED), not the
    daily free-tier cap.

    A client-side timeout (see app.extract's explicit HttpOptions.timeout)
    counts too: the SDK has no timeout of its own, so without ours a slow
    Gemini response would just run out the clock until Vercel's hard 60s
    kill instead of failing cleanly — and a response that takes that long
    reads the same as "busy" from here, whether Gemini ever answered or not.

    504 is Gemini's own server-side deadline, not ours — seen live as
    "DEADLINE_EXCEEDED. ... Deadline expired before operation could
    complete." when the model itself is currently slow to respond."""
    if isinstance(exc, httpx.TimeoutException):
        return True
    code = getattr(exc, "code", None)
    if code in (500, 503, 504):
        return True
    message = str(getattr(exc, "message", None) or exc).lower()
    return (
        "high demand" in message
        or "unavailable" in message
        or "overloaded" in message
        or "try again later" in message
        or "timeout" in message
        or "timed out" in message
        or "deadline_exceeded" in message
        or "deadline expired" in message
    )


def gemini_is_quota_exhausted(exc: Exception) -> bool:
    """A real daily-cap 429 (RESOURCE_EXHAUSTED) — distinct from
    gemini_is_busy's capacity blips."""
    return isinstance(exc, GeminiAPIError) and exc.code == 429 and not gemini_is_busy(exc)


def gemini_is_retryable(exc: Exception) -> bool:
    if gemini_is_busy(exc):
        return True
    code = getattr(exc, "code", None)
    if code == 429:
        return True
    message = str(exc).lower()
    return "429" in message or "resource_exhausted" in message


def _is_gemini_error(exc: Exception) -> bool:
    """Only the Gemini SDK lets raw httpx errors escape — every other httpx
    caller in this app (Apify, page fetches) wraps or swallows its own — so
    a bare httpx error here is Gemini's. Our own RuntimeErrors that merely
    *mention* "timed out" (a slow recipe site, say) are not."""
    return isinstance(exc, (GeminiAPIError, httpx.HTTPError))


def _gemini_message(exc: Exception) -> str:
    if isinstance(exc, GeminiAPIError) and exc.code == 429:
        return GEMINI_QUOTA_MESSAGE
    if gemini_is_busy(exc):
        return GEMINI_BUSY_MESSAGE
    if isinstance(exc, httpx.HTTPError):
        return "Couldn't reach Gemini. Check the connection and try again."
    code = getattr(exc, "code", None)
    text = str(getattr(exc, "message", None) or exc)
    lowered = text.lower()
    if "api key" in lowered or "api_key" in lowered or code == 401:
        return (
            "Gemini rejected the API key. Create a new one at aistudio.google.com/apikey, "
            "set it as GEMINI_API_KEY, and redeploy."
        )
    if code == 403:
        return (
            "Gemini refused the request (permission denied). The API key may be "
            "restricted or blocked — create a new one and set GEMINI_API_KEY."
        )
    if code == 404:
        return (
            "That Gemini model isn't available any more. Check GEMINI_MODEL / "
            "GEMINI_FALLBACK_MODEL in the environment settings."
        )
    if code == 400 and ("too large" in lowered or "exceeds" in lowered or "token" in lowered):
        return "That post is too big for Gemini to read in one go."
    return f"Gemini couldn't read that ({code or 'error'}). Try again."


def _sheets_message(exc: Exception) -> str | None:
    try:
        import gspread
        from google.auth.exceptions import GoogleAuthError, RefreshError
    except ImportError:  # pragma: no cover
        return None
    if isinstance(exc, gspread.exceptions.SpreadsheetNotFound):
        return "The Google Sheet wasn't found. Check GOOGLE_SHEET_ID."
    if isinstance(exc, RefreshError):
        return (
            "Google rejected the service account key (it may have been deleted or "
            "rotated). Create a new JSON key and update GOOGLE_SERVICE_ACCOUNT_JSON."
        )
    if isinstance(exc, GoogleAuthError):
        return "Google sign-in for the service account failed. Check GOOGLE_SERVICE_ACCOUNT_JSON."
    if isinstance(exc, gspread.exceptions.APIError):
        code = getattr(exc, "code", None)
        if code == 403:
            return "Google Sheets refused access. Make sure the Sheet is shared with the service account as Editor."
        if code == 404:
            return "The Google Sheet wasn't found. Check GOOGLE_SHEET_ID."
        if code == 429:
            return "Google Sheets is rate-limiting requests. Wait a minute and try again."
        if code in (500, 502, 503, 504):
            return "Google Sheets is having trouble right now. Try again shortly."
        return f"Google Sheets returned an error ({code}). Try again."
    module = type(exc).__module__ or ""
    if module.startswith("requests") or module.startswith("urllib3"):
        return "Couldn't reach Google Sheets. Try again shortly."
    return None


def known_message(exc: Exception) -> str | None:
    """A specific, user-facing explanation when we can tell what went wrong;
    None for an unexpected bug (the caller picks its own fallback)."""
    if _is_gemini_error(exc):
        return _gemini_message(exc)
    sheets = _sheets_message(exc)
    if sheets:
        return sheets
    if isinstance(exc, json.JSONDecodeError):
        return "GOOGLE_SERVICE_ACCOUNT_JSON isn't valid JSON. Paste the whole key file again."
    try:
        from pydantic import ValidationError
    except ImportError:  # pragma: no cover
        ValidationError = ()  # type: ignore[assignment]
    if isinstance(exc, ValidationError):
        return None
    if isinstance(exc, (RuntimeError, TimeoutError, ValueError)) and str(exc).strip():
        # Our own raises — already worded for people.
        return str(exc)
    return None


def friendly_message(exc: Exception) -> str:
    return known_message(exc) or "Something went wrong on the server. Try again."


def http_status_for(exc: Exception) -> int:
    if isinstance(exc, GeminiAPIError) and exc.code == 429:
        return 429
    if _is_gemini_error(exc) and gemini_is_busy(exc):
        return 503
    return 502
