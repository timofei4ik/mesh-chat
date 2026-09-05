import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from server import server_storage, server_call_captions, server_calls, server_commands_ai
from server.server_command_bus import ConnectionContext
from server.tests.test_calls import FakeCallServer, FakeSocket


class CaptionRelay(FakeCallServer, server_storage.ServerStorageMixin):
    def __init__(self):
        super().__init__()
        self.db = self.open_db()
        self.members = {"caller", "callee", "guest"}
        self.pro = {"alice"}
        self.client_logins["guest"] = "carol"
        self.ai_logins = []

    def get_group_delivery_nodes(self, group_id):
        return sorted(self.members) if group_id == "group" else []

    def subscription_feature_enabled(self, login, feature):
        return login in self.pro

    async def transcribe_voice_with_ai(self, login, *args):
        self.ai_logins.append((login, args))
        return {"ok": True, "text": "Hello"}

    async def translate_message_with_ai(self, login, *args):
        self.ai_logins.append((login, args))
        return {"ok": True, "text": "Hello"}


class GroupCaptionTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.db_patch = patch.object(server_storage, "DB_PATH", Path(self.temp.name) / "test.db")
        self.db_patch.start()
        self.server = CaptionRelay()
        for node in self.server.members:
            self.server.clients[node] = FakeSocket()

    def tearDown(self):
        self.server.db.close()
        self.db_patch.stop()
        self.temp.cleanup()

    async def command(self, action, node="caller", **extra):
        row = server_call_captions.caption_session(self.server, "call")
        packet = {"call_id": "call", "group_id": "group", "action": action,
                  "members": sorted(self.server.members), "request_id": "request",
                  "session_id": row[3] if row else "", **extra}
        socket = self.server.clients[node]
        offset = len(socket.sent)
        await server_call_captions.handle_caption_session(self.server, packet, ConnectionContext(socket, node))
        return next(item for item in socket.sent[offset:] if item["type"] == "call_caption_session_result")

    def billing(self, node, session_id=None):
        row = server_call_captions.caption_session(self.server, "call")
        return server_call_captions.caption_billing_login(self.server, "call", node, session_id or (row[3] if row else ""))

    async def test_requires_meshpro_and_explicit_participant_consent(self):
        self.assertEqual("meshpro_required", (await self.command("start", "callee"))["error"])
        self.assertTrue((await self.command("start"))["ok"])
        self.assertEqual("alice", self.billing("caller"))
        self.assertEqual("", self.billing("callee"))
        self.assertTrue((await self.command("join", "callee"))["ok"])
        approved = self.server.clients["callee"].sent[-1]
        self.assertEqual(1, approved["consent"])
        self.assertEqual(1, approved["revision"])
        await self.command("heartbeat")
        self.assertEqual(1, self.server.clients["callee"].sent[-1]["revision"])
        self.assertEqual("alice", self.billing("callee"))
        self.assertEqual("", self.billing("callee", "stale-session"))
        self.assertTrue((await self.command("decline", "callee"))["ok"])
        self.assertEqual("", self.billing("callee"))

    async def test_stop_expiry_and_subscription_revocation_close_billing(self):
        await self.command("start")
        await self.command("join", "callee")
        self.server.pro.clear()
        self.assertEqual("", self.billing("callee"))
        self.server.pro.add("alice")
        self.server.members.remove("callee")
        self.assertEqual("", self.billing("callee"))
        self.server.members.add("callee")
        row = server_call_captions.caption_session(self.server, "call")
        with patch.object(server_call_captions.time, "time", return_value=row[2] + 1):
            self.assertEqual("", self.billing("callee", row[3]))
        self.assertTrue((await self.command("stop"))["ok"])
        self.assertEqual("", self.billing("caller", row[3]))

    async def test_non_sponsor_cannot_renew_stop_or_replace_session(self):
        await self.command("start")
        for action in ("start", "heartbeat", "stop"):
            self.assertEqual("caption_session_owned_by_peer", (await self.command(action, "callee"))["error"])
        self.assertEqual("caption_session_expired", (await self.command("stop", session_id="old"))["error"])
        self.assertTrue((await self.command("heartbeat"))["ok"])

    async def test_cannot_sponsor_second_room_or_inject_outsiders(self):
        self.assertEqual("invalid_members", (await self.command("start", members=["caller", "outsider"]))["error"])
        await self.command("start", members=["caller", "callee"])
        self.assertEqual("caption_session_forbidden", (await self.command("join", "guest"))["error"])
        self.assertEqual("caption_session_unavailable", (await self.command("start", call_id="other"))["error"])

    async def test_sponsored_ai_bills_sponsor_only_after_consent(self):
        await self.command("start")
        row = server_call_captions.caption_session(self.server, "call")
        socket = self.server.clients["callee"]
        packet = {"type": "ai_voice_transcription_request", "request_id": "chunk",
                  "live_call_id": "call", "caption_session_id": row[3],
                  "message_id": "someone-elses-cache", "login": "alice"}
        context = ConnectionContext(socket, "callee")
        await server_commands_ai.handle_ai_request(self.server, packet, context)
        self.assertFalse(socket.sent[-1]["ok"])
        self.assertEqual([], self.server.ai_logins)
        await self.command("join", "callee")
        await server_commands_ai.handle_ai_request(self.server, packet, context)
        self.assertEqual("alice", self.server.ai_logins[-1][0])
        self.assertTrue(self.server.ai_logins[-1][1][0].startswith("call-caption-"))
        self.assertEqual("someone-elses-cache", packet["message_id"])

    async def test_group_signals_require_real_membership_and_no_state_spoof(self):
        socket = self.server.clients["caller"]
        for packet in (
            {"type": "call_group_offer", "group_id": "other", "destination_node": "callee"},
            {"type": "call_group_ready", "group_id": "group", "destination_node": "outsider"},
            {"type": "call_caption_session", "group_id": "group", "destination_node": "callee"},
        ):
            await server_calls.handle_call_signal(self.server, {"call_id": "call", **packet}, ConnectionContext(socket, "caller"))
        self.assertEqual(3, len(self.server.errors))
        self.assertEqual([], self.server.clients["callee"].sent)

    async def test_free_caption_sender_needs_sponsored_consent(self):
        socket = self.server.clients["callee"]
        await self.command("start")
        row = server_call_captions.caption_session(self.server, "call")
        packet = {"type": "call_caption", "call_id": "call", "group_id": "group",
                  "destination_node": "guest", "caption_id": "line", "text": "Hello",
                  "caption_session_id": row[3]}
        await server_calls.handle_call_signal(self.server, packet, ConnectionContext(socket, "callee"))
        self.assertEqual("meshpro_required", self.server.errors[-1][0])
        await self.command("join", "callee")
        await server_calls.handle_call_signal(self.server, packet, ConnectionContext(socket, "callee"))
        self.assertEqual("call_caption", self.server.clients["guest"].sent[-1]["type"])
