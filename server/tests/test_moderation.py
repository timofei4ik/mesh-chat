import base64
import hashlib
import json
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
from server.server_command_bus import ConnectionContext
from server.server_commands_moderation import handle_moderation_report
from server.server_moderation import ServerModerationMixin
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
CREATE TABLE moderation_enforcements(
 enforcement_id TEXT PRIMARY KEY, report_id TEXT, action TEXT,
 subject_type TEXT, subject_id TEXT, target_login TEXT DEFAULT '',
 status TEXT DEFAULT 'active', expires_at DATETIME,
 reversible INTEGER DEFAULT 1, metadata_json TEXT DEFAULT '{}',
 created_by TEXT, created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
 revoked_at DATETIME, revoked_by TEXT DEFAULT '', revoke_note TEXT DEFAULT ''
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


class FakeWebSocket:
    def __init__(self):
        self.sent = []
        self.closed = None

    async def send(self, value):
        self.sent.append(json.loads(value))

    async def close(self, code=None, reason=None):
        self.closed = (code, reason)


class EnforcementRelay(ServerModerationMixin):
    def __init__(self, connection):
        self.db = connection
        self.connection = connection
        self.client_logins = {
            "sender-node": "sender",
            "receiver-node": "receiver",
            "member-node": "member",
            "owner-node": "owner",
        }
        self.clients = {}
        self.persisted = []
        self.routed = []
        self.mirrored = []

    def unit_of_work_factory(self, write=False):
        return FakeUnitOfWork(self.connection)

    def get_login_by_node(self, node_id):
        return self.client_logins.get(node_id, "")

    def get_account_node_ids(self, login):
        return [
            node for node, value in self.client_logins.items() if value == login
        ]

    def get_group_delivery_nodes(self, group_id):
        rows = self.db.execute(
            "SELECT node_id FROM server_group_members WHERE group_id=?",
            (group_id,),
        ).fetchall()
        return [row[0] for row in rows]

    def _dedupe_account_nodes(self, nodes):
        seen = set()
        result = []
        for node in nodes:
            identity = self.get_login_by_node(node) or node
            if identity in seen:
                continue
            seen.add(identity)
            result.append(node)
        return result

    def _same_account_nodes(self, first, second):
        return (self.get_login_by_node(first) or first) == (
            self.get_login_by_node(second) or second
        )

    def sync_v2_accounts_for_packet(self, packet, extra_nodes=None):
        nodes = [
            packet.get("source_node"),
            packet.get("destination_node"),
            *(extra_nodes or []),
        ]
        return sorted(
            {
                self.get_login_by_node(node)
                for node in nodes
                if self.get_login_by_node(node)
            }
        )

    def persist_history_mutation(self, packet, accounts, mutation_context=None):
        self.persisted.append((dict(packet), list(accounts)))
        packet_type = packet["type"]
        if packet_type == "message_delete":
            self.db.execute(
                "DELETE FROM direct_messages WHERE message_id=?",
                (packet["message_id"],),
            )
            self.db.execute(
                "DELETE FROM server_files WHERE file_id=?",
                (packet["message_id"],),
            )
        elif packet_type == "group_message_delete":
            self.db.execute(
                "DELETE FROM server_group_messages WHERE message_id=?",
                (packet["group_message_id"],),
            )
            self.db.execute(
                "DELETE FROM server_files WHERE file_id=?",
                (packet["group_message_id"],),
            )
        elif packet_type == "story_delete":
            self.db.execute(
                "DELETE FROM server_stories WHERE story_id=?",
                (packet["story_id"],),
            )
        elif packet_type == "group_delete":
            self.db.execute(
                "DELETE FROM server_groups WHERE group_id=?",
                (packet["group_id"],),
            )
        self.db.commit()
        return {"saved": True, "processed_inserted": None}

    async def mirror_packet_to_source_account_devices(self, packet):
        self.mirrored.append(dict(packet))

    async def route_packet(self, packet):
        self.routed.append(dict(packet))

    async def send_server_error(self, websocket, code, message, **extra):
        await websocket.send(json.dumps({"type": "server_error", "code": code}))


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

    def test_account_sanction_can_be_revoked_without_losing_audit(self):
        self.repository.create_report(
            {
                "report_id": "report-2", "reporter_login": "alice",
                "reporter_node": "node-1", "subject_type": "profile",
                "subject_id": "bob", "conversation_id": "",
                "target_login": "bob", "reason": "harassment", "details": "",
                "snapshot": {},
            }
        )
        self.repository.create_enforcement(
            {
                "enforcement_id": "sanction-1", "report_id": "report-2",
                "action": "block", "subject_type": "profile",
                "subject_id": "bob", "target_login": "bob",
                "created_by": "admin",
            }
        )
        self.assertTrue(self.repository.account_access("bob")["blocked"])
        self.assertTrue(
            self.repository.revoke_enforcement(
                "sanction-1", "admin", "appeal accepted"
            )
        )
        self.assertFalse(self.repository.account_access("bob")["blocked"])
        sanction = self.repository.enforcement_by_id("sanction-1")
        self.assertEqual(sanction["status"], "revoked")
        self.assertEqual(sanction["revoke_note"], "appeal accepted")


class ModerationReportCommandTests(unittest.IsolatedAsyncioTestCase):
    async def test_all_supported_subject_types_reach_the_queue(self):
        connection = sqlite3.connect(":memory:")
        connection.executescript(SCHEMA)
        relay = FakeRelay(connection)
        relay.client_logins = {"reporter-node": "reporter"}
        relay.get_login_by_node = lambda node: relay.client_logins.get(node, "")
        websocket = FakeWebSocket()
        context = ConnectionContext(websocket, "reporter-node")
        try:
            for subject_type in (
                "message", "comment", "story", "profile", "group", "channel"
            ):
                await handle_moderation_report(
                    relay,
                    {
                        "type": "moderation_report",
                        "request_id": f"request-{subject_type}",
                        "subject_type": subject_type,
                        "subject_id": f"subject-{subject_type}",
                        "target_login": "reported-user",
                        "reason": "spam",
                    },
                    context,
                )
            reports = relay.unit_of_work_factory().moderation.list_reports(
                status="new", limit=20
            )
            self.assertEqual({item["subject_type"] for item in reports}, {
                "message", "comment", "story", "profile", "group", "channel"
            })
            self.assertTrue(all(item["ok"] for item in websocket.sent))
        finally:
            connection.close()


class ModerationEnforcementTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.connection = sqlite3.connect(":memory:")
        self.connection.executescript(SCHEMA)
        self.connection.executescript(
            """
            CREATE TABLE direct_messages(
                message_id TEXT PRIMARY KEY, sender_node TEXT, receiver_node TEXT
            );
            CREATE TABLE server_group_messages(
                message_id TEXT PRIMARY KEY, group_id TEXT, sender_node TEXT
            );
            CREATE TABLE server_files(
                file_id TEXT PRIMARY KEY, group_id TEXT, sender_node TEXT,
                receiver_node TEXT
            );
            CREATE TABLE server_groups(
                group_id TEXT PRIMARY KEY, owner_node TEXT, is_channel INTEGER
            );
            CREATE TABLE server_group_members(group_id TEXT, node_id TEXT);
            CREATE TABLE server_stories(
                story_id TEXT PRIMARY KEY, owner_node TEXT,
                recipients_json TEXT, story_json TEXT
            );
            """
        )
        self.relay = EnforcementRelay(self.connection)

    def tearDown(self):
        self.connection.close()

    async def test_hide_emits_tombstones_for_every_content_scope(self):
        fixtures = (
            (
                "message", "direct-1",
                "INSERT INTO direct_messages VALUES(?,?,?)",
                ("direct-1", "sender-node", "receiver-node"),
                "message_delete",
            ),
            (
                "comment", "comment-1",
                "INSERT INTO server_group_messages VALUES(?,?,?)",
                ("comment-1", "group-1", "sender-node"),
                "group_message_delete",
            ),
            (
                "story", "story-1",
                "INSERT INTO server_stories VALUES(?,?,?,?)",
                (
                    "story-1", "sender-node", '["receiver-node"]',
                    '{"recipients":["member-node"]}',
                ),
                "story_delete",
            ),
            (
                "group", "group-2",
                "INSERT INTO server_groups VALUES(?,?,?)",
                ("group-2", "owner-node", 0),
                "group_delete",
            ),
            (
                "channel", "channel-1",
                "INSERT INTO server_groups VALUES(?,?,?)",
                ("channel-1", "owner-node", 1),
                "group_delete",
            ),
        )
        self.connection.execute(
            "INSERT INTO server_group_members VALUES(?,?)",
            ("group-1", "member-node"),
        )
        for subject_type, subject_id, statement, values, expected in fixtures:
            self.connection.execute(statement, values)
            if subject_type in {"group", "channel"}:
                self.connection.execute(
                    "INSERT INTO server_group_members VALUES(?,?)",
                    (subject_id, "member-node"),
                )
            report = {
                "report_id": f"report-{subject_id}",
                "subject_type": subject_type,
                "subject_id": subject_id,
                "target_login": "sender",
            }
            metadata = await self.relay._moderation_hide_content(report)
            self.assertEqual(metadata["packet_type"], expected)
            packet, accounts = self.relay.persisted[-1]
            self.assertTrue(packet["moderated"])
            self.assertTrue(packet["operation_id"].startswith("moderation:"))
            self.assertTrue(accounts)

    async def test_restrict_block_and_undo_change_server_access(self):
        repository = ModerationRepository(self.connection)
        repository.create_report(
            {
                "report_id": "profile-report", "reporter_login": "alice",
                "reporter_node": "node", "subject_type": "profile",
                "subject_id": "sender", "conversation_id": "",
                "target_login": "sender", "reason": "harassment",
                "details": "", "snapshot": {},
            }
        )
        report = repository.report_by_id("profile-report")
        restricted = await self.relay.apply_moderation_enforcement(
            report, "restrict", "admin", duration_hours=1
        )
        self.assertEqual(
            self.relay.moderation_packet_allowed("sender", "chat_message"),
            (False, "account_restricted"),
        )
        self.assertEqual(
            self.relay.moderation_packet_allowed("sender", "group_update"),
            (False, "account_restricted"),
        )
        self.assertEqual(
            self.relay.moderation_packet_allowed("sender", "message_delete"),
            (True, "ok"),
        )
        await self.relay.revoke_moderation_enforcement(
            restricted, "admin", "appeal"
        )
        self.assertEqual(
            self.relay.moderation_packet_allowed("sender", "chat_message"),
            (True, "ok"),
        )
        blocked = await self.relay.apply_moderation_enforcement(
            report, "block", "admin"
        )
        self.assertEqual(
            self.relay.moderation_packet_allowed("sender", "message_delete"),
            (False, "account_blocked"),
        )
        await self.relay.revoke_moderation_enforcement(
            blocked, "admin", "mistake"
        )
        self.assertEqual(
            self.relay.moderation_packet_allowed("sender", "chat_message"),
            (True, "ok"),
        )

    async def test_invalid_restriction_duration_uses_safe_default(self):
        repository = ModerationRepository(self.connection)
        repository.create_report(
            {
                "report_id": "duration-report", "reporter_login": "alice",
                "reporter_node": "node", "subject_type": "profile",
                "subject_id": "sender", "conversation_id": "",
                "target_login": "sender", "reason": "spam",
                "details": "", "snapshot": {},
            }
        )
        enforcement_id = await self.relay.apply_moderation_enforcement(
            repository.report_by_id("duration-report"),
            "restrict",
            "admin",
            duration_hours="not-a-number",
        )
        enforcement = repository.enforcement_by_id(enforcement_id)
        self.assertEqual(enforcement["metadata"]["duration_hours"], 24)


@unittest.skipUnless(web is not None, "aiohttp is not installed")
class ModerationHttpTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.connection = sqlite3.connect(":memory:")
        self.connection.executescript(SCHEMA)
        self.relay = EnforcementRelay(self.connection)
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
        app.router.add_post(
            "/admin/moderation/api/reports/{report_id}/decision",
            service._decision,
        )
        app.router.add_post(
            "/admin/moderation/api/enforcements/{enforcement_id}/undo",
            service._undo_enforcement,
        )
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

    async def test_admin_can_restrict_and_undo_through_http_api(self):
        repository = ModerationRepository(self.connection)
        repository.create_report(
            {
                "report_id": "http-report", "reporter_login": "alice",
                "reporter_node": "node", "subject_type": "profile",
                "subject_id": "sender", "conversation_id": "",
                "target_login": "sender", "reason": "harassment",
                "details": "", "snapshot": {},
            }
        )
        self.connection.commit()
        login = await self.client.post(
            "/admin/moderation/api/login", json={"password": self.password}
        )
        login_payload = await login.json()
        cookie = login.cookies["mesh_moderation_session"].value
        headers = {
            "Cookie": f"mesh_moderation_session={cookie}",
            "X-CSRF-Token": login_payload["csrf"],
        }
        decision = await self.client.post(
            "/admin/moderation/api/reports/http-report/decision",
            headers=headers,
            json={
                "action": "restrict", "duration_hours": 1,
                "note": "temporary safety restriction",
            },
        )
        self.assertEqual(decision.status, 200)
        enforcement_id = (await decision.json())["enforcement_id"]
        self.assertTrue(repository.account_access("sender")["restricted"])

        reports = await self.client.get(
            "/admin/moderation/api/reports?status=all",
            headers={"Cookie": headers["Cookie"]},
        )
        report = (await reports.json())["reports"][0]
        self.assertEqual(report["enforcements"][0]["status"], "active")
        self.assertEqual(report["actions"][0]["action"], "restrict")

        undo = await self.client.post(
            f"/admin/moderation/api/enforcements/{enforcement_id}/undo",
            headers=headers,
            json={"note": "appeal accepted"},
        )
        self.assertEqual(undo.status, 200)
        self.assertFalse(repository.account_access("sender")["restricted"])
        actions = repository.actions_for_report("http-report")
        self.assertEqual(actions[-1]["action"], "undo:restrict")


if __name__ == "__main__":
    unittest.main()
