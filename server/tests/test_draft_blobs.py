import json
import tempfile
import unittest
from types import SimpleNamespace
from server.server_commands_drafts import handle_draft_blob
from server.server_command_bus import ConnectionContext
from server.server_push import ServerPushMixin


class DraftBlobTests(unittest.IsolatedAsyncioTestCase):
    async def test_owner_isolation_retry_and_validation(self):
        with tempfile.TemporaryDirectory() as root:
            server = SimpleNamespace(draft_blob_root=root, client_logins={"a": "alice", "b": "bob"})
            responses = []
            class Socket:
                async def send(self, value): responses.append(json.loads(value))
            a, b = ConnectionContext(Socket(), "a"), ConnectionContext(Socket(), "b")
            packet = {"type": "draft_blob_put", "blob_id": "12345678-1234-1234-1234-123456789abc", "index": 0, "data": "encrypted", "request_id": "1"}
            await handle_draft_blob(server, packet, a)
            self.assertTrue(responses[-1]["ok"])
            await handle_draft_blob(server, {**packet, "data": "encrypted retry"}, a)
            self.assertTrue(responses[-1]["ok"])
            await handle_draft_blob(server, {**packet, "type": "draft_blob_get"}, b)
            self.assertFalse(responses[-1]["ok"])
            await handle_draft_blob(server, {**packet, "type": "draft_blob_get"}, a)
            self.assertEqual("encrypted retry", responses[-1]["data"])
            for changes in ({"blob_id": "../escape"}, {"index": -1}, {"data": "x" * (192 * 1024 + 1)}):
                await handle_draft_blob(server, {**packet, **changes}, a)
                self.assertFalse(responses[-1]["ok"])

    def test_silent_push_has_no_apple_sound_and_android_data_flag(self):
        push = ServerPushMixin()
        for kind in ("chat_message", "group_message"):
            payload = push._web_push_payload({"type": kind, "silent": True})
            self.assertTrue(payload["silent"])
            self.assertEqual("true", push._android_push_data(payload)["silent"])
            self.assertNotIn("sound", push._apple_push_request(payload)["payload"]["aps"])
        normal = push._web_push_payload({"type": "chat_message"})
        self.assertEqual("default", push._apple_push_request(normal)["payload"]["aps"]["sound"])
