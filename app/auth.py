import hmac

from fastapi import Cookie, Header, HTTPException

from app.config import settings

COOKIE_NAME = "anything_i_want_key"
HEADER_NAME = "X-Anything-I-Want-Key"


def secret_is_enforced() -> bool:
    expected = (settings.anything_i_want_secret or "").strip()
    return bool(expected) and expected != "change-me"


def key_matches(presented: str | None) -> bool:
    expected = (settings.anything_i_want_secret or "").strip()
    if not secret_is_enforced():
        return True
    got = (presented or "").strip()
    if not got:
        return False
    return hmac.compare_digest(got.encode("utf-8"), expected.encode("utf-8"))


async def require_secret(
    x_anything_i_want_key: str | None = Header(default=None),
    anything_i_want_key: str | None = Cookie(default=None),
) -> None:
    if key_matches(x_anything_i_want_key) or key_matches(anything_i_want_key):
        return
    raise HTTPException(status_code=401, detail=f"Missing or invalid {HEADER_NAME}")
