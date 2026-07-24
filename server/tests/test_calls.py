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
