import asyncio
import json
import sqlite3
import tempfile
import unittest
import uuid
from pathlib import Path

import websockets
from websockets.exceptions import ConnectionClosed

from server import server as server_module
from server import server_auth, server_storage


class ServerSchemaMigrationTests(unittest.TestCase):
    def test_legacy_file_and_chat_delete_tables_are_migrated(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            db_path = Path(temp_dir) / "legacy.db"
            connection = sqlite3.connect(db_path)
            connection.execute(
                """
                CREATE TABLE server_chat_deletes(
                    owner_node TEXT NOT NULL,
                    peer_node TEXT NOT NULL,
                    deleted_at DATETIME DEFAULT CURRENT_TIMESTAMP,
                    PRIMARY KEY(owner_node, peer_node)
                )
                """
            )
            connection.execute(
                """
                CREATE TABLE server_files(
                    file_id TEXT PRIMARY KEY,
                    sender_node TEXT,
                    sender_login TEXT,
                    sender_name TEXT,
                    receiver_node TEXT,
                    receiver_login TEXT,
                    group_id TEXT,
                    filename TEXT,
                    data TEXT,
                    created_at DATETIME DEFAULT CURRENT_TIMESTAMP
                )
                """
            )
            connection.commit()
            connection.close()

            previous_path = server_storage.DB_PATH
            server_storage.DB_PATH = db_path
            relay = None
            try:
                relay = server_module.MeshRelayServer()
                chat_columns = {
                    row[1]
                    for row in relay.db.execute(
                        "PRAGMA table_info(server_chat_deletes)"
                    ).fetchall()
                }
                file_columns = {
                    row[1]
                    for row in relay.db.execute(
                        "PRAGMA table_info(server_files)"
                    ).fetchall()
                }
                self.assertTrue(
                    {"owner_login", "peer_login", "chat_kind", "chat_id"}
                    <= chat_columns
                )
                self.assertTrue(
                    {
                        "group_name",
                        "is_channel",
                        "comments_enabled",
                        "reply_to_message_id",
                        "reply_to_text",
                        "is_channel_comment",
                    }
                    <= file_columns
                )
                self.assertEqual(
                    "ok",
                    relay.db.execute("PRAGMA integrity_check").fetchone()[0],
                )
            finally:
                if relay is not None:
                    relay.db.close()
                server_storage.DB_PATH = previous_path

    def test_startup_housekeeping_keeps_only_supported_current_packets(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            db_path = Path(temp_dir) / "housekeeping.db"
            previous_path = server_storage.DB_PATH
            server_storage.DB_PATH = db_path
            relay = None
            reopened = None
            try:
                relay = server_module.MeshRelayServer()
                packets = [
                    (
                        "device-current",
                        {"type": "chat_request", "packet_id": "keep-me"},
                        "CURRENT_TIMESTAMP",
                    ),
                    (
                        "device-stale",
                        {"type": "chat_request", "packet_id": "expire-me"},
                        "'2000-01-01 00:00:00'",
                    ),
                    (
                        "SERVER",
                        {"type": "group_update", "packet_id": "server-only"},
                        "CURRENT_TIMESTAMP",
                    ),
                    (
                        "device-typing",
                        {"type": "typing", "packet_id": "transient"},
                        "CURRENT_TIMESTAMP",
                    ),
                ]
                for destination, packet, created_at in packets:
                    relay.db.execute(
                        f"""
                        INSERT INTO offline_packets(
                            destination_node,
                            packet_json,
                            created_at
                        )
                        VALUES(?,?,{created_at})
                        """,
                        (destination, json.dumps(packet)),
                    )
                relay.db.execute(
                    """
                    INSERT INTO offline_packets(destination_node, packet_json)
                    VALUES('device-invalid', 'not-json')
                    """
                )
                relay.db.execute(
                    """
                    INSERT INTO direct_messages(message_id, message)
                    VALUES('live-message', 'payload')
                    """
                )
                relay.db.execute(
                    """
                    INSERT INTO server_reactions(
                        scope,
                        message_id,
                        reactor_node,
                        reaction
                    )
                    VALUES('direct', 'live-message', 'reactor-1', 'heart')
                    """
                )
                relay.db.execute(
                    """
                    INSERT INTO server_reactions(
                        scope,
                        message_id,
                        reactor_node,
                        reaction
                    )
                    VALUES('direct', 'missing-message', 'reactor-2', 'heart')
                    """
                )
                relay.db.commit()
                relay.db.close()
                relay = None

                reopened = server_module.MeshRelayServer()
                queued = reopened.db.execute(
                    """
                    SELECT destination_node, packet_json
                    FROM offline_packets
                    ORDER BY id
                    """
                ).fetchall()
                self.assertEqual(1, len(queued))
                self.assertEqual("device-current", queued[0][0])
                self.assertEqual("keep-me", json.loads(queued[0][1])["packet_id"])

                reactions = reopened.db.execute(
                    """
                    SELECT message_id
                    FROM server_reactions
                    ORDER BY message_id
                    """
                ).fetchall()
                self.assertEqual([("live-message",)], reactions)
            finally:
                if relay is not None:
                    relay.db.close()
                if reopened is not None:
                    reopened.db.close()
                server_storage.DB_PATH = previous_path


class TestClient:
    def __init__(self, uri, login, password, node_id, display_name=None):
        self.uri = uri
        self.login = login
        self.password = password
        self.node_id = node_id
        self.display_name = display_name or login.title()
        self.websocket = None
        self.sync = None
        self.pending = []

    async def connect(self):
        self.websocket = await websockets.connect(
            self.uri,
            max_size=server_module.WEBSOCKET_MAX_SIZE,
        )
        await self.send(
            {
                "type": "server_hello",
                "node_id": self.node_id,
                "username": self.login,
                "display_name": self.display_name,
                "login": self.login,
                "password": self.password,
                "public_username": self.login,
                "server_token": "integration-test-token",
                "encryption_public_key": f"public-key:{self.node_id}",
                "protocol_version": 5,
                "min_protocol_version": 5,
                "app_version": "integration-test",
            }
        )
        await self.receive_type("server_welcome")
        self.sync = await self.receive_type("server_sync")
        self.sync["file_chunks"] = []
        while True:
            packet = await self.receive()
            if packet.get("type") == "server_file_sync_chunk":
                self.sync["file_chunks"].append(packet)
            if packet.get("type") == "server_sync_done":
                break
        return self.sync

    async def send(self, packet):
        await self.websocket.send(json.dumps(packet, ensure_ascii=False))

    async def receive(self, timeout=2.0):
        if self.pending:
            return self.pending.pop(0)
        raw = await asyncio.wait_for(self.websocket.recv(), timeout=timeout)
        return json.loads(raw)

    async def receive_type(self, packet_type, timeout=2.0):
        for index, packet in enumerate(self.pending):
            if packet.get("type") == packet_type:
                return self.pending.pop(index)

        deadline = asyncio.get_running_loop().time() + timeout
        while True:
            remaining = deadline - asyncio.get_running_loop().time()
            if remaining <= 0:
                raise TimeoutError(f"Packet {packet_type!r} was not received")
            raw = await asyncio.wait_for(self.websocket.recv(), timeout=remaining)
            packet = json.loads(raw)
            if packet.get("type") == packet_type:
                return packet
            self.pending.append(packet)

    async def close(self):
        if self.websocket is not None:
            await self.websocket.close()
            self.websocket = None


class ServerSyncIntegrationTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        server_storage.DB_PATH = Path(self.temp_dir.name) / "server.db"
        server_auth.PASSWORD_ITERATIONS = 1_000
        server_module.SERVER_TOKEN = "integration-test-token"
        server_module.REQUIRE_LOGIN = True

        self.relay = server_module.MeshRelayServer()
        self.server = await websockets.serve(
            self.relay.handler,
            "127.0.0.1",
            0,
            max_size=server_module.WEBSOCKET_MAX_SIZE,
        )
        port = self.server.sockets[0].getsockname()[1]
        self.uri = f"ws://127.0.0.1:{port}"
        self.clients = []

    async def asyncTearDown(self):
        for client in reversed(self.clients):
            await client.close()
        self.server.close()
        await self.server.wait_closed()
        self.relay.db.close()
        self.temp_dir.cleanup()

    async def connect(self, login, node_id=None, password="test-password"):
        client = TestClient(
            self.uri,
            login,
            password,
            node_id or str(uuid.uuid4()),
        )
        self.clients.append(client)
        await client.connect()
        return client

    async def send_and_receive(self, source, destination, packet_type, **data):
        packet = {
            "type": packet_type,
            "packet_id": data.pop("packet_id", str(uuid.uuid4())),
            "protocol_version": 5,
            "source_node": source.node_id,
            "destination_node": destination.node_id,
            "sender": source.login,
            "ttl": 5,
            **data,
        }
        await source.send(packet)
        return await destination.receive_type(packet_type)

    async def test_offline_queue_only_keeps_non_syncable_events(self):
        alice = await self.connect("queue_alice")
        bob = await self.connect("queue_bob")
        bob_node = bob.node_id
        await bob.close()
        await asyncio.sleep(0.05)

        base_packet = {
            "protocol_version": 5,
            "source_node": alice.node_id,
            "destination_node": bob_node,
            "sender": alice.login,
            "ttl": 5,
        }
        await alice.send(
            {
                **base_packet,
                "type": "chat_message",
                "packet_id": "offline-history-message",
                "message": "encrypted payload",
            }
        )
        await alice.send(
            {
                **base_packet,
                "type": "typing",
                "packet_id": "offline-typing",
            }
        )
        await alice.send(
            {
                **base_packet,
                "type": "chat_request",
                "packet_id": "offline-chat-request",
            }
        )
        await alice.send(
            {
                **base_packet,
                "type": "message_delete",
                "packet_id": "offline-delete-event",
                "message_id": "offline-history-message",
            }
        )
        await alice.send(
            {
                "type": "group_update",
                "packet_id": "server-group-update",
                "protocol_version": 5,
                "source_node": alice.node_id,
                "destination_node": "SERVER",
                "group_id": "queue-group",
                "group_name": "Queue group",
                "members": [alice.node_id],
                "owner_node": alice.node_id,
                "admins": [alice.node_id],
                "is_channel": False,
                "ttl": 5,
            }
        )
        await asyncio.sleep(0.1)

        queued = self.relay.db.execute(
            "SELECT destination_node, packet_json FROM offline_packets ORDER BY id"
        ).fetchall()
        self.assertEqual([bob_node, bob_node], [row[0] for row in queued])
        self.assertEqual(
            ["chat_request", "message_delete"],
            [json.loads(row[1])["type"] for row in queued],
        )
        self.assertIsNone(
            self.relay.db.execute(
                "SELECT 1 FROM direct_messages WHERE message_id=?",
                ("offline-history-message",),
            ).fetchone()
        )
        self.assertIsNotNone(
            self.relay.db.execute(
                "SELECT 1 FROM server_groups WHERE group_id=?",
                ("queue-group",),
            ).fetchone()
        )

        bob_reconnected = await self.connect("queue_bob", node_id=bob_node)
        self.assertEqual(
            "offline-chat-request",
            (await bob_reconnected.receive_type("chat_request"))["packet_id"],
        )
        self.assertEqual(
            "offline-history-message",
            (await bob_reconnected.receive_type("message_delete"))["message_id"],
        )
        self.assertEqual(
            0,
            self.relay.db.execute(
                "SELECT COUNT(*) FROM offline_packets"
            ).fetchone()[0],
        )

    async def test_direct_history_and_deletion_survive_device_change(self):
        alice_phone = await self.connect("alice")
        bob_phone = await self.connect("bob")

        await self.send_and_receive(
            alice_phone,
            bob_phone,
            "chat_message",
            packet_id="direct-message-1",
            message="encrypted payload",
        )

        await alice_phone.close()
        alice_desktop = await self.connect("alice")
        self.assertEqual(
            ["direct-message-1"],
            [item["message_id"] for item in alice_desktop.sync["direct_messages"]],
        )

        await self.send_and_receive(
            alice_desktop,
            bob_phone,
            "message_delete",
            message_id="direct-message-1",
        )
        await bob_phone.close()
        bob_tablet = await self.connect("bob")
        self.assertNotIn(
            "direct-message-1",
            {item["message_id"] for item in bob_tablet.sync["direct_messages"]},
        )

        await self.send_and_receive(
            alice_desktop,
            bob_tablet,
            "chat_message",
            packet_id="direct-message-2",
            message="another encrypted payload",
        )
        await self.send_and_receive(
            alice_desktop,
            bob_tablet,
            "chat_delete",
            chat_node_id=bob_tablet.node_id,
            chat_kind="normal",
            chat_id="",
        )

        await alice_desktop.close()
        await bob_tablet.close()
        alice_laptop = await self.connect("alice")
        bob_laptop = await self.connect("bob")
        self.assertEqual([], alice_laptop.sync["direct_messages"])
        self.assertEqual([], bob_laptop.sync["direct_messages"])

    async def test_wrong_password_never_receives_account_sync(self):
        registered = await self.connect("password_owner")
        await registered.close()

        rejected = TestClient(
            self.uri,
            "password_owner",
            "wrong-password",
            str(uuid.uuid4()),
        )
        self.clients.append(rejected)
        with self.assertRaises(ConnectionClosed):
            await rejected.connect()

        accepted = await self.connect("password_owner")
        self.assertEqual("password_owner", accepted.sync["profile"]["login"])

    async def test_group_owner_permissions_and_membership_survive_relogin(self):
        owner_phone = await self.connect("owner")
        member_phone = await self.connect("member")
        observer_phone = await self.connect("observer")
        group_id = "group-integration-1"
        members = [
            owner_phone.node_id,
            member_phone.node_id,
            observer_phone.node_id,
        ]

        await self.send_and_receive(
            owner_phone,
            member_phone,
            "group_update",
            group_id=group_id,
            group_name="Reliable group",
            group_about="Persistent metadata",
            group_avatar_data="avatar-data",
            members=members,
            owner_node=owner_phone.node_id,
            admins=[owner_phone.node_id],
            is_channel=False,
            comments_enabled=True,
        )

        await owner_phone.close()
        owner_desktop = await self.connect("owner")
        group = next(
            item for item in owner_desktop.sync["groups"] if item["group_id"] == group_id
        )
        self.assertEqual(owner_desktop.node_id, group["owner_node"])
        self.assertIn(owner_desktop.node_id, group["members"])
        self.assertEqual("avatar-data", group["group_avatar_data"])

        await member_phone.send(
            {
                "type": "group_delete",
                "packet_id": str(uuid.uuid4()),
                "protocol_version": 5,
                "source_node": member_phone.node_id,
                "destination_node": observer_phone.node_id,
                "group_id": group_id,
                "ttl": 5,
            }
        )
        await asyncio.sleep(0.05)
        self.assertIsNotNone(
            self.relay.db.execute(
                "SELECT 1 FROM server_groups WHERE group_id=?", (group_id,)
            ).fetchone()
        )

        await self.send_and_receive(
            owner_desktop,
            observer_phone,
            "group_delete",
            group_id=group_id,
        )
        self.assertIsNone(
            self.relay.db.execute(
                "SELECT 1 FROM server_groups WHERE group_id=?", (group_id,)
            ).fetchone()
        )

    async def test_channel_history_files_reactions_and_member_leave(self):
        owner = await self.connect("channel_owner")
        member = await self.connect("channel_member")
        newcomer = await self.connect("channel_newcomer")
        group_id = "channel-integration-1"

        await self.send_and_receive(
            owner,
            member,
            "group_update",
            group_id=group_id,
            group_name="News channel",
            members=[owner.node_id, member.node_id],
            owner_node=owner.node_id,
            admins=[owner.node_id],
            is_channel=True,
            comments_enabled=True,
        )
        await self.send_and_receive(
            owner,
            member,
            "group_message",
            packet_id="channel-post-1",
            group_message_id="channel-post-1",
            group_id=group_id,
            group_name="News channel",
            members=[owner.node_id, member.node_id],
            owner_node=owner.node_id,
            admins=[owner.node_id],
            is_channel=True,
            message="encrypted channel post",
            group_key_id="key-1",
        )
        await self.send_and_receive(
            owner,
            member,
            "file_chunk",
            file_id="channel-image-1",
            filename="encrypted-image-name",
            caption="encrypted-caption",
            data="01020304",
            chunk_index=0,
            total_chunks=1,
            message_kind="image",
            group_id=group_id,
            group_name="News channel",
            is_channel=True,
            comments_enabled=True,
            reply_to_message_id="channel-post-1",
            reply_to_text="Original post",
            is_channel_comment=True,
            group_key_id="key-1",
        )

        for _ in range(2):
            await member.send(
                {
                    "type": "group_reaction",
                    "packet_id": str(uuid.uuid4()),
                    "protocol_version": 5,
                    "source_node": member.node_id,
                    "destination_node": owner.node_id,
                    "group_id": group_id,
                    "group_message_id": "channel-post-1",
                    "reaction": "heart",
                    "ttl": 5,
                }
            )
        await owner.receive_type("group_reaction")
        await asyncio.sleep(0.05)

        await self.send_and_receive(
            owner,
            newcomer,
            "group_update",
            group_id=group_id,
            group_name="News channel",
            members=[owner.node_id, member.node_id, newcomer.node_id],
            owner_node=owner.node_id,
            admins=[owner.node_id],
            is_channel=True,
            comments_enabled=True,
        )
        await newcomer.close()
        newcomer_relogin = await self.connect("channel_newcomer")
        self.assertIn(
            "channel-post-1",
            {item["message_id"] for item in newcomer_relogin.sync["group_messages"]},
        )
        self.assertIn(
            "channel-image-1",
            {item["file_id"] for item in newcomer_relogin.sync["files"]},
        )
        image_chunk = next(
            item
            for item in newcomer_relogin.sync["file_chunks"]
            if item["file_id"] == "channel-image-1"
        )
        self.assertEqual("image", image_chunk["message_kind"])
        self.assertEqual("News channel", image_chunk["group_name"])
        self.assertTrue(image_chunk["is_channel"])
        self.assertTrue(image_chunk["is_channel_comment"])
        self.assertEqual("channel-post-1", image_chunk["reply_to_message_id"])
        reactions = [
            item
            for item in newcomer_relogin.sync["reactions"]
            if item["message_id"] == "channel-post-1"
        ]
        self.assertEqual(1, len(reactions))

        await owner.close()
        owner_desktop = await self.connect("channel_owner")
        await self.send_and_receive(
            owner_desktop,
            newcomer_relogin,
            "group_message_delete",
            group_id=group_id,
            group_message_id="channel-image-1",
        )
        await newcomer_relogin.close()
        newcomer_after_delete = await self.connect("channel_newcomer")
        self.assertNotIn(
            "channel-image-1",
            {item["file_id"] for item in newcomer_after_delete.sync["files"]},
        )

        await member.close()
        member_desktop = await self.connect("channel_member")
        await self.send_and_receive(
            member_desktop,
            owner_desktop,
            "group_member_leave",
            group_id=group_id,
            leaver_node=member_desktop.node_id,
        )
        await member_desktop.close()
        member_relogin = await self.connect("channel_member")
        self.assertNotIn(group_id, {item["group_id"] for item in member_relogin.sync["groups"]})

    async def test_sticker_library_is_account_scoped_across_devices(self):
        alice_phone = await self.connect("sticker_alice")
        observer = await self.connect("sticker_observer")
        library = {
            "packs": [
                {
                    "id": "pack-1",
                    "name": "Saved stickers",
                    "stickers": [
                        {
                            "id": "sticker-1",
                            "name": "Hello",
                            "file_name": "hello.webp",
                            "mime_type": "image/webp",
                            "data": "010203",
                        }
                    ],
                }
            ],
            "favorite_ids": ["sticker-1"],
        }
        await self.send_and_receive(
            alice_phone,
            observer,
            "sticker_library_update",
            login="sticker_alice",
            sticker_library=library,
        )

        await observer.send(
            {
                "type": "sticker_library_update",
                "packet_id": str(uuid.uuid4()),
                "protocol_version": 5,
                "source_node": observer.node_id,
                "destination_node": alice_phone.node_id,
                "login": "sticker_alice",
                "sticker_library": {"packs": [], "favorite_ids": []},
                "ttl": 5,
            }
        )
        await asyncio.sleep(0.05)

        await observer.send(
            {
                "type": "profile_update",
                "packet_id": str(uuid.uuid4()),
                "protocol_version": 5,
                "source_node": observer.node_id,
                "destination_node": "SERVER",
                "login": "sticker_alice",
                "display_name": "Spoofed name",
                "ttl": 5,
            }
        )
        profile_result = await observer.receive_type("profile_update_result")
        self.assertFalse(profile_result["ok"])

        await alice_phone.close()
        alice_desktop = await self.connect("sticker_alice")
        self.assertEqual(library, alice_desktop.sync["sticker_library"])
        self.assertNotEqual("Spoofed name", alice_desktop.sync["profile"]["display_name"])


if __name__ == "__main__":
    unittest.main()
