import json
import unittest
from unittest.mock import patch

from server import server_push


class FakePushServer(server_push.ServerPushMixin):
    def __init__(self):
        self.clients = {"device-online": object()}
        self.web_subscriptions = {
            "device-primary": [
                (
                    "https://push.example/primary",
                    {"endpoint": "https://push.example/primary"},
                )
            ],
            "device-pwa": [
                (
                    "https://push.example/pwa",
                    {"endpoint": "https://push.example/pwa"},
                )
            ],
        }
        self.android_sends = []
        self.deleted_endpoints = []

    def get_login_by_node(self, node_id):
        if node_id in {
            "device-primary",
            "device-online",
            "device-pwa",
        }:
            return "bob"
        return ""

    def get_account_node_ids(self, login):
        if login != "bob":
            return []
        return [
            "device-primary",
            "device-online",
            "device-pwa",
            "device-primary",
        ]

    def web_push_subscriptions_for_node(self, node_id):
        return self.web_subscriptions.get(node_id, [])

    def delete_web_push_subscription(self, endpoint=None, node_id=None):
        if endpoint:
            self.deleted_endpoints.append(endpoint)

    @property
    def android_push_enabled(self):
        return True

    async def _send_android_push(self, destination_node, notification):
        self.android_sends.append((destination_node, notification))


class PushDeliveryTests(unittest.IsolatedAsyncioTestCase):
    def test_offline_targets_cover_account_devices_without_duplicates(self):
        relay = FakePushServer()

        self.assertEqual(
            ["device-primary", "device-pwa"],
            relay._offline_push_target_nodes("device-primary"),
        )

    async def test_push_reaches_every_offline_account_device(self):
        relay = FakePushServer()
        web_sends = []

        def fake_webpush(**kwargs):
            web_sends.append(kwargs)

        with (
            patch.object(server_push, "webpush", fake_webpush),
            patch.object(
                server_push,
                "WEB_PUSH_VAPID_PRIVATE_KEY",
                "private",
            ),
            patch.object(
                server_push,
                "WEB_PUSH_VAPID_PUBLIC_KEY",
                "public",
            ),
            patch.object(
                server_push,
                "WEB_PUSH_VAPID_SUBJECT",
                "mailto:test@example.com",
            ),
        ):
            await relay.send_web_push_for_packet(
                "device-primary",
                {
                    "type": "chat_message",
                    "packet_id": "packet-1",
                    "source_node": "alice-device",
                    "sender": "Alice",
                },
            )

        self.assertEqual(
            {
                "https://push.example/primary",
                "https://push.example/pwa",
            },
            {
                item["subscription_info"]["endpoint"]
                for item in web_sends
            },
        )
        self.assertEqual(
            ["device-primary", "device-pwa"],
            [item[0] for item in relay.android_sends],
        )
        payload = json.loads(web_sends[0]["data"])
        self.assertEqual("chat:alice-device", payload["tag"])
        self.assertEqual("packet-1", payload["packet_id"])

    def test_call_payload_has_stable_identity(self):
        relay = FakePushServer()

        payload = relay._web_push_payload(
            {
                "type": "call_offer",
                "packet_id": "packet-call",
                "call_id": "call-42",
                "sender": "Alice",
            }
        )

        self.assertEqual("Входящий звонок", payload["body"])
        self.assertEqual("call:call-42", payload["tag"])
        self.assertEqual("call-42", payload["call_id"])


if __name__ == "__main__":
    unittest.main()
