import hmac

from fastapi import Cookie, Header, HTTPException

from app.config import settings

COOKIE_NAME = "recipe_box_key"


def secret_is_enforced() -> bool:
    expected = (settings.recipe_box_secret or "").strip()
    return bool(expected) and expected != "change-me"


def key_matches(presented: str | None) -> bool:
    expected = (settings.recipe_box_secret or "").strip()
    if not secret_is_enforced():
        return True
    got = (presented or "").strip()
    if not got:
        return False
    return hmac.compare_digest(got.encode("utf-8"), expected.encode("utf-8"))


async def require_secret(
    x_recipe_box_key: str | None = Header(default=None),
    recipe_box_key: str | None = Cookie(default=None),
) -> None:
    """Header for the app and Shortcut; cookie so recipe photos can load in <img>."""
    if key_matches(x_recipe_box_key) or key_matches(recipe_box_key):
        return
    raise HTTPException(status_code=401, detail="Missing or invalid X-Recipe-Box-Key")
