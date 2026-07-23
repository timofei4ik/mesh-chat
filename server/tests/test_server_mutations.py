import unittest

from server.server_mutations import (
    execute_history_mutation,
    prepare_mutation,
)


class FakeWebSocket:
    pass


class FakeMutationServer:
    def __init__(self):
        self.client_logins = {"source": "Alice"}
        self.node_logins = {
            "source": "Alice",
            "destination": "Bob",
            "member-a": "Carol",
            "member-b": "Dave",
        }
        self.processed = False
        self.authorized = True
        self.saved = True
        self.processed_inserted = True
        self.acks = []
        self.calls = []

    def mutation_ack_context(self, node_id, packet):
        if not packet.get("outbox_id"):
            return None
        return {
            "account_login": "alice",
            "outbox_id": packet["outbox_id"],
            "operation_id": packet["operation_id"],
        }

    def mutation_was_processed(self, account_login, outbox_id):
        self.calls.append(("processed", account_login, outbox_id))
        return self.processed

    async def send_mutation_ack(
        self,
        websocket,
        packet,
        context,
        ok=True,
        duplicate=False,
        reason="",
    ):
        self.acks.append(
            {
                "ok": ok,
                "duplicate": duplicate,
                "reason": reason,
                "context": context,
            }
        )

    def authorize_group_management(self, packet):
        self.calls.append(("authorize", packet["type"]))
        return self.authorized

    def get_group_delivery_nodes(self, group_id):
        self.calls.append(("group_targets", group_id))
        return ["source", "member-a", "member-b"]

    def get_login_by_node(self, node_id):
        return self.node_logins.get(node_id)

    def sync_v2_accounts_for_packet(self, packet, extra_nodes):
        self.calls.append(("sync_accounts", tuple(extra_nodes)))
        return ["alice", "bob"]

    def persist_history_mutation(
        self,
        packet,
        sync_event_accounts,
        mutation_context,
    ):
        self.calls.append(
            (
                "persist",
                tuple(sync_event_accounts),
                mutation_context,
            )
        )
        return {
            "saved": self.saved,
            "processed_inserted": self.processed_inserted,
        }

    async def mirror_packet_to_source_account_devices(self, packet):
        self.calls.append(("mirror", packet["type"]))

    async def route_packet(self, packet):
        self.calls.append(("route", dict(packet)))


class MutationPipelineTests(unittest.IsolatedAsyncioTestCase):
    async def test_preparation_acknowledges_already_processed_operation(self):
        server = FakeMutationServer()
        server.processed = True
        packet = {
            "type": "chat_message",
            "outbox_id": "outbox-1",
            "operation_id": "operation-1",
        }

        result = await prepare_mutation(
            server,
            FakeWebSocket(),
            "source",
            packet,
        )

        self.assertTrue(result.duplicate)
        self.assertTrue(server.acks[0]["duplicate"])

    async def test_unauthorized_group_mutation_is_not_persisted(self):
        server = FakeMutationServer()
        server.authorized = False
        context = {
            "account_login": "alice",
            "outbox_id": "outbox-1",
            "operation_id": "operation-1",
        }

        result = await execute_history_mutation(
            server,
            FakeWebSocket(),
            "source",
            {"type": "group_update", "group_id": "group-1"},
            context,
        )

        self.assertFalse(result.accepted)
        self.assertEqual("unauthorized_group_management", result.reason)
        self.assertFalse(any(call[0] == "persist" for call in server.calls))
        self.assertEqual(
            "unauthorized_group_management",
            server.acks[0]["reason"],
        )

    async def test_successful_mutation_enriches_persists_and_routes(self):
        server = FakeMutationServer()
        packet = {
            "type": "message_reaction",
            "source_node": "source",
            "destination_node": "destination",
        }

        result = await execute_history_mutation(
            server,
            FakeWebSocket(),
            "source",
            packet,
            None,
        )

        self.assertTrue(result.accepted)
        self.assertEqual("alice", packet["sender_login"])
        self.assertEqual("alice", packet["reactor_login"])
        self.assertEqual("login:alice", packet["reactor_identity"])
        self.assertEqual("bob", packet["receiver_login"])
        self.assertEqual(
            ["authorize", "sync_accounts", "persist", "mirror", "route"],
            [call[0] for call in server.calls],
        )

    async def test_group_delete_routes_unique_packets_to_all_other_members(self):
        server = FakeMutationServer()
        packet = {
            "type": "group_delete",
            "group_id": "group-1",
            "packet_id": "original-packet",
            "source_node": "source",
        }

        result = await execute_history_mutation(
            server,
            FakeWebSocket(),
            "source",
            packet,
            None,
        )

        self.assertTrue(result.accepted)
        routed = [
            call[1]
            for call in server.calls
            if call[0] == "route"
        ]
        self.assertEqual(
            {"member-a", "member-b"},
            {item["destination_node"] for item in routed},
        )
        self.assertEqual(2, len({item["packet_id"] for item in routed}))
        self.assertTrue(
            all(item["packet_id"] != "original-packet" for item in routed)
        )

    async def test_rejected_persistence_is_not_mirrored_or_routed(self):
        server = FakeMutationServer()
        server.saved = False
        context = {
            "account_login": "alice",
            "outbox_id": "outbox-1",
            "operation_id": "operation-1",
        }

        result = await execute_history_mutation(
            server,
            FakeWebSocket(),
            "source",
            {"type": "chat_message", "source_node": "source"},
            context,
        )

        self.assertFalse(result.accepted)
        self.assertEqual("rejected", result.reason)
        self.assertFalse(any(call[0] == "mirror" for call in server.calls))
        self.assertFalse(any(call[0] == "route" for call in server.calls))
        self.assertEqual("rejected", server.acks[0]["reason"])
