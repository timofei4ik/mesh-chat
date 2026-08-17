import base64
import hashlib
import sqlite3
import unittest
from contextlib import nullcontext
from unittest.mock import patch

try:
    from aiohttp import web
    from aiohttp.test_utils import TestClient, TestServer
except ModuleNotFoundError:
    web = None
    TestClient = None
    TestServer = None

from server.persistence.moderation import ModerationRepository
from server.server_moderation_http import ModerationHttpServer


SCHEMA = """
CREATE TABLE moderation_reports(
 report_id TEXT PRIMARY KEY, reporter_login TEXT, reporter_node TEXT,
 subject_type TEXT, subject_id TEXT, conversation_id TEXT, target_login TEXT,
 reason TEXT, details TEXT, snapshot_json TEXT, status TEXT, priority INTEGER,
 assigned_to TEXT DEFAULT '', ai_category TEXT DEFAULT '',
 ai_confidence REAL DEFAULT 0, ai_recommendation TEXT DEFAULT '',
 created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
 updated_at DATETIME DEFAULT CURRENT_TIMESTAMP, resolved_at DATETIME
);
CREATE TABLE moderation_actions(
 action_id TEXT PRIMARY KEY, report_id TEXT, admin_id TEXT, action TEXT,
 note TEXT, created_at DATETIME DEFAULT CURRENT_TIMESTAMP
);
"""


class FakeUnitOfWork:
    def __init__(self, connection):
        self.moderation = ModerationRepository(connection)
        self._transaction = nullcontext()

    def __enter__(self):
        self._transaction.__enter__()
        return self

    def __exit__(self, *args):
        return self._transaction.__exit__(*args)


class FakeRelay:
    def __init__(self, connection):
        self.connection = connection

    def unit_of_work_factory(self, write=False):
        return FakeUnitOfWork(self.connection)


def password_hash(password):
    salt = b"0123456789abcdef"
    digest = hashlib.scrypt(password.encode(), salt=salt, n=16384, r=8, p=1)
    return "scrypt$%s$%s" % (
        base64.urlsafe_b64encode(salt).decode(),
        base64.urlsafe_b64encode(digest).decode(),
    )


class ModerationRepositoryTests(unittest.TestCase):
    def setUp(self):
        self.connection = sqlite3.connect(":memory:")
        self.connection.executescript(SCHEMA)
        self.repository = ModerationRepository(self.connection)

    def test_report_and_audit_decision_are_persisted(self):
        self.repository.create_report(
            {
                "report_id": "report-1", "reporter_login": "alice",
                "reporter_node": "node-1", "subject_type": "message",
                "subject_id": "message-1", "conversation_id": "chat-1",
                "target_login": "bob", "reason": "spam", "details": "ads",
                "snapshot": {"text": "buy now"},
            }
        )
        report = self.repository.list_reports()[0]
        self.assertEqual(report["snapshot"]["text"], "buy now")
        self.assertTrue(
            self.repository.record_decision(
                "report-1", "action-1", "admin", "hide", "confirmed"
            )
        )
        self.assertEqual(
            self.repository.report_by_id("report-1")["status"], "resolved"
        )
        self.assertEqual(
            self.repository.actions_for_report("report-1")[0]["action"], "hide"
        )


@unittest.skipUnless(web is not None, "aiohttp is not installed")
class ModerationHttpTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.connection = sqlite3.connect(":memory:")
        self.connection.executescript(SCHEMA)
        self.relay = FakeRelay(self.connection)
        self.password = "correct horse battery staple"
        self.patches = [
            patch(
                "server.server_moderation_http.MODERATION_ADMIN_PASSWORD_HASH",
                password_hash(self.password),
            ),
            patch(
                "server.server_moderation_http.MODERATION_SESSION_SECRET",
                "test-session-secret-with-enough-entropy",
            ),
        ]
        for item in self.patches:
            item.start()
        service = ModerationHttpServer(self.relay)
        app = web.Application()
        app.router.add_post("/admin/moderation/api/login", service._login)
        app.router.add_get("/admin/moderation/api/session", service._session)
        app.router.add_get("/admin/moderation/api/reports", service._reports)
        self.client = TestClient(TestServer(app))
        await self.client.start_server()

    async def asyncTearDown(self):
        await self.client.close()
        for item in reversed(self.patches):
            item.stop()
        self.connection.close()

    async def test_login_sets_secure_session_and_lists_reports(self):
        response = await self.client.post(
            "/admin/moderation/api/login", json={"password": self.password}
        )
        self.assertEqual(response.status, 200)
        payload = await response.json()
        self.assertTrue(payload["csrf"])
        cookie = response.cookies["mesh_moderation_session"].value
        headers = {"Cookie": f"mesh_moderation_session={cookie}"}
        session = await self.client.get(
            "/admin/moderation/api/session", headers=headers
        )
        self.assertEqual(session.status, 200)
        reports = await self.client.get(
            "/admin/moderation/api/reports", headers=headers
        )
        self.assertEqual((await reports.json())["reports"], [])

    async def test_wrong_password_is_rejected(self):
        response = await self.client.post(
            "/admin/moderation/api/login", json={"password": "wrong"}
        )
        self.assertEqual(response.status, 401)


if __name__ == "__main__":
    unittest.main()
