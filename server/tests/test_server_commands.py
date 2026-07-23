import json
import unittest

from server.server_commands import (
    ConnectionContext,
    PacketCommandRegistry,
    StopConnectionHandler,
    build_control_command_registry,
    build_command_registry,
)


class FakeWebSocket:
    def __init__(self):
        self.sent = []
        self.closed = None

    async def send(self, payload):
        self.sent.append(json.loads(payload))

    async def close(self, code=None, reason=None):
        self.closed = (code, reason)


class FakeCommandServer:
    def __init__(self):
        self.client_logins = {"client-node": "client-login"}
        self.service_logins = {"service-node": "service-login"}
        self.clients = {}
        self.service_clients = {}
        self.client_services = {}
        self.client_capabilities = {
            "client-node": {
                "sticker_library_chunks": True,
                "sync_v2": True,
            }
        }
        self.calls = []
        self.user_list_sends = 0
        self.scheduled = []
        self.delete_ok = True

    def subscription_catalog(self, product):
        return {"product": product} if product == "meshpro" else None

    def subscription_status(self, login, product):
        return {"login": login, "product": product}

    async def rewrite_text_with_ai(self, login, text, style):
        self.calls.append((login, text, style))
        return {"ok": True, "text": f"{style}:{text}"}

    def get_login_by_node(self, node_id):
        return self.client_logins.get(node_id)

    def save_account_profile(self, *values):
        self.calls.append(("profile", values))
        return True, "ok"

    async def send_user_list(self):
        self.user_list_sends += 1

    def get_account_devices(self, login):
        return [{"node_id": "other-node", "login": login}]

    def update_account_device(
        self,
        login,
        target_node,
        action,
        device_name,
    ):
        self.calls.append(
            ("device", login, target_node, action, device_name)
        )
        return True, "ok"

    def create_scheduled_message(self, node_id, packet):
        item = {"schedule_id": "scheduled-1", "node_id": node_id}
        self.scheduled.append(item)
        return True, "ok", item

    def cancel_scheduled_message(self, node_id, schedule_id):
        self.calls.append(("cancel", node_id, schedule_id))
        return schedule_id == "scheduled-1"

    def list_scheduled_messages(self, login):
        return [*self.scheduled, {"login": login}]

    async def create_subscription_checkout(
        self,
        login,
        node_id,
        request_id,
        product,
        plan_code,
        buyer_email=None,
    ):
        self.calls.append(
            (
                "checkout",
                login,
                node_id,
                request_id,
                product,
                plan_code,
                buyer_email,
            )
        )
        return {"checkout_id": "checkout-1"}

    def vpn_config_for(self, login, node_id):
        self.calls.append(("vpn", login, node_id))
        return "config", {"active": True}, "ok"

    def revoke_service_session(self, token, service_name):
        self.calls.append(("logout", token, service_name))

    def revoke_wireguard_peers(self, login, product, node_id):
        self.calls.append(("revoke-vpn", login, product, node_id))

    def save_meshpro_preferences(
        self,
        login,
        quick_reactions,
        hd_audio,
        enhanced_noise_suppression,
    ):
        self.calls.append(
            (
                "meshpro-preferences",
                login,
                quick_reactions,
                hd_audio,
                enhanced_noise_suppression,
            )
        )
        return True, "ok"

    def get_meshpro_preferences(self, login):
        return {"login": login, "hd_audio": True}

    def save_chat_preferences(
        self,
        login,
        chat_key,
        theme_id,
        bubble_style,
        animated_background,
    ):
        self.calls.append(
            (
                "chat-preferences",
                login,
                chat_key,
                theme_id,
                bubble_style,
                animated_background,
            )
        )
        return True, "ok"

    def invalidate_sync_v2_snapshot(
        self,
        login,
        reason,
        operation_id,
        metadata=None,
    ):
        self.calls.append(
            (
                "invalidate",
                login,
                reason,
                operation_id,
                metadata,
            )
        )

    def get_online_account_nodes(self, login):
        return [
            node_id
            for node_id, account_login in self.client_logins.items()
            if account_login == login
        ]

    def account_email(self, login):
        return ""

    def normalize_email(self, email):
        return str(email or "").strip().lower()

    def mask_email(self, email):
        return f"***@{str(email).split('@')[-1]}"

    async def issue_email_challenge_async(
        self,
        login,
        node_id,
        email,
        purpose,
    ):
        self.calls.append(
            ("email-challenge", login, node_id, email, purpose)
        )
        return {"challenge_id": "challenge-1"}, "ok"

    def verify_email_challenge(
        self,
        challenge_id,
        login,
        node_id,
        code,
        purpose,
    ):
        self.calls.append(
            (
                "email-verify",
                challenge_id,
                login,
                node_id,
                code,
                purpose,
            )
        )
        return True, "verified", "user@example.com"

    def bind_account_email(self, login, email, node_id):
        self.calls.append(("email-bind", login, email, node_id))
        return True, "ok"

    def acknowledge_offline_packet(self, node_id, queue_id):
        self.calls.append(("offline-ack", node_id, queue_id))

    def acknowledge_sync_v2_cursor(self, login, node_id, cursor):
        self.calls.append(("sync-ack", login, node_id, cursor))

    async def send_account_sync(self, *args):
        self.calls.append(("account-sync", args))

    def delete_account(self, login, password):
        self.calls.append(("account-delete", login, password))
        return (
            (True, "ok")
            if self.delete_ok
            else (False, "wrong_password")
        )

    def cancel_file_transfer(self, login, transfer_id):
        self.calls.append(("file-cancel", login, transfer_id))
        return True

    def save_file_transfer_chunk(self, packet, login):
        self.calls.append(("file-save", login, dict(packet)))
        return {
            "ok": True,
            "newly_completed": True,
            "transfer_id": packet.get("transfer_id"),
        }

    async def send_file_transfer_ack(
        self,
        websocket,
        packet,
        transfer_result,
    ):
        self.calls.append(("file-ack", transfer_result))

    async def deliver_completed_file_transfer(self, transfer_result):
        self.calls.append(("file-deliver", transfer_result))


class PacketCommandRegistryTests(unittest.IsolatedAsyncioTestCase):
    async def test_unknown_packet_is_left_for_legacy_dispatch(self):
        registry = build_command_registry()
        handled = await registry.dispatch(
            FakeCommandServer(),
            {"type": "legacy_packet"},
            ConnectionContext(FakeWebSocket(), "client-node"),
        )
        self.assertFalse(handled)

    def test_duplicate_packet_type_is_rejected(self):
        registry = PacketCommandRegistry()

        async def handler(server, packet, context):
            return None

        registry.register("example", handler)
        with self.assertRaisesRegex(ValueError, "duplicate packet command"):
            registry.register("example", handler)

    async def test_ai_command_preserves_request_and_result_shape(self):
        registry = build_command_registry()
        websocket = FakeWebSocket()
        server = FakeCommandServer()
        handled = await registry.dispatch(
            server,
            {
                "type": "ai_text_rewrite_request",
                "request_id": "request-1",
                "text": "hello",
                "style": "formal",
            },
            ConnectionContext(websocket, "client-node"),
        )

        self.assertTrue(handled)
        self.assertEqual(
            [("client-login", "hello", "formal")],
            server.calls,
        )
        self.assertEqual(
            {
                "type": "ai_text_rewrite_result",
                "request_id": "request-1",
                "ok": True,
                "text": "formal:hello",
            },
            websocket.sent[0],
        )

    async def test_subscription_status_uses_service_identity(self):
        registry = build_command_registry()
        websocket = FakeWebSocket()
        handled = await registry.dispatch(
            FakeCommandServer(),
            {
                "type": "subscription_status_request",
                "product": "meshpro",
            },
            ConnectionContext(
                websocket,
                "service-node",
                is_service_connection=True,
            ),
        )

        self.assertTrue(handled)
        self.assertEqual(
            {
                "type": "subscription_status_result",
                "ok": True,
                "subscription": {
                    "login": "service-login",
                    "product": "meshpro",
                },
            },
            websocket.sent[0],
        )

    async def test_profile_update_broadcasts_user_list(self):
        registry = build_command_registry()
        websocket = FakeWebSocket()
        server = FakeCommandServer()
        handled = await registry.dispatch(
            server,
            {
                "type": "profile_update",
                "login": "client-login",
                "source_node": "client-node",
                "display_name": "Alice",
                "public_username": "alice",
            },
            ConnectionContext(websocket, "client-node"),
        )

        self.assertTrue(handled)
        self.assertEqual(1, server.user_list_sends)
        self.assertEqual("profile_update_result", websocket.sent[0]["type"])
        self.assertTrue(websocket.sent[0]["ok"])

    async def test_device_revoke_closes_target_session(self):
        registry = build_command_registry()
        websocket = FakeWebSocket()
        target = FakeWebSocket()
        server = FakeCommandServer()
        server.clients["other-node"] = target

        handled = await registry.dispatch(
            server,
            {
                "type": "active_device_action_request",
                "request_id": "device-request",
                "target_node": "other-node",
                "action": "revoke",
            },
            ConnectionContext(websocket, "client-node"),
        )

        self.assertTrue(handled)
        self.assertEqual("device_revoked", target.sent[0]["code"])
        self.assertEqual(
            (4003, "device session revoked"),
            target.closed,
        )

    async def test_scheduled_message_commands_keep_response_contract(self):
        registry = build_command_registry()
        websocket = FakeWebSocket()
        server = FakeCommandServer()
        context = ConnectionContext(websocket, "client-node")

        self.assertTrue(
            await registry.dispatch(
                server,
                {
                    "type": "scheduled_message_create",
                    "request_id": "create-request",
                },
                context,
            )
        )
        self.assertTrue(
            await registry.dispatch(
                server,
                {
                    "type": "scheduled_message_cancel",
                    "request_id": "cancel-request",
                    "schedule_id": "scheduled-1",
                },
                context,
            )
        )
        self.assertTrue(
            await registry.dispatch(
                server,
                {"type": "scheduled_messages_request"},
                context,
            )
        )

        self.assertEqual(
            [
                "scheduled_message_result",
                "scheduled_message_result",
                "scheduled_messages",
            ],
            [payload["type"] for payload in websocket.sent],
        )
        self.assertEqual("create", websocket.sent[0]["action"])
        self.assertEqual("cancel", websocket.sent[1]["action"])

    async def test_meshprivacy_checkout_and_vpn_use_service_identity(self):
        registry = build_command_registry()
        websocket = FakeWebSocket()
        server = FakeCommandServer()
        server.service_clients["service-node"] = websocket
        server.client_services["service-node"] = "meshprivacy"
        context = ConnectionContext(
            websocket,
            "service-node",
            is_service_connection=True,
        )

        await registry.dispatch(
            server,
            {
                "type": "subscription_checkout_request",
                "client_request_id": "request-1",
                "product": "meshpro",
                "plan_code": "monthly",
                "email": "buyer@example.com",
            },
            context,
        )
        await registry.dispatch(
            server,
            {"type": "vpn_config_request"},
            context,
        )

        self.assertTrue(websocket.sent[0]["ok"])
        self.assertEqual(
            {"checkout_id": "checkout-1"},
            websocket.sent[0]["checkout"],
        )
        self.assertTrue(websocket.sent[1]["ok"])
        self.assertEqual("config", websocket.sent[1]["config"])
        self.assertIn(
            ("vpn", "service-login", "service-node"),
            server.calls,
        )

    async def test_service_logout_revokes_session_and_wireguard_peer(self):
        registry = build_command_registry()
        websocket = FakeWebSocket()
        server = FakeCommandServer()
        server.service_clients["service-node"] = websocket
        server.client_services["service-node"] = "meshprivacy"

        await registry.dispatch(
            server,
            {
                "type": "service_logout",
                "service_session_token": "session-token",
            },
            ConnectionContext(
                websocket,
                "service-node",
                is_service_connection=True,
            ),
        )

        self.assertIn(
            ("logout", "session-token", "meshprivacy"),
            server.calls,
        )
        self.assertIn(
            (
                "revoke-vpn",
                "service-login",
                "meshpro",
                "service-node",
            ),
            server.calls,
        )
        self.assertTrue(websocket.sent[0]["ok"])

    async def test_preference_commands_invalidate_sync_snapshot(self):
        registry = build_command_registry()
        websocket = FakeWebSocket()
        server = FakeCommandServer()
        context = ConnectionContext(websocket, "client-node")

        await registry.dispatch(
            server,
            {
                "type": "meshpro_preferences_update",
                "request_id": "meshpro-request",
                "quick_reactions": ["heart"],
                "hd_audio": True,
                "enhanced_noise_suppression": True,
            },
            context,
        )
        await registry.dispatch(
            server,
            {
                "type": "chat_preferences_update",
                "request_id": "chat-request",
                "chat_key": "chat-1",
                "theme_id": "aurora",
                "bubble_style": "glass",
                "animated_background": True,
            },
            context,
        )

        invalidations = [
            call
            for call in server.calls
            if call[0] == "invalidate"
        ]
        self.assertEqual(2, len(invalidations))
        self.assertEqual(
            "meshpro_preferences_result",
            websocket.sent[0]["type"],
        )
        self.assertEqual(
            "chat_preferences_result",
            websocket.sent[1]["type"],
        )

    async def test_control_registry_binds_verified_email(self):
        registry = build_control_command_registry()
        websocket = FakeWebSocket()
        server = FakeCommandServer()
        context = ConnectionContext(websocket, "client-node")

        await registry.dispatch(
            server,
            {
                "type": "email_verification_request",
                "email": " USER@EXAMPLE.COM ",
            },
            context,
        )
        await registry.dispatch(
            server,
            {
                "type": "email_verification_confirm",
                "challenge_id": "challenge-1",
                "code": "123456",
            },
            context,
        )

        self.assertEqual(
            "challenge-1",
            websocket.sent[0]["challenge_id"],
        )
        self.assertTrue(websocket.sent[1]["complete"])
        self.assertIn(
            (
                "email-bind",
                "client-login",
                "user@example.com",
                "client-node",
            ),
            server.calls,
        )

    async def test_account_delete_stops_handler_only_after_success(self):
        registry = build_control_command_registry()
        websocket = FakeWebSocket()
        server = FakeCommandServer()
        server.clients["client-node"] = websocket
        context = ConnectionContext(websocket, "client-node")

        server.delete_ok = False
        handled = await registry.dispatch(
            server,
            {
                "type": "account_delete_request",
                "request_id": "delete-failed",
                "password": "wrong",
            },
            context,
        )
        self.assertTrue(handled)
        self.assertFalse(websocket.sent[-1]["ok"])
        self.assertIsNone(websocket.closed)

        server.delete_ok = True
        with self.assertRaises(StopConnectionHandler):
            await registry.dispatch(
                server,
                {
                    "type": "account_delete_request",
                    "request_id": "delete-success",
                    "password": "correct",
                },
                context,
            )

        self.assertTrue(websocket.sent[-1]["ok"])
        self.assertEqual((1000, "account deleted"), websocket.closed)
        self.assertEqual(1, server.user_list_sends)

    async def test_control_registry_acks_and_requests_account_sync(self):
        registry = build_control_command_registry()
        websocket = FakeWebSocket()
        server = FakeCommandServer()
        started = []

        async def start_account_sync(operation):
            started.append(True)
            await operation

        context = ConnectionContext(
            websocket,
            "client-node",
            start_account_sync=start_account_sync,
        )
        await registry.dispatch(
            server,
            {"type": "offline_packet_ack", "queue_id": "queue-1"},
            context,
        )
        await registry.dispatch(
            server,
            {"type": "sync_v2_ack", "cursor": 42},
            context,
        )
        await registry.dispatch(
            server,
            {"type": "sync_v2_snapshot_request"},
            context,
        )

        self.assertIn(
            ("offline-ack", "client-node", "queue-1"),
            server.calls,
        )
        self.assertIn(
            ("sync-ack", "client-login", "client-node", 42),
            server.calls,
        )
        self.assertEqual([True], started)
        sync_call = next(
            call
            for call in server.calls
            if call[0] == "account-sync"
        )
        self.assertTrue(sync_call[1][3])
        self.assertTrue(sync_call[1][4])

    async def test_file_transfer_v2_is_handled_but_legacy_falls_through(self):
        registry = build_control_command_registry()
        websocket = FakeWebSocket()
        server = FakeCommandServer()
        context = ConnectionContext(websocket, "client-node")

        legacy_handled = await registry.dispatch(
            server,
            {
                "type": "file_chunk",
                "transfer_id": "legacy-transfer",
            },
            context,
        )
        self.assertFalse(legacy_handled)

        server.client_capabilities["client-node"]["file_transfer_v2"] = True
        handled = await registry.dispatch(
            server,
            {
                "type": "file_chunk",
                "transfer_id": "transfer-1",
                "file_transfer_v2": True,
            },
            context,
        )

        self.assertTrue(handled)
        self.assertIn(
            (
                "file-save",
                "client-login",
                {
                    "type": "file_chunk",
                    "transfer_id": "transfer-1",
                    "file_transfer_v2": True,
                    "source_node": "client-node",
                },
            ),
            server.calls,
        )
        self.assertTrue(
            any(call[0] == "file-deliver" for call in server.calls)
        )
