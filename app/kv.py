"""The app's shared state (Cupboard, Medicines, Shop/Pack, Tasks, their
category lists, the Gemini usage count) in an Upstash Redis database
instead of the Google Sheet's single AppState cell.

Why: Google Sheets allows each service account about 60 reads and 60
writes a minute, and the apps refresh several tabs at once. Upstash has no
per-minute cap that matters here and is free at this size.

Talks to Upstash's REST API with plain httpx (no Redis driver needed on
Vercel). Each top-level key is one field of a single Redis hash, stored as
JSON, so saving the cupboard never rewrites the task list (no read-merge-
write race between devices). Configured by Vercel's Upstash integration
(KV_REST_API_URL / KV_REST_API_TOKEN) or Upstash's own names
(UPSTASH_REDIS_REST_URL / UPSTASH_REDIS_REST_TOKEN). Without either, the
app keeps using the Sheet (see app.store._read_app_state).
"""

from __future__ import annotations

import json
import logging
from typing import Callable

import httpx

from app.config import settings

logger = logging.getLogger(__name__)

STATE_KEY = "anything-i-want:state"
# Set once the Sheet's AppState has been copied in — see read_state().
MIGRATED_FIELD = "__migrated_from_sheet"


class KVError(RuntimeError):
    """Worded for people; app.errors passes RuntimeError text through."""


def is_configured() -> bool:
    url, token = settings.kv_credentials()
    return bool(url and token)


def _command(*args: str):
    url, token = settings.kv_credentials()
    last: Exception | None = None
    for attempt in range(2):
        try:
            response = httpx.post(
                url.rstrip("/"),
                headers={"Authorization": f"Bearer {token}"},
                json=list(args),
                timeout=10,
            )
        except httpx.HTTPError as exc:
            last = exc
            logger.warning("Upstash request failed (attempt %s): %s", attempt + 1, exc)
            continue
        if response.status_code in (401, 403):
            raise KVError(
                "The Upstash database rejected its token. Reconnect it in Vercel "
                "(Storage → your Upstash database → Connect Project) and redeploy."
            )
        if response.status_code >= 500:
            last = KVError(f"Upstash answered {response.status_code}")
            logger.warning("Upstash %s (attempt %s): %s", response.status_code, attempt + 1, response.text[:200])
            continue
        try:
            body = response.json()
        except ValueError as exc:
            raise KVError("The app's database sent back an unreadable answer. Try again.") from exc
        if isinstance(body, dict) and body.get("error"):
            if "max" in str(body["error"]).lower() and "limit" in str(body["error"]).lower():
                raise KVError(
                    "The Upstash database's free usage limit has been reached. "
                    "Check the plan in Vercel → Storage."
                )
            raise KVError(f"The app's database refused a request: {str(body['error'])[:200]}")
        return body.get("result") if isinstance(body, dict) else body
    raise KVError("Couldn't reach the app's database (Upstash). Try again shortly.") from last


def _decode_hash(flat) -> dict:
    data: dict = {}
    if not isinstance(flat, list):
        return data
    for field, raw in zip(flat[0::2], flat[1::2]):
        if field == MIGRATED_FIELD:
            continue
        try:
            data[field] = json.loads(raw)
        except (TypeError, ValueError):
            logger.warning("Skipping unreadable state field %r", field)
    return data


def read_state(load_sheet_state: Callable[[], dict]) -> dict:
    """The whole state as a dict. The first time ever (empty hash), copies
    the Sheet's AppState in with HSETNX — set-if-missing — so a save that
    lands mid-copy is never overwritten by older Sheet data."""
    flat = _command("HGETALL", STATE_KEY)
    if flat:
        return _decode_hash(flat)
    try:
        sheet_state = load_sheet_state() or {}
    except Exception:
        logger.exception("Could not read the Sheet's AppState to copy into Upstash")
        raise KVError(
            "Couldn't copy your data from the Google Sheet into the new database yet. Try again shortly."
        )
    for field, value in sheet_state.items():
        _command("HSETNX", STATE_KEY, field, json.dumps(value))
    _command("HSETNX", STATE_KEY, MIGRATED_FIELD, "1")
    logger.info("Copied %s AppState keys from the Sheet into Upstash", len(sheet_state))
    return _decode_hash(_command("HGETALL", STATE_KEY))


def write_fields(updates: dict) -> None:
    if not updates:
        return
    args: list[str] = ["HSET", STATE_KEY]
    for field, value in updates.items():
        args.extend([field, json.dumps(value)])
    _command(*args)
