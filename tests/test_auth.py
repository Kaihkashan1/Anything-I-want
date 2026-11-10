from __future__ import annotations

import unittest

from fastapi.testclient import TestClient

from app.config import settings
from app.main import app


class ReadAuthTests(unittest.TestCase):
    def setUp(self):
        self._secret = settings.anything_i_want_secret
        settings.anything_i_want_secret = "test-secret"
        self.client = TestClient(app)

    def tearDown(self):
        settings.anything_i_want_secret = self._secret

    def test_recipe_list_is_closed_without_the_key(self):
        response = self.client.get("/api/recipes")
        self.assertEqual(response.status_code, 401)

    def test_photo_is_closed_without_the_key(self):
        response = self.client.get("/api/recipes/1/photo")
        self.assertEqual(response.status_code, 401)

    def test_session_rejects_a_wrong_key(self):
        response = self.client.post("/api/session", headers={"X-Anything-I-Want-Key": "nope"})
        self.assertEqual(response.status_code, 401)

    def test_session_sets_a_cookie_for_a_valid_key(self):
        response = self.client.post("/api/session", headers={"X-Anything-I-Want-Key": "test-secret"})
        self.assertEqual(response.status_code, 200)
        self.assertTrue(response.json()["required"])
        self.assertEqual(response.cookies.get("anything_i_want_key"), "test-secret")

    def test_old_header_is_rejected(self):
        response = self.client.post("/api/session", headers={"X-Recipe-Box-Key": "test-secret"})
        self.assertEqual(response.status_code, 401)

    def test_cookie_alone_is_accepted(self):
        self.client.cookies.set("anything_i_want_key", "test-secret")
        response = self.client.post("/api/session")
        self.assertEqual(response.status_code, 200)

    def test_home_and_health_stay_reachable(self):
        self.assertEqual(self.client.get("/").status_code, 200)
        self.assertEqual(self.client.get("/health").json(), {"ok": True})

    def test_placeholder_secret_does_not_lock_the_box(self):
        settings.anything_i_want_secret = "change-me"
        response = self.client.post("/api/session")
        self.assertEqual(response.status_code, 200)
        self.assertFalse(response.json()["required"])


if __name__ == "__main__":
    unittest.main()
