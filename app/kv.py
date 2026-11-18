"""Recipes, the import log and the app's shared state (Cupboard,
Medicines, Shop/Pack, Tasks, their category lists, the Gemini usage count)
in an Upstash Redis database instead of the Google Sheet. Recipe photos
stay in Drive (see app/photos.py).

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


# ---------- Recipes ----------
# One hash field per recipe, keyed by its id, holding the same column
# names the Sheet used (Title, Ingredients, …) so app.store's recipe code
# reads them unchanged. Ids are the old Sheet row numbers, so links, the
# apps' caches and Shop items that point at a recipe keep working; new
# recipes take the next number from a counter and ids are never reused.
RECIPES_KEY = "anything-i-want:recipes"
RECIPE_COUNTER_KEY = "anything-i-want:recipes:last-id"
RECIPES_MIGRATED_KEY = "anything-i-want:recipes:migrated"
IMPORT_LOG_KEY = "anything-i-want:import-log"
IMPORT_LOG_MIGRATED_KEY = "anything-i-want:import-log:migrated"
IMPORT_LOG_KEEP = 500

_migrated: set[str] = set()


def _ensure_copied(marker: str, copy: Callable[[], None]) -> None:
    """Runs `copy` once ever (per database), remembered per process too so
    a warm instance doesn't ask Upstash again on every request."""
    if marker in _migrated:
        return
    if _command("GET", marker):
        _migrated.add(marker)
        return
    copy()
    _command("SET", marker, "1")
    _migrated.add(marker)


def ensure_recipes_copied(load_sheet_rows: Callable[[], list[dict]]) -> None:
    def copy() -> None:
        try:
            rows = load_sheet_rows()
        except Exception:
            logger.exception("Could not read recipes from the Sheet to copy into Upstash")
            raise KVError("Couldn't copy your recipes from the Google Sheet yet. Try again shortly.")
        copied = 0
        for index, record in enumerate(rows, start=2):  # Sheet row numbers
            if not str(record.get("Title") or "").strip():
                continue
            _command("HSETNX", RECIPES_KEY, str(index), json.dumps(record))
            copied += 1
        # Next new recipe gets the row number after the Sheet's last row.
        _command("SET", RECIPE_COUNTER_KEY, str(len(rows) + 1), "NX")
        logger.info("Copied %s recipes from the Sheet into Upstash", copied)

    _ensure_copied(RECIPES_MIGRATED_KEY, copy)


def all_recipe_records() -> list[tuple[int, dict]]:
    rows: list[tuple[int, dict]] = []
    flat = _command("HGETALL", RECIPES_KEY) or []
    for field, raw in zip(flat[0::2], flat[1::2]):
        try:
            rows.append((int(field), json.loads(raw)))
        except (TypeError, ValueError):
            logger.warning("Skipping unreadable recipe %r", field)
    return rows


def recipe_record(recipe_id: int) -> dict | None:
    raw = _command("HGET", RECIPES_KEY, str(recipe_id))
    if not raw:
        return None
    try:
        return json.loads(raw)
    except ValueError:
        return None


def put_recipe_record(recipe_id: int, record: dict) -> None:
    _command("HSET", RECIPES_KEY, str(recipe_id), json.dumps(record))


def delete_recipe_record(recipe_id: int) -> None:
    _command("HDEL", RECIPES_KEY, str(recipe_id))


def next_recipe_id() -> int:
    return int(_command("INCR", RECIPE_COUNTER_KEY))


# ---------- Import log ----------
# Newest last, trimmed to the latest IMPORT_LOG_KEEP rows. Each entry is a
# dict with app.store.IMPORT_LOG_HEADERS keys.
def ensure_import_log_copied(load_sheet_values: Callable[[], list[list]]) -> None:
    def copy() -> None:
        try:
            values = load_sheet_values() or []
        except Exception:
            logger.warning("Could not read the Sheet's import log to copy it; starting a new one", exc_info=True)
            return
        if len(values) < 2:
            return
        headers = [str(cell or "").strip().lower() for cell in values[0]]
        entries = []
        for raw in values[1:][-IMPORT_LOG_KEEP:]:
            if not any(str(cell or "").strip() for cell in raw):
                continue
            entries.append(json.dumps({name: str(raw[i]) if i < len(raw) else "" for i, name in enumerate(headers) if name}))
        # Older rows go in front of anything logged since (LPUSH reverses,
        # so push newest-first).
        for entry in reversed(entries):
            _command("LPUSH", IMPORT_LOG_KEY, entry)
        _command("LTRIM", IMPORT_LOG_KEY, str(-IMPORT_LOG_KEEP), "-1")
        logger.info("Copied %s import-log rows from the Sheet into Upstash", len(entries))

    _ensure_copied(IMPORT_LOG_MIGRATED_KEY, copy)


def append_import_log(entry: dict) -> None:
    _command("RPUSH", IMPORT_LOG_KEY, json.dumps(entry))
    _command("LTRIM", IMPORT_LOG_KEY, str(-IMPORT_LOG_KEEP), "-1")


def import_log_entries(limit: int) -> list[dict]:
    raw = _command("LRANGE", IMPORT_LOG_KEY, str(-max(1, limit)), "-1") or []
    entries = []
    for item in raw:
        try:
            entries.append(json.loads(item))
        except ValueError:
            continue
    return entries
