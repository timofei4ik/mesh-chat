import base64
import hashlib
import hmac
import json
import unittest
from unittest.mock import patch

from server import server_calls
from server.server_command_bus import ConnectionContext
from server.server_commands import build_command_registry


class FakeSocket:
    def __init__(self):
        self.sent = []

    async def send(self, value):
        self.sent.append(json.loads(value))


class FakeCallServer:
    def __init__(self):
        self.clients = {}
        self.client_logins = {"caller": "alice", "callee": "bob"}
        self.errors = []
        self.pushes = []

    def get_login_by_node(self, node_id):
        return self.client_logins.get(node_id, "")

    def get_online_account_nodes(self, login):
        return [
            node_id
            for node_id, value in self.client_logins.items()
            if value == login
        ]

    async def send_server_error(self, websocket, code, message, **details):
        self.errors.append((code, message))

    async def send_web_push_for_packet(self, destination, packet):
        self.pushes.append((destination, packet["type"]))


class FakeSignalingPublisher:
    def __init__(self, accepted=True):
        self.accepted = accepted
        self.packets = []

    async def submit(self, packet):
        self.packets.append(dict(packet))
        return self.accepted


class CallDomainTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        server_calls._seen_operations.clear()

    def test_turn_credentials_follow_coturn_rest_formula(self):
        with (
            patch.object(server_calls, "TURN_SHARED_SECRET", "secret"),
            patch.object(
                server_calls,
                "TURN_URLS",
                ("turn:turn.example.test:3478",),
            ),
            patch.object(server_calls, "TURN_STUN_URLS", ()),
            patch.object(server_calls, "TURN_CREDENTIAL_TTL_SECONDS", 600),
        ):
            result = server_calls.build_ice_servers("alice", "node", now=1000)

        self.assertEqual("1600:alice", result[0]["username"])
        expected = base64.b64encode(
            hmac.new(b"secret", b"1600:alice", hashlib.sha1).digest()
        ).decode("ascii")
        self.assertEqual(expected, result[0]["credential"])

    def test_livekit_room_name_does_not_expose_call_id(self):
        room = server_calls.private_room_name("private-call-id", "secret")
        self.assertTrue(room.startswith("mesh-"))
        self.assertNotIn("private-call-id", room)

    async def test_sfu_access_is_closed_when_not_configured(self):
        server = FakeCallServer()
        socket = FakeSocket()
        with patch.object(server_calls, "CALL_SFU_ENABLED", False):
            handled = await build_command_registry().dispatch(
                server,
                {
                    "type": "call_sfu_access_request",
                    "request_id": "request-1",
                    "call_id": "call-1",
                },
                ConnectionContext(socket, "caller"),
            )

        self.assertTrue(handled)
        self.assertFalse(socket.sent[0]["enabled"])
        self.assertEqual("p2p", socket.sent[0]["fallback"])

    async def test_sfu_access_uses_short_lived_room_scoped_token(self):
        server = FakeCallServer()
        socket = FakeSocket()
        with (
            patch.object(server_calls, "CALL_SFU_ENABLED", True),
            patch.object(server_calls, "CALL_SFU_URL", "wss://sfu.test"),
            patch.object(server_calls, "CALL_SFU_API_KEY", "api-key"),
            patch.object(server_calls, "CALL_SFU_API_SECRET", "secret"),
            patch.object(server_calls, "CALL_SFU_TOKEN_TTL_SECONDS", 300),
            patch.object(server_calls, "CALL_SFU_REQUIRE_E2EE", True),
        ):
            await build_command_registry().dispatch(
                server,
                {
                    "type": "call_sfu_access_request",
                    "request_id": "request-2",
                    "call_id": "call-2",
                    "media_e2ee_capability": "frame-v1",
                },
                ConnectionContext(socket, "caller"),
            )

        result = socket.sent[0]
        payload_segment = result["token"].split(".")[1]
        payload_segment += "=" * (-len(payload_segment) % 4)
        payload = json.loads(base64.urlsafe_b64decode(payload_segment))
        self.assertTrue(result["enabled"])
        self.assertEqual(result["room"], payload["video"]["room"])
        self.assertTrue(payload["video"]["roomJoin"])
        self.assertLessEqual(payload["exp"] - payload["nbf"], 305)
        self.assertEqual("frame-v1", result["media_e2ee"])

    async def test_sfu_access_falls_back_without_media_e2ee(self):
        server = FakeCallServer()
        socket = FakeSocket()
        with (
            patch.object(server_calls, "CALL_SFU_ENABLED", True),
            patch.object(server_calls, "CALL_SFU_URL", "wss://sfu.test"),
            patch.object(server_calls, "CALL_SFU_API_KEY", "api-key"),
            patch.object(server_calls, "CALL_SFU_API_SECRET", "secret"),
            patch.object(server_calls, "CALL_SFU_REQUIRE_E2EE", True),
        ):
            await build_command_registry().dispatch(
                server,
                {
                    "type": "call_sfu_access_request",
                    "request_id": "request-3",
                    "call_id": "call-3",
                },
                ConnectionContext(socket, "caller"),
            )

        self.assertFalse(socket.sent[0]["enabled"])
        self.assertEqual("media_e2ee_required", socket.sent[0]["reason"])

    async def test_call_signal_routes_without_history_mutation(self):
        server = FakeCallServer()
        target = FakeSocket()
        server.clients["callee"] = target
        handled = await build_command_registry().dispatch(
            server,
            {
                "type": "call_offer",
                "destination_node": "callee",
                "call_id": "call-1",
            },
            ConnectionContext(FakeSocket(), "caller"),
        )
        self.assertTrue(handled)
        self.assertEqual("caller", target.sent[0]["source_node"])
        self.assertEqual("alice", target.sent[0]["sender_login"])

    async def test_invalid_call_signal_is_rejected(self):
        server = FakeCallServer()
        handled = await build_command_registry().dispatch(
            server,
            {"type": "call_offer", "call_id": "call-1"},
            ConnectionContext(FakeSocket(), "caller"),
        )
        self.assertTrue(handled)

    async def test_live_caption_is_ephemeral_and_not_pushed(self):
        server = FakeCallServer()
        target = FakeSocket()
        server.clients["callee"] = target

        handled = await build_command_registry().dispatch(
            server,
            {
                "type": "call_caption",
                "destination_node": "callee",
                "call_id": "call-1",
                "caption_id": "caption-1",
                "text": "Hello from the call",
                "final": False,
            },
            ConnectionContext(FakeSocket(), "caller"),
        )

        self.assertTrue(handled)
        self.assertEqual("call_caption", target.sent[0]["type"])
        self.assertEqual("caller", target.sent[0]["source_node"])
        self.assertEqual([], server.pushes)

    async def test_oversized_live_caption_is_rejected(self):
        server = FakeCallServer()
        handled = await build_command_registry().dispatch(
            server,
            {
                "type": "call_caption",
                "destination_node": "callee",
                "call_id": "call-1",
                "caption_id": "caption-1",
                "text": "x" * 801,
            },
            ConnectionContext(FakeSocket(), "caller"),
        )

        self.assertTrue(handled)
        self.assertEqual("invalid_call_signal", server.errors[0][0])

    async def test_oversized_call_signal_is_rejected(self):
        server = FakeCallServer()
        handled = await build_command_registry().dispatch(
            server,
            {
                "type": "call_offer",
                "destination_node": "callee",
                "call_id": "call-1",
                "sdp": "x" * (server_calls._MAX_SDP_LENGTH + 1),
            },
            ConnectionContext(FakeSocket(), "caller"),
        )
        self.assertTrue(handled)
        self.assertEqual("invalid_call_signal", server.errors[0][0])

    async def test_terminal_signal_is_idempotent_and_mirrored_to_own_devices(self):
        server = FakeCallServer()
        server.client_logins["caller-2"] = "alice"
        callee = FakeSocket()
        caller_second_device = FakeSocket()
        server.clients["callee"] = callee
        server.clients["caller-2"] = caller_second_device
        registry = build_command_registry()
        packet = {
            "type": "call_end",
            "destination_node": "callee",
            "call_id": "call-1",
            "operation_id": "end-call-1-caller",
        }

        await registry.dispatch(
            server,
            dict(packet),
            ConnectionContext(FakeSocket(), "caller"),
        )
        await registry.dispatch(
            server,
            dict(packet),
            ConnectionContext(FakeSocket(), "caller"),
        )

        self.assertEqual(1, len(callee.sent))
        self.assertEqual(1, len(caller_second_device.sent))
        self.assertTrue(caller_second_device.sent[0]["mirrored_terminal"])

    async def test_restart_offer_routes_like_other_call_signals(self):
        server = FakeCallServer()
        target = FakeSocket()
        server.clients["callee"] = target

        handled = await build_command_registry().dispatch(
            server,
            {
                "type": "call_restart_offer",
                "destination_node": "callee",
                "call_id": "call-2",
                "sdp": "offer",
            },
            ConnectionContext(FakeSocket(), "caller"),
        )

        self.assertTrue(handled)
        self.assertEqual("call_restart_offer", target.sent[0]["type"])

    async def test_handoff_targets_only_the_selected_account_device(self):
        server = FakeCallServer()
        server.client_logins.update(
            {"caller-2": "alice", "caller-3": "alice"}
        )
        selected = FakeSocket()
        other = FakeSocket()
        server.clients["caller-2"] = selected
        server.clients["caller-3"] = other

        handled = await build_command_registry().dispatch(
            server,
            {
                "type": "call_handoff_request",
                "destination_node": "caller-2",
                "call_id": "call-handoff",
                "peer_node": "callee",
            },
            ConnectionContext(FakeSocket(), "caller"),
        )

        self.assertTrue(handled)
        self.assertEqual(1, len(selected.sent))
        self.assertEqual([], other.sent)

    async def test_handoff_replacement_offer_targets_only_active_peer_device(self):
        server = FakeCallServer()
        server.client_logins["callee-2"] = "bob"
        selected = FakeSocket()
        other = FakeSocket()
        server.clients["callee"] = selected
        server.clients["callee-2"] = other

        handled = await build_command_registry().dispatch(
            server,
            {
                "type": "call_offer",
                "destination_node": "callee",
                "call_id": "call-handoff-new",
                "handoff_from_call_id": "call-handoff-old",
                "sdp": "offer",
            },
            ConnectionContext(FakeSocket(), "caller"),
        )

        self.assertTrue(handled)
        self.assertEqual(1, len(selected.sent))
        self.assertEqual([], other.sent)

    async def test_handoff_rejects_a_device_from_another_account(self):
        server = FakeCallServer()
        target = FakeSocket()
        server.clients["callee"] = target

        handled = await build_command_registry().dispatch(
            server,
            {
                "type": "call_handoff_request",
                "destination_node": "callee",
                "call_id": "call-handoff",
                "peer_node": "peer",
            },
            ConnectionContext(FakeSocket(), "caller"),
        )

        self.assertTrue(handled)
        self.assertEqual([], target.sent)
        self.assertEqual(
            "call_handoff_account_mismatch",
            server.errors[0][0],
        )

    async def test_dedicated_signaling_bypasses_local_socket_and_keeps_push(self):
        server = FakeCallServer()
        server.call_signaling = FakeSignalingPublisher()
        target = FakeSocket()
        server.clients["callee"] = target

        handled = await build_command_registry().dispatch(
            server,
            {
                "type": "call_offer",
                "destination_node": "callee",
                "call_id": "call-dedicated",
            },
            ConnectionContext(FakeSocket(), "caller"),
        )

        self.assertTrue(handled)
        self.assertEqual([], target.sent)
        self.assertEqual(
            "caller",
            server.call_signaling.packets[0]["source_node"],
        )
        self.assertEqual([("callee", "call_offer")], server.pushes)
