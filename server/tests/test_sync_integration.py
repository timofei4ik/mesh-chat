import asyncio
import hashlib
import json
import sqlite3
import tempfile
import unittest
import uuid
from pathlib import Path

import websockets
from websockets.exceptions import ConnectionClosed

from server import server as server_module
from server import server_auth, server_storage, server_sync


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
                table_names = {
                    row[0]
                    for row in relay.db.execute(
                        "SELECT name FROM sqlite_master WHERE type='table'"
                    ).fetchall()
                }
                sync_event_indexes = {
                    row[1]
                    for row in relay.db.execute(
                        "PRAGMA index_list(sync_events)"
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
                        "message_effect",
                        "storage_path",
                        "sha256",
                        "size_bytes",
                    }
                    <= file_columns
                )
                self.assertTrue(
                    {
                        "sync_events",
                        "sync_cursors",
                        "processed_mutations",
                        "file_transfer_sessions",
                        "file_transfer_chunks",
                    } <= table_names
                )
                self.assertIn(
                    "idx_sync_events_account_cursor",
                    sync_event_indexes,
                )
                event_packet = {
                    "type": "chat_message",
                    "packet_id": "legacy-migration-event",
                    "message": "hello",
                }
                relay.record_sync_v2_event(event_packet, ["legacy-user"])
                relay.record_sync_v2_event(event_packet, ["legacy-user"])
                self.assertEqual(1, relay.sync_v2_cursor("legacy-user"))
                self.assertEqual(
                    1,
                    len(relay.list_sync_v2_events("legacy-user", 0)),
                )
                self.assertTrue(
                    relay.acknowledge_sync_v2_cursor(
                        "legacy-user",
                        "legacy-node",
                        1,
                    )
                )
                self.assertEqual(
                    "ok",
                    relay.db.execute("PRAGMA integrity_check").fetchone()[0],
                )
                relay.save_android_push_token(
                    "tester",
                    "android-node",
                    "first-token",
                )
                relay.save_android_push_token(
                    "tester",
                    "android-node",
                    "refreshed-token",
                )
                self.assertEqual(
                    ["refreshed-token"],
                    relay.android_push_tokens_for_node("android-node"),
                )
                relay.delete_android_push_token(token="refreshed-token")
                self.assertEqual(
                    [],
                    relay.android_push_tokens_for_node("android-node"),
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
    def __init__(
        self,
        uri,
        login,
        password,
        node_id,
        display_name=None,
        supports_sync_v2=False,
        supports_sync_v2_delta=False,
        sync_cursor=0,
        supports_offline_ack=False,
        supports_mutation_ack=False,
        supports_file_transfer_v2=False,
        supports_account_live_fanout=False,
    ):
        self.uri = uri
        self.login = login
        self.password = password
        self.node_id = node_id
        self.display_name = display_name or login.title()
        self.websocket = None
        self.welcome = None
        self.sync = None
        self.sync_done = None
        self.pending = []
        self.supports_sync_v2 = supports_sync_v2
        self.supports_sync_v2_delta = supports_sync_v2_delta
        self.sync_cursor = sync_cursor
        self.delta_events = []
        self.supports_offline_ack = supports_offline_ack
        self.supports_mutation_ack = supports_mutation_ack
        self.supports_file_transfer_v2 = supports_file_transfer_v2
        self.supports_account_live_fanout = supports_account_live_fanout

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
                "supports_sticker_library_chunks": True,
                "supports_sync_v2": self.supports_sync_v2,
                "supports_sync_v2_delta": self.supports_sync_v2_delta,
                "sync_cursor": self.sync_cursor,
                "supports_offline_packet_ack": self.supports_offline_ack,
                "supports_mutation_ack": self.supports_mutation_ack,
                "supports_file_transfer_v2": self.supports_file_transfer_v2,
                "supports_account_live_fanout": (
                    self.supports_account_live_fanout
                ),
            }
        )
        self.welcome = await self.receive_type("server_welcome")
        self.sync = await self.receive()
        if self.sync.get("type") == "server_sync_delta_begin":
            while True:
                packet = await self.receive()
                if packet.get("type") == "server_sync_delta_event":
                    self.delta_events.append(packet)
                if packet.get("type") == "server_sync_done":
                    self.sync_done = packet
                    break
            return self.sync
        if self.sync.get("type") != "server_sync":
            raise AssertionError(
                f"Unexpected first sync packet: {self.sync.get('type')!r}"
            )
        self.sync["file_chunks"] = []
        sticker_chunks = {}
        sticker_chunk_total = 0
        while True:
            packet = await self.receive()
            if packet.get("type") == "server_file_sync_chunk":
                self.sync["file_chunks"].append(packet)
            if packet.get("type") == "server_sticker_library_sync_chunk":
                sticker_chunk_total = packet["total_chunks"]
                sticker_chunks[packet["chunk_index"]] = packet["data"]
            if packet.get("type") == "server_sync_done":
                self.sync_done = packet
                break
        if sticker_chunks:
            if (
                sticker_chunk_total <= 0
                or set(sticker_chunks) != set(range(sticker_chunk_total))
            ):
                raise AssertionError(
                    "Sticker library sync chunks are incomplete"
                )
            self.sync["sticker_library"] = json.loads(
                "".join(
                    sticker_chunks[index]
                    for index in range(sticker_chunk_total)
                )
            )
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


class CapturingWebSocket:
    def __init__(self):
        self.sent = []

    async def send(self, raw):
        self.sent.append(json.loads(raw))


class ServerSyncIntegrationTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        server_storage.DB_PATH = Path(self.temp_dir.name) / "server.db"
        server_auth.PASSWORD_ITERATIONS = 1_000
        server_module.SERVER_TOKEN = "integration-test-token"
        server_module.REQUIRE_LOGIN = True
        self.previous_sync_v2_delta_enabled = (
            server_module.SYNC_V2_DELTA_ENABLED
        )
        self.previous_sync_v2_delta_test_accounts = (
            server_module.SYNC_V2_DELTA_TEST_ACCOUNTS
        )
        server_module.SYNC_V2_DELTA_ENABLED = True
        server_module.SYNC_V2_DELTA_TEST_ACCOUNTS = frozenset()
        self.relay = server_module.MeshRelayServer()
        self.relay.wireguard_config_for = lambda login, device_id: (
            "[Interface]\n"
            "PrivateKey = integration-test\n"
            f"# {login}/{device_id}\n"
        )
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
        server_module.SYNC_V2_DELTA_ENABLED = (
            self.previous_sync_v2_delta_enabled
        )
        server_module.SYNC_V2_DELTA_TEST_ACCOUNTS = (
            self.previous_sync_v2_delta_test_accounts
        )
        self.temp_dir.cleanup()

    async def connect(
        self,
        login,
        node_id=None,
        password="test-password",
        supports_sync_v2=False,
        supports_sync_v2_delta=False,
        sync_cursor=0,
        supports_offline_ack=False,
        supports_mutation_ack=False,
        supports_file_transfer_v2=False,
        supports_account_live_fanout=False,
    ):
        client = TestClient(
            self.uri,
            login,
            password,
            node_id or str(uuid.uuid4()),
            supports_sync_v2=supports_sync_v2,
            supports_sync_v2_delta=supports_sync_v2_delta,
            sync_cursor=sync_cursor,
            supports_offline_ack=supports_offline_ack,
            supports_mutation_ack=supports_mutation_ack,
            supports_file_transfer_v2=supports_file_transfer_v2,
            supports_account_live_fanout=supports_account_live_fanout,
        )
        self.clients.append(client)
        await client.connect()
        return client

    async def restart_server(self):
        for client in reversed(self.clients):
            await client.close()
        self.clients.clear()
        self.server.close()
        await self.server.wait_closed()
        self.relay.db.close()
        self.relay = server_module.MeshRelayServer()
        self.relay.wireguard_config_for = lambda login, device_id: (
            "[Interface]\n"
            "PrivateKey = integration-test\n"
            f"# {login}/{device_id}\n"
        )
        self.server = await websockets.serve(
            self.relay.handler,
            "127.0.0.1",
            0,
            max_size=server_module.WEBSOCKET_MAX_SIZE,
        )
        port = self.server.sockets[0].getsockname()[1]
        self.uri = f"ws://127.0.0.1:{port}"

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

    async def test_file_transfer_v2_resumes_after_restart_and_syncs_from_disk(self):
        sender_node = str(uuid.uuid4())
        receiver_node = str(uuid.uuid4())
        sender = await self.connect(
            "file_v2_sender",
            node_id=sender_node,
            supports_file_transfer_v2=True,
        )
        receiver = await self.connect(
            "file_v2_receiver",
            node_id=receiver_node,
            supports_file_transfer_v2=True,
        )
        self.assertTrue(sender.welcome["capabilities"]["file_transfer_v2"])

        chunk_size = 64 * 1024
        payload = bytes((index * 17) % 251 for index in range(150_000))
        digest = hashlib.sha256(payload).hexdigest()
        total_chunks = (len(payload) + chunk_size - 1) // chunk_size
        transfer_id = "transfer-v2-restart"
        file_id = "file-v2-restart"
        operation_id = f"file_transfer:{file_id}"

        async def send_chunk(client, chunk_index, data=None):
            chunk = (
                payload[
                    chunk_index * chunk_size:
                    (chunk_index + 1) * chunk_size
                ]
                if data is None
                else data
            )
            await client.send(
                {
                    "type": "file_chunk",
                    "packet_id": f"{transfer_id}:{chunk_index}",
                    "protocol_version": 5,
                    "source_node": sender_node,
                    "destination_node": receiver_node,
                    "sender": "File sender",
                    "transfer_id": transfer_id,
                    "operation_id": operation_id,
                    "file_transfer_v2": True,
                    "file_id": file_id,
                    "filename": "durable.bin",
                    "caption": "durable transfer",
                    "file_sha256": digest,
                    "file_size": len(payload),
                    "chunk_size_bytes": chunk_size,
                    "chunk_index": chunk_index,
                    "total_chunks": total_chunks,
                    "data": chunk.hex(),
                    "ttl": 5,
                }
            )
            return await client.receive_type("file_chunk_ack")

        first_ack = await send_chunk(sender, 0)
        self.assertTrue(first_ack["ok"])
        self.assertEqual([[0, 0]], first_ack["received_ranges"])
        third_ack = await send_chunk(sender, 2)
        self.assertEqual([[0, 0], [2, 2]], third_ack["received_ranges"])
        self.assertFalse(third_ack["complete"])

        await self.restart_server()
        receiver = await self.connect(
            "file_v2_receiver",
            node_id=receiver_node,
            supports_file_transfer_v2=True,
        )
        sender = await self.connect(
            "file_v2_sender",
            node_id=sender_node,
            supports_file_transfer_v2=True,
        )
        final_ack = await send_chunk(sender, 1)
        self.assertTrue(final_ack["ok"])
        self.assertTrue(final_ack["complete"])
        self.assertEqual([[0, 2]], final_ack["received_ranges"])

        delivered = [
            await receiver.receive_type("file_chunk")
            for _ in range(total_chunks)
        ]
        delivered.sort(key=lambda item: item["chunk_index"])
        self.assertEqual(
            payload,
            bytes.fromhex("".join(item["data"] for item in delivered)),
        )
        self.assertTrue(all(item["file_sha256"] == digest for item in delivered))

        duplicate_ack = await send_chunk(sender, 1)
        self.assertTrue(duplicate_ack["complete"])
        with self.assertRaises((TimeoutError, asyncio.TimeoutError)):
            await receiver.receive_type("file_chunk", timeout=0.15)

        stored = self.relay.db.execute(
            """
            SELECT data, storage_path, sha256, size_bytes
            FROM server_files
            WHERE file_id=?
            """,
            (file_id,),
        ).fetchone()
        self.assertEqual("", stored[0])
        self.assertTrue(Path(stored[1]).is_file())
        self.assertEqual(digest, stored[2])
        self.assertEqual(len(payload), stored[3])

        await receiver.close()
        receiver_tablet = await self.connect(
            "file_v2_receiver",
            supports_file_transfer_v2=True,
        )
        synced = [
            item
            for item in receiver_tablet.sync["file_chunks"]
            if item["file_id"] == file_id
        ]
        synced.sort(key=lambda item: item["chunk_index"])
        self.assertEqual(
            payload,
            bytes.fromhex("".join(item["data"] for item in synced)),
        )
        self.assertTrue(all(item["file_sha256"] == digest for item in synced))

        storage_path = Path(stored[1])
        deleted = self.relay._delete_server_files(
            "file_id=?",
            (file_id,),
        )
        self.relay.db.commit()
        self.assertEqual(1, deleted)
        self.assertFalse(storage_path.exists())
        self.assertEqual(
            0,
            self.relay.db.execute(
                "SELECT COUNT(*) FROM file_transfer_sessions WHERE file_id=?",
                (file_id,),
            ).fetchone()[0],
        )

    async def test_file_transfer_v2_checksum_reset_and_cancel(self):
        sender = await self.connect(
            "file_v2_checksum_sender",
            supports_file_transfer_v2=True,
        )
        receiver = await self.connect(
            "file_v2_checksum_receiver",
            supports_file_transfer_v2=True,
        )
        good_payload = b"verified-file-payload"
        bad_payload = b"corrupted-file-bytes!"
        self.assertEqual(len(good_payload), len(bad_payload))
        digest = hashlib.sha256(good_payload).hexdigest()
        transfer_id = "transfer-v2-checksum"
        packet = {
            "type": "file_chunk",
            "packet_id": f"{transfer_id}:0",
            "protocol_version": 5,
            "source_node": sender.node_id,
            "destination_node": receiver.node_id,
            "sender": sender.login,
            "transfer_id": transfer_id,
            "operation_id": "file_transfer:file-v2-checksum",
            "file_transfer_v2": True,
            "file_id": "file-v2-checksum",
            "filename": "checksum.bin",
            "file_sha256": digest,
            "file_size": len(good_payload),
            "chunk_size_bytes": 64 * 1024,
            "chunk_index": 0,
            "total_chunks": 1,
            "data": bad_payload.hex(),
            "ttl": 5,
        }
        await sender.send(packet)
        reset_ack = await sender.receive_type("file_chunk_ack")
        self.assertFalse(reset_ack["ok"])
        self.assertTrue(reset_ack["retryable"])
        self.assertTrue(reset_ack["reset"])
        self.assertEqual(
            0,
            self.relay.db.execute(
                "SELECT COUNT(*) FROM file_transfer_chunks"
            ).fetchone()[0],
        )

        await sender.send({**packet, "data": good_payload.hex()})
        complete_ack = await sender.receive_type("file_chunk_ack")
        self.assertTrue(complete_ack["ok"])
        self.assertTrue(complete_ack["complete"])
        delivered = await receiver.receive_type("file_chunk")
        self.assertEqual(good_payload, bytes.fromhex(delivered["data"]))

        cancel_id = "transfer-v2-cancel"
        cancel_payload = b"a" * (70 * 1024)
        cancel_packet = {
            **packet,
            "packet_id": f"{cancel_id}:0",
            "transfer_id": cancel_id,
            "operation_id": "file_transfer:file-v2-cancel",
            "file_id": "file-v2-cancel",
            "filename": "cancel.bin",
            "file_sha256": hashlib.sha256(cancel_payload).hexdigest(),
            "file_size": len(cancel_payload),
            "total_chunks": 2,
            "data": cancel_payload[:64 * 1024].hex(),
        }
        await sender.send(cancel_packet)
        partial_ack = await sender.receive_type("file_chunk_ack")
        self.assertFalse(partial_ack["complete"])
        await sender.send(
            {
                "type": "file_transfer_cancel",
                "protocol_version": 5,
                "source_node": sender.node_id,
                "destination_node": "SERVER",
                "transfer_id": cancel_id,
                "operation_id": "file_transfer:file-v2-cancel",
                "file_id": "file-v2-cancel",
            }
        )
        cancelled = await sender.receive_type("file_chunk_ack")
        self.assertTrue(cancelled["cancelled"])
        self.assertEqual(
            0,
            self.relay.db.execute(
                """
                SELECT COUNT(*)
                FROM file_transfer_sessions
                WHERE transfer_id=?
                """,
                (cancel_id,),
            ).fetchone()[0],
        )

    async def test_mutation_ack_is_durable_and_duplicate_is_not_rerouted(self):
        sender = await self.connect(
            "outbox_sender",
            supports_mutation_ack=True,
        )
        receiver = await self.connect("outbox_receiver")
        self.assertTrue(sender.welcome["capabilities"]["mutation_ack"])

        packet_id = str(uuid.uuid4())
        operation_id = f"chat_message:{packet_id}"
        outbox_id = f"{operation_id}|{receiver.node_id}|"
        packet = {
            "type": "chat_message",
            "packet_id": packet_id,
            "operation_id": operation_id,
            "outbox_id": outbox_id,
            "protocol_version": 5,
            "source_node": sender.node_id,
            "destination_node": receiver.node_id,
            "sender": sender.login,
            "message": "encrypted-payload",
            "ttl": 5,
        }

        await sender.send(packet)
        ack = await sender.receive_type("mutation_ack")
        delivered = await receiver.receive_type("chat_message")
        self.assertTrue(ack["ok"])
        self.assertFalse(ack["duplicate"])
        self.assertEqual(outbox_id, ack["outbox_id"])
        self.assertEqual(packet_id, delivered["packet_id"])
        self.assertEqual(
            1,
            self.relay.db.execute(
                "SELECT COUNT(*) FROM direct_messages WHERE message_id=?",
                (packet_id,),
            ).fetchone()[0],
        )
        self.assertEqual(
            1,
            self.relay.db.execute(
                """
                SELECT COUNT(*)
                FROM processed_mutations
                WHERE account_login=? AND outbox_id=?
                """,
                (sender.login, outbox_id),
            ).fetchone()[0],
        )
        self.assertEqual(
            1,
            self.relay.db.execute(
                """
                SELECT COUNT(*)
                FROM sync_events
                WHERE account_login=? AND operation_id=?
                """,
                (sender.login, operation_id),
            ).fetchone()[0],
        )

        await sender.send(packet)
        duplicate_ack = await sender.receive_type("mutation_ack")
        self.assertTrue(duplicate_ack["ok"])
        self.assertTrue(duplicate_ack["duplicate"])
        with self.assertRaises((TimeoutError, asyncio.TimeoutError)):
            await receiver.receive_type("chat_message", timeout=0.25)

    async def test_same_account_devices_do_not_stack_identical_reaction(self):
        alice_phone = await self.connect(
            "reaction_alice",
            node_id="reaction-alice-phone",
            supports_mutation_ack=True,
        )
        alice_desktop = await self.connect(
            "reaction_alice",
            node_id="reaction-alice-desktop",
            supports_mutation_ack=True,
        )
        bob = await self.connect(
            "reaction_bob",
            node_id="reaction-bob-phone",
        )

        await self.send_and_receive(
            alice_phone,
            bob,
            "chat_message",
            packet_id="shared-message",
            message="encrypted reaction target",
        )

        async def send_reaction(client, suffix):
            packet_id = f"reaction-{suffix}"
            operation_id = f"message_reaction:{packet_id}"
            outbox_id = f"{operation_id}|{bob.node_id}|"
            await client.send(
                {
                    "type": "message_reaction",
                    "packet_id": packet_id,
                    "operation_id": operation_id,
                    "outbox_id": outbox_id,
                    "protocol_version": 5,
                    "source_node": client.node_id,
                    "destination_node": bob.node_id,
                    "message_id": "shared-message",
                    "reaction": "heart",
                    "ttl": 5,
                }
            )
            return await client.receive_type("mutation_ack")

        first_ack = await send_reaction(alice_phone, "phone")
        delivered = await bob.receive_type("message_reaction")
        self.assertTrue(first_ack["ok"])
        self.assertFalse(first_ack["duplicate"])
        self.assertEqual("heart", delivered["reaction"])

        duplicate_ack = await send_reaction(alice_desktop, "desktop")
        self.assertTrue(duplicate_ack["ok"])
        self.assertTrue(duplicate_ack["duplicate"])
        with self.assertRaises((TimeoutError, asyncio.TimeoutError)):
            await bob.receive_type("message_reaction", timeout=0.25)

        rows = self.relay.db.execute(
            """
            SELECT reactor_login, reactor_identity, reaction
            FROM server_reactions
            WHERE scope='direct' AND message_id='shared-message'
            """
        ).fetchall()
        self.assertEqual(
            [("reaction_alice", "login:reaction_alice", "heart")],
            rows,
        )

        await bob.close()
        bob_desktop = await self.connect(
            "reaction_bob",
            node_id="reaction-bob-desktop",
        )
        restored_reactions = [
            reaction
            for reaction in bob_desktop.sync["reactions"]
            if reaction["message_id"] == "shared-message"
            and reaction["reaction"] == "heart"
        ]
        self.assertEqual(1, len(restored_reactions))
        self.assertEqual(
            "reaction_alice",
            restored_reactions[0]["reactor_login"],
        )
        self.assertEqual(
            "login:reaction_alice",
            restored_reactions[0]["reactor_identity"],
        )

    async def test_unauthorized_group_mutation_gets_permanent_negative_ack(self):
        owner = await self.connect("outbox_group_owner")
        member = await self.connect(
            "outbox_group_member",
            supports_mutation_ack=True,
        )
        group_id = "outbox-protected-group"

        await self.send_and_receive(
            owner,
            member,
            "group_update",
            group_id=group_id,
            group_name="Protected group",
            members=[owner.node_id, member.node_id],
            owner_node=owner.node_id,
            admins=[],
            is_channel=False,
            comments_enabled=True,
        )

        packet_id = str(uuid.uuid4())
        operation_id = f"group_delete:{packet_id}"
        await member.send(
            {
                "type": "group_delete",
                "packet_id": packet_id,
                "operation_id": operation_id,
                "outbox_id": f"{operation_id}|SERVER|",
                "protocol_version": 5,
                "source_node": member.node_id,
                "destination_node": "SERVER",
                "group_id": group_id,
                "ttl": 5,
            }
        )

        ack = await member.receive_type("mutation_ack")
        self.assertFalse(ack["ok"])
        self.assertEqual(
            "unauthorized_group_management",
            ack["reason"],
        )
        self.assertIsNotNone(
            self.relay.db.execute(
                "SELECT 1 FROM server_groups WHERE group_id=?",
                (group_id,),
            ).fetchone()
        )

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

    async def test_offline_packet_is_retained_until_new_client_acknowledges(self):
        alice = await self.connect("ack_alice")
        bob = await self.connect("ack_bob")
        bob_node = bob.node_id
        await bob.close()
        await asyncio.sleep(0.05)

        await alice.send(
            {
                "type": "chat_request",
                "packet_id": "durable-chat-request",
                "protocol_version": 5,
                "source_node": alice.node_id,
                "destination_node": bob_node,
                "sender": alice.login,
                "ttl": 5,
            }
        )
        await asyncio.sleep(0.05)

        bob_reconnected = await self.connect(
            "ack_bob",
            node_id=bob_node,
            supports_offline_ack=True,
        )
        queued = await bob_reconnected.receive_type("chat_request")
        queue_id = queued.get("_offline_queue_id")
        self.assertIsInstance(queue_id, int)
        self.assertEqual(
            1,
            self.relay.db.execute(
                "SELECT COUNT(*) FROM offline_packets WHERE id=?",
                (queue_id,),
            ).fetchone()[0],
        )

        await bob_reconnected.close()
        bob_again = await self.connect(
            "ack_bob",
            node_id=bob_node,
            supports_offline_ack=True,
        )
        redelivered = await bob_again.receive_type("chat_request")
        self.assertEqual(queue_id, redelivered.get("_offline_queue_id"))

        await bob_again.send(
            {
                "type": "offline_packet_ack",
                "source_node": bob_node,
                "queue_id": queue_id,
                "protocol_version": 5,
            }
        )
        await asyncio.sleep(0.05)
        self.assertEqual(
            0,
            self.relay.db.execute(
                "SELECT COUNT(*) FROM offline_packets WHERE id=?",
                (queue_id,),
            ).fetchone()[0],
        )

    async def test_sync_v2_journal_cursor_and_duplicate_operation(self):
        alice = await self.connect("sync_v2_alice", supports_sync_v2=True)
        bob = await self.connect("sync_v2_bob", supports_sync_v2=True)
        packet = {
            "type": "chat_message",
            "packet_id": "sync-v2-message",
            "protocol_version": 5,
            "source_node": alice.node_id,
            "destination_node": bob.node_id,
            "sender": alice.login,
            "message": "encrypted sync payload",
            "ttl": 5,
        }

        await alice.send(packet)
        await bob.receive_type("chat_message")
        await alice.send(packet)
        await bob.receive_type("chat_message")
        await asyncio.sleep(0.05)

        rows = self.relay.db.execute(
            """
            SELECT account_login, operation_id, packet_type
            FROM sync_events
            WHERE operation_id='chat_message:sync-v2-message'
            ORDER BY account_login
            """
        ).fetchall()
        self.assertEqual(
            [
                (
                    "sync_v2_alice",
                    "chat_message:sync-v2-message",
                    "chat_message",
                ),
                (
                    "sync_v2_bob",
                    "chat_message:sync-v2-message",
                    "chat_message",
                ),
            ],
            rows,
        )

        await alice.close()
        alice_reconnected = await self.connect(
            "sync_v2_alice",
            supports_sync_v2=True,
        )
        cursor = alice_reconnected.sync_done.get("sync_cursor")
        self.assertIsInstance(cursor, int)
        self.assertGreater(cursor, 0)
        self.assertEqual(
            cursor,
            alice_reconnected.sync["sync_v2"]["cursor"],
        )

        await alice_reconnected.send(
            {
                "type": "sync_v2_ack",
                "source_node": alice_reconnected.node_id,
                "cursor": cursor,
                "protocol_version": 5,
            }
        )
        await asyncio.sleep(0.05)
        stored_cursor = self.relay.db.execute(
            """
            SELECT cursor
            FROM sync_cursors
            WHERE account_login=? AND node_id=?
            """,
            ("sync_v2_alice", alice_reconnected.node_id),
        ).fetchone()
        self.assertEqual((cursor,), stored_cursor)

    async def test_live_mutations_fan_out_to_every_online_account_device(self):
        alice_phone = await self.connect(
            "live_alice",
            node_id="live-alice-phone",
            supports_sync_v2=True,
            supports_account_live_fanout=True,
        )
        alice_desktop = await self.connect(
            "live_alice",
            node_id="live-alice-desktop",
            supports_sync_v2=True,
            supports_account_live_fanout=True,
        )
        alice_legacy = await self.connect(
            "live_alice",
            node_id="live-alice-legacy",
            supports_sync_v2=True,
        )
        bob_phone = await self.connect(
            "live_bob",
            node_id="live-bob-phone",
            supports_sync_v2=True,
            supports_account_live_fanout=True,
        )
        bob_desktop = await self.connect(
            "live_bob",
            node_id="live-bob-desktop",
            supports_sync_v2=True,
            supports_account_live_fanout=True,
        )

        message = {
            "type": "chat_message",
            "packet_id": "live-message-1",
            "protocol_version": 5,
            "source_node": alice_phone.node_id,
            "destination_node": bob_phone.node_id,
            "sender": alice_phone.login,
            "message": "encrypted-live-message",
            "ttl": 5,
        }
        await alice_phone.send(message)

        bob_phone_message = await bob_phone.receive_type("chat_message")
        bob_desktop_message = await bob_desktop.receive_type("chat_message")
        alice_mirror_message = await alice_desktop.receive_type("chat_message")
        self.assertEqual("live_alice", bob_phone_message["sender_login"])
        self.assertEqual("live_bob", bob_desktop_message["receiver_login"])
        self.assertEqual(True, alice_mirror_message["account_mirror"])
        self.assertEqual(
            bob_phone.node_id,
            alice_mirror_message["destination_node"],
        )
        with self.assertRaises(TimeoutError):
            await alice_legacy.receive_type("chat_message", timeout=0.15)

        read_receipt = {
            "type": "message_read",
            "packet_id": "live-read-1",
            "protocol_version": 5,
            "source_node": bob_phone.node_id,
            "destination_node": alice_phone.node_id,
            "message_ids": ["live-message-1"],
            "ttl": 5,
        }
        await bob_phone.send(read_receipt)

        alice_read = await alice_phone.receive_type("message_read")
        bob_mirror_read = await bob_desktop.receive_type("message_read")
        self.assertEqual(["live-message-1"], alice_read["message_ids"])
        self.assertEqual(True, bob_mirror_read["account_mirror"])

        reaction = {
            "type": "message_reaction",
            "packet_id": "live-reaction-1",
            "operation_id": "message_reaction:live-reaction-1",
            "protocol_version": 5,
            "source_node": bob_phone.node_id,
            "destination_node": alice_phone.node_id,
            "message_id": "live-message-1",
            "reaction": "heart",
            "ttl": 5,
        }
        await bob_phone.send(reaction)

        await alice_phone.receive_type("message_reaction")
        await alice_desktop.receive_type("message_reaction")
        bob_mirror_reaction = await bob_desktop.receive_type(
            "message_reaction"
        )
        self.assertEqual("live_bob", bob_mirror_reaction["reactor_login"])

        deletion = {
            "type": "message_delete",
            "packet_id": "live-delete-1",
            "operation_id": "message_delete:live-message-1",
            "protocol_version": 5,
            "source_node": alice_phone.node_id,
            "destination_node": bob_phone.node_id,
            "message_id": "live-message-1",
            "ttl": 5,
        }
        await alice_phone.send(deletion)

        await bob_phone.receive_type("message_delete")
        await bob_desktop.receive_type("message_delete")
        alice_mirror_delete = await alice_desktop.receive_type(
            "message_delete"
        )
        self.assertEqual(True, alice_mirror_delete["account_mirror"])

    async def test_sync_v2_delta_is_negotiated_and_streamed_over_websocket(self):
        initial = await self.connect(
            "sync_delta_alice",
            node_id="sync-delta-phone",
            supports_sync_v2=True,
        )
        await initial.close()

        source_cursor = self.relay.record_sync_v2_event(
            {
                "type": "chat_message",
                "packet_id": "delta-message-a",
                "operation_id": "chat_message:delta-message-a",
                "source_node": "sync-delta-phone",
                "destination_node": "peer-phone",
                "message": "ciphertext-a",
            },
            ["sync_delta_alice"],
        )["sync_delta_alice"]
        target_cursor = self.relay.record_sync_v2_event(
            {
                "type": "message_delete",
                "packet_id": "delta-delete-b",
                "operation_id": "message_delete:delta-message-b",
                "source_node": "sync-delta-phone",
                "destination_node": "peer-phone",
                "message_id": "delta-message-b",
            },
            ["sync_delta_alice"],
        )["sync_delta_alice"]

        delta_client = await self.connect(
            "sync_delta_alice",
            node_id="sync-delta-desktop",
            supports_sync_v2=True,
            supports_sync_v2_delta=True,
            sync_cursor=source_cursor,
        )

        self.assertTrue(
            delta_client.welcome["capabilities"]["sync_v2_delta"]
        )
        self.assertEqual("server_sync_delta_begin", delta_client.sync["type"])
        self.assertEqual(source_cursor, delta_client.sync["source_cursor"])
        self.assertEqual(target_cursor, delta_client.sync["target_cursor"])
        self.assertEqual(1, delta_client.sync["event_count"])
        self.assertEqual(1, len(delta_client.delta_events))
        event_digest = server_sync.sync_v2_delta_digest(
            [packet["event"] for packet in delta_client.delta_events]
        )
        self.assertEqual(
            event_digest,
            delta_client.sync["event_digest_sha256"],
        )
        self.assertEqual(
            "message_delete:delta-message-b",
            delta_client.delta_events[0]["event"]["operation_id"],
        )
        self.assertEqual(target_cursor, delta_client.sync_done["sync_cursor"])
        self.assertEqual("delta", delta_client.sync_done["sync_v2"]["mode"])
        self.assertEqual(
            event_digest,
            delta_client.sync_done["sync_v2"]["event_digest_sha256"],
        )

    async def test_sync_v2_delta_canary_is_negotiated_per_account(self):
        server_module.SYNC_V2_DELTA_ENABLED = False
        server_module.SYNC_V2_DELTA_TEST_ACCOUNTS = frozenset(
            {"sync_canary"}
        )

        canary = await self.connect(
            "sync_canary",
            node_id="sync-canary-phone",
            supports_sync_v2=True,
            supports_sync_v2_delta=True,
        )
        ordinary = await self.connect(
            "sync_ordinary",
            node_id="sync-ordinary-phone",
            supports_sync_v2=True,
            supports_sync_v2_delta=True,
        )

        self.assertTrue(canary.welcome["capabilities"]["sync_v2_delta"])
        self.assertFalse(ordinary.welcome["capabilities"]["sync_v2_delta"])
        self.assertEqual("snapshot", canary.sync["sync_v2"]["mode"])
        self.assertEqual("snapshot", ordinary.sync["sync_v2"]["mode"])

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

        await self.send_and_receive(
            alice_laptop,
            bob_laptop,
            "chat_message",
            packet_id="direct-message-after-delete",
            message="new encrypted payload",
        )
        await alice_laptop.close()
        await bob_laptop.close()
        alice_reopened = await self.connect("alice")
        bob_reopened = await self.connect("bob")
        for client in (alice_reopened, bob_reopened):
            self.assertEqual(
                ["direct-message-after-delete"],
                [
                    item["message_id"]
                    for item in client.sync["direct_messages"]
                ],
            )

    async def test_self_alias_chat_delete_never_hides_account_history(self):
        alice_phone = await self.connect("self_delete_alice")
        alice_desktop = await self.connect("self_delete_alice")
        bob_phone = await self.connect("self_delete_bob")

        await self.send_and_receive(
            alice_phone,
            bob_phone,
            "chat_message",
            packet_id="self-delete-history-message",
            message="encrypted payload",
        )
        await self.send_and_receive(
            alice_phone,
            alice_desktop,
            "chat_delete",
            chat_node_id=alice_desktop.node_id,
            chat_kind="normal",
            chat_id="",
        )

        self.assertEqual(
            0,
            self.relay.db.execute(
                """
                SELECT COUNT(*)
                FROM server_chat_deletes
                WHERE owner_login='self_delete_alice'
                  AND peer_login='self_delete_alice'
                """
            ).fetchone()[0],
        )
        await alice_phone.close()
        await alice_desktop.close()
        alice_laptop = await self.connect("self_delete_alice")
        self.assertIn(
            "self-delete-history-message",
            {
                item["message_id"]
                for item in alice_laptop.sync["direct_messages"]
            },
        )

    async def test_offline_direct_message_and_file_sync_to_new_device(self):
        alice = await self.connect("offline_file_alice")
        bob_phone = await self.connect("offline_file_bob")
        bob_node = bob_phone.node_id
        await bob_phone.close()
        await asyncio.sleep(0.05)

        await alice.send(
            {
                "type": "chat_message",
                "packet_id": "offline-direct-message",
                "protocol_version": 5,
                "source_node": alice.node_id,
                "destination_node": bob_node,
                "sender": alice.login,
                "message": "encrypted offline text",
                "message_effect": "orbit",
                "ttl": 5,
            }
        )
        await alice.send(
            {
                "type": "file_chunk",
                "packet_id": "offline-image-packet",
                "protocol_version": 5,
                "source_node": alice.node_id,
                "destination_node": bob_node,
                "sender": alice.login,
                "file_id": "offline-image-file",
                "filename": "encrypted-image-name",
                "caption": "encrypted-image-caption",
                "message_kind": "image",
                "message_effect": "frost",
                "chunk_index": 0,
                "total_chunks": 1,
                "data": "0102030405",
                "ttl": 5,
            }
        )
        await asyncio.sleep(0.1)

        self.assertEqual(
            0,
            self.relay.db.execute(
                "SELECT COUNT(*) FROM offline_packets"
            ).fetchone()[0],
        )

        bob_tablet = await self.connect("offline_file_bob")
        self.assertIn(
            "offline-direct-message",
            {
                item["message_id"]
                for item in bob_tablet.sync["direct_messages"]
            },
        )
        direct_message = next(
            item
            for item in bob_tablet.sync["direct_messages"]
            if item["message_id"] == "offline-direct-message"
        )
        self.assertEqual("orbit", direct_message["message_effect"])
        image_chunk = next(
            item
            for item in bob_tablet.sync["file_chunks"]
            if item["file_id"] == "offline-image-file"
        )
        self.assertEqual("image", image_chunk["message_kind"])
        self.assertEqual("0102030405", image_chunk["data"])
        self.assertEqual("frost", image_chunk["message_effect"])

        await self.send_and_receive(
            alice,
            bob_tablet,
            "message_delete",
            message_id="offline-image-file",
        )
        await bob_tablet.close()
        bob_desktop = await self.connect("offline_file_bob")
        self.assertNotIn(
            "offline-image-file",
            {item["file_id"] for item in bob_desktop.sync["files"]},
        )

    async def test_secret_text_photo_and_file_restore_then_stay_deleted(self):
        alice_phone = await self.connect("secret_alice")
        bob_phone = await self.connect("secret_bob")
        secret_id = "secret:stable-integration-thread"

        await self.send_and_receive(
            alice_phone,
            bob_phone,
            "chat_message",
            packet_id="normal-message-kept",
            message="encrypted normal message",
            chat_kind="normal",
            chat_id="",
        )
        await self.send_and_receive(
            alice_phone,
            bob_phone,
            "chat_message",
            packet_id="secret-text",
            message="encrypted secret text",
            reply_to_message_id="",
            reply_to_text="",
            chat_kind="secret",
            chat_id=secret_id,
        )

        for index, data in enumerate(("001122", "334455")):
            await self.send_and_receive(
                alice_phone,
                bob_phone,
                "file_chunk",
                packet_id=f"secret-photo-packet-{index}",
                file_id="secret-photo",
                filename="encrypted-photo-name",
                caption="encrypted-photo-caption",
                message_kind="image",
                chunk_index=index,
                total_chunks=2,
                data=data,
                chat_kind="secret",
                chat_id=secret_id,
            )

        await self.send_and_receive(
            bob_phone,
            alice_phone,
            "file_chunk",
            packet_id="secret-file-packet",
            file_id="secret-file",
            filename="encrypted-document-name",
            caption="encrypted-document-caption",
            message_kind="file",
            chunk_index=0,
            total_chunks=1,
            data="aabbccdd",
            chat_kind="secret",
            chat_id=secret_id,
        )
        await asyncio.sleep(0.05)

        alice_old_node = alice_phone.node_id
        bob_old_node = bob_phone.node_id
        await alice_phone.close()
        await bob_phone.close()

        bob_tablet = await self.connect("secret_bob")
        alice_desktop = await self.connect("secret_alice")

        for client, own_old_node in (
            (alice_desktop, alice_old_node),
            (bob_tablet, bob_old_node),
        ):
            self.assertEqual(client.node_id, client.sync["profile"]["node_id"])
            self.assertIn(
                own_old_node,
                client.sync["profile"]["node_aliases"],
            )
            secret_message = next(
                item
                for item in client.sync["direct_messages"]
                if item["message_id"] == "secret-text"
            )
            self.assertEqual("secret", secret_message["chat_kind"])
            self.assertEqual(secret_id, secret_message["chat_id"])
            self.assertIn(
                "normal-message-kept",
                {
                    item["message_id"]
                    for item in client.sync["direct_messages"]
                },
            )

            secret_files = {
                item["file_id"]: item
                for item in client.sync["files"]
                if item["chat_id"] == secret_id
            }
            self.assertEqual(
                {"secret-photo", "secret-file"},
                set(secret_files),
            )
            self.assertEqual("secret", secret_files["secret-photo"]["chat_kind"])
            self.assertEqual("image", secret_files["secret-photo"]["message_kind"])
            self.assertEqual(
                "encrypted-photo-caption",
                secret_files["secret-photo"]["caption"],
            )
            payloads = {
                item["file_id"]: item["data"]
                for item in client.sync["file_chunks"]
                if item["file_id"] in secret_files
            }
            self.assertEqual("001122334455", payloads["secret-photo"])
            self.assertEqual("aabbccdd", payloads["secret-file"])

        await self.send_and_receive(
            alice_desktop,
            bob_tablet,
            "chat_delete",
            chat_node_id=bob_tablet.node_id,
            chat_kind="secret",
            chat_id=secret_id,
        )
        await alice_desktop.close()
        await bob_tablet.close()

        alice_after_delete = await self.connect("secret_alice")
        bob_after_delete = await self.connect("secret_bob")
        for client in (alice_after_delete, bob_after_delete):
            self.assertNotIn(
                "secret-text",
                {
                    item["message_id"]
                    for item in client.sync["direct_messages"]
                },
            )
            self.assertNotIn(
                secret_id,
                {item["chat_id"] for item in client.sync["files"]},
            )
            self.assertIn(
                "normal-message-kept",
                {
                    item["message_id"]
                    for item in client.sync["direct_messages"]
                },
            )

    async def test_story_media_reactions_and_views_follow_account_devices(self):
        alice_phone = await self.connect("story_alice")
        bob_phone = await self.connect("story_bob")
        self.relay.grant_subscription("story_alice", days=7)
        self.relay.grant_subscription("story_bob", days=7)
        await alice_phone.send(
            {
                "type": "profile_update",
                "packet_id": "story-owner-profile-update",
                "protocol_version": 5,
                "source_node": alice_phone.node_id,
                "destination_node": "SERVER",
                "login": "story_alice",
                "display_name": "Persistent Alice",
                "public_username": "persistent_alice",
                "about": "Persistent profile description",
                "avatar_data": "persistent-avatar-payload",
                "encryption_public_key": f"public-key:{alice_phone.node_id}",
                "ttl": 5,
            }
        )
        profile_result = await alice_phone.receive_type("profile_update_result")
        self.assertTrue(profile_result["ok"])
        story_id = "story-media-1"
        story = {
            "id": story_id,
            "owner_node": alice_phone.node_id,
            "owner_name": "Story Alice",
            "created_at": "2099-01-01T00:00:00Z",
            "text": "persistent story",
            "image_data": "base64-image-payload",
            "video_data": "base64-video-payload",
            "video_mime": "video/mp4",
            "media_type": "video",
            "hd": True,
            "video_duration_seconds": 90,
            "liked_by_node_ids": [],
            "viewed_by_node_ids": [],
            "visibility": "selected",
            "allowed_node_ids": [bob_phone.node_id],
            "excluded_node_ids": [],
        }
        await self.send_and_receive(
            alice_phone,
            bob_phone,
            "story_update",
            story=story,
        )
        await self.send_and_receive(
            bob_phone,
            alice_phone,
            "story_reaction",
            story_id=story_id,
            reaction="fire",
            liked=True,
            replace_existing=True,
        )
        await self.send_and_receive(
            bob_phone,
            alice_phone,
            "story_view",
            story_id=story_id,
        )

        alice_old_node = alice_phone.node_id
        bob_old_node = bob_phone.node_id
        await alice_phone.close()
        await bob_phone.close()

        bob_tablet = await self.connect("story_bob")
        restored_for_bob = next(
            item for item in bob_tablet.sync["stories"] if item["id"] == story_id
        )
        self.assertEqual(alice_old_node, restored_for_bob["owner_node"])
        self.assertEqual("base64-image-payload", restored_for_bob["image_data"])
        self.assertEqual("base64-video-payload", restored_for_bob["video_data"])
        self.assertTrue(restored_for_bob["hd"])
        self.assertEqual(90, restored_for_bob["video_duration_seconds"])
        self.assertIn(
            bob_tablet.node_id,
            restored_for_bob["reactions"]["fire"],
        )
        self.assertEqual([], restored_for_bob["liked_by_node_ids"])
        self.assertIn(bob_tablet.node_id, restored_for_bob["viewed_by_node_ids"])
        self.assertNotIn(bob_old_node, restored_for_bob["liked_by_node_ids"])

        alice_desktop = await self.connect("story_alice")
        restored_for_alice = next(
            item
            for item in alice_desktop.sync["stories"]
            if item["id"] == story_id
        )
        self.assertEqual(alice_desktop.node_id, restored_for_alice["owner_node"])
        self.assertEqual(
            alice_desktop.node_id,
            alice_desktop.sync["profile"]["node_id"],
        )
        self.assertEqual(
            "Persistent Alice",
            alice_desktop.sync["profile"]["display_name"],
        )
        self.assertEqual(
            "Persistent profile description",
            alice_desktop.sync["profile"]["about"],
        )
        self.assertEqual(
            "persistent-avatar-payload",
            alice_desktop.sync["profile"]["avatar_data"],
        )
        self.assertIn(alice_old_node, alice_desktop.sync["profile"]["node_aliases"])
        archived = next(
            item
            for item in alice_desktop.sync["story_archive"]
            if item["id"] == story_id
        )
        self.assertTrue(archived["hd"])
        self.assertIn(
            bob_old_node,
            archived["reactions"]["fire"],
        )

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

    async def test_meshchat_welcome_and_refresh_expose_meshpro_status(self):
        client = await self.connect("meshpro_chat_user")
        self.assertIn("subscription", client.welcome)
        self.assertFalse(client.welcome["subscription"]["active"])
        self.assertFalse(
            client.welcome["subscription"]["entitlements"]["features"]
            ["meshprivacy_vpn"]
        )
        self.assertFalse(client.sync["profile"]["meshpro_badge"])

        await client.send(
            {
                "type": "meshpro_catalog_request",
                "packet_id": str(uuid.uuid4()),
                "protocol_version": 5,
                "source_node": client.node_id,
                "destination_node": "SERVER",
                "product": "meshpro",
                "ttl": 5,
            }
        )
        catalog_result = await client.receive_type("meshpro_catalog_result")
        self.assertTrue(catalog_result["ok"])
        self.assertEqual(1, catalog_result["catalog"]["schema_version"])
        self.assertIn(
            "ai_text_rewrite",
            catalog_result["catalog"]["features"],
        )

        self.relay.grant_subscription("meshpro_chat_user", days=14)
        await client.send(
            {
                "type": "subscription_status_request",
                "packet_id": str(uuid.uuid4()),
                "protocol_version": 5,
                "source_node": client.node_id,
                "destination_node": "SERVER",
                "product": "meshpro",
                "ttl": 5,
            }
        )
        refreshed = await client.receive_type("subscription_status_result")
        self.assertTrue(refreshed["ok"])
        self.assertTrue(refreshed["subscription"]["active"])
        self.assertEqual("meshpro", refreshed["subscription"]["product"])
        self.assertTrue(
            refreshed["subscription"]["entitlements"]["features"]
            ["meshprivacy_vpn"]
        )
        self.assertTrue(
            refreshed["subscription"]["entitlements"]["features"]
            ["premium_badge"]
        )
        self.assertTrue(
            refreshed["subscription"]["entitlements"]["features"]
            ["ai_text_rewrite"]
        )
        self.assertEqual(
            50,
            refreshed["subscription"]["entitlements"]["limits"]
            ["ai_text_rewrites_month"],
        )

        await client.close()
        relogin = await self.connect("meshpro_chat_user")
        self.assertTrue(relogin.sync["profile"]["meshpro_badge"])

    async def test_meshpro_profile_style_survives_relogin_and_is_gated(self):
        client = await self.connect("meshpro_style_user")
        await client.send(
            {
                "type": "profile_update",
                "packet_id": str(uuid.uuid4()),
                "protocol_version": 5,
                "source_node": client.node_id,
                "destination_node": "SERVER",
                "login": "meshpro_style_user",
                "display_name": "Styled user",
                "profile_background": "aurora",
                "ttl": 5,
            }
        )
        rejected = await client.receive_type("profile_update_result")
        self.assertFalse(rejected["ok"])
        self.assertEqual("meshpro_required", rejected["reason"])

        self.relay.grant_subscription("meshpro_style_user", days=14)
        await client.send(
            {
                "type": "profile_update",
                "packet_id": str(uuid.uuid4()),
                "protocol_version": 5,
                "source_node": client.node_id,
                "destination_node": "SERVER",
                "login": "meshpro_style_user",
                "display_name": "Styled user",
                "profile_background": "aurora",
                "profile_effect": "stars",
                "profile_blink_shape": "moose",
                "avatar_decoration": "stardust",
                "profile_glow": True,
                "profile_accent": 0xFF67F3C4,
                "ttl": 5,
            }
        )
        accepted = await client.receive_type("profile_update_result")
        self.assertTrue(accepted["ok"])

        await client.close()
        relogin = await self.connect("meshpro_style_user")
        self.assertEqual("aurora", relogin.sync["profile"]["profile_background"])
        self.assertEqual("stars", relogin.sync["profile"]["profile_effect"])
        self.assertEqual(
            "moose",
            relogin.sync["profile"]["profile_blink_shape"]
        )
        self.assertEqual(
            "stardust",
            relogin.sync["profile"]["avatar_decoration"]
        )
        self.assertTrue(relogin.sync["profile"]["profile_glow"])
        self.assertEqual(0xFF67F3C4, relogin.sync["profile"]["profile_accent"])

        self.relay.revoke_subscription("meshpro_style_user")
        await relogin.close()
        expired = await self.connect("meshpro_style_user")
        self.assertEqual("mesh", expired.sync["profile"]["profile_background"])
        self.assertEqual("nodes", expired.sync["profile"]["profile_effect"])
        self.assertEqual(
            "auto",
            expired.sync["profile"]["profile_blink_shape"]
        )
        self.assertEqual(
            "none",
            expired.sync["profile"]["avatar_decoration"]
        )
        self.assertFalse(expired.sync["profile"]["profile_glow"])
        self.assertEqual(0xFF42A5F5, expired.sync["profile"]["profile_accent"])

    async def test_direct_edit_and_delete_are_live_and_persistent(self):
        alice = await self.connect("mutation_alice")
        bob = await self.connect("mutation_bob")
        message_id = "direct-live-edit-delete"

        await self.send_and_receive(
            alice,
            bob,
            "chat_message",
            packet_id=message_id,
            message="encrypted original",
        )
        edited = await self.send_and_receive(
            alice,
            bob,
            "message_edit",
            message_id=message_id,
            message="encrypted edited",
        )
        self.assertEqual("encrypted edited", edited["message"])

        deleted = await self.send_and_receive(
            alice,
            bob,
            "message_delete",
            message_id=message_id,
        )
        self.assertEqual(message_id, deleted["message_id"])

        await alice.close()
        await bob.close()
        alice_relogin = await self.connect("mutation_alice")
        bob_relogin = await self.connect("mutation_bob")
        for client in (alice_relogin, bob_relogin):
            self.assertNotIn(
                message_id,
                {item["message_id"] for item in client.sync["direct_messages"]},
            )

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

    async def test_channel_delete_is_broadcast_and_absent_after_relogin(self):
        owner = await self.connect("delete_owner")
        member_a = await self.connect("delete_member_a")
        member_b = await self.connect("delete_member_b")
        group_id = "authoritative-group-delete"
        members = [owner.node_id, member_a.node_id, member_b.node_id]

        await self.send_and_receive(
            owner,
            member_a,
            "group_update",
            group_id=group_id,
            group_name="Delete everywhere",
            members=members,
            owner_node=owner.node_id,
            admins=[],
            is_channel=True,
            comments_enabled=True,
        )

        await member_a.send(
            {
                "type": "group_delete",
                "packet_id": str(uuid.uuid4()),
                "protocol_version": 5,
                "source_node": member_a.node_id,
                "destination_node": "SERVER",
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

        await owner.send(
            {
                "type": "group_delete",
                "packet_id": str(uuid.uuid4()),
                "protocol_version": 5,
                "source_node": owner.node_id,
                "destination_node": "SERVER",
                "group_id": group_id,
                "ttl": 5,
            }
        )
        for member in (member_a, member_b):
            event = await member.receive_type("group_delete")
            self.assertEqual(group_id, event["group_id"])

        self.assertIsNone(
            self.relay.db.execute(
                "SELECT 1 FROM server_groups WHERE group_id=?", (group_id,)
            ).fetchone()
        )

        await owner.close()
        await member_a.close()
        await member_b.close()
        for login in ("delete_owner", "delete_member_a", "delete_member_b"):
            relogin = await self.connect(login)
            self.assertNotIn(
                group_id,
                {item["group_id"] for item in relogin.sync["groups"]},
            )

    async def test_group_delete_is_broadcast_and_absent_after_relogin(self):
        owner = await self.connect("group_delete_owner")
        member_a = await self.connect("group_delete_member_a")
        member_b = await self.connect("group_delete_member_b")
        group_id = "authoritative-group-delete"
        members = [owner.node_id, member_a.node_id, member_b.node_id]

        await self.send_and_receive(
            owner,
            member_a,
            "group_update",
            group_id=group_id,
            group_name="Delete group everywhere",
            members=members,
            owner_node=owner.node_id,
            admins=[],
            is_channel=False,
        )

        await owner.send(
            {
                "type": "group_delete",
                "packet_id": str(uuid.uuid4()),
                "protocol_version": 5,
                "source_node": owner.node_id,
                "destination_node": "SERVER",
                "group_id": group_id,
                "ttl": 5,
            }
        )
        for member in (member_a, member_b):
            event = await member.receive_type("group_delete")
            self.assertEqual(group_id, event["group_id"])

        self.assertIsNone(
            self.relay.db.execute(
                "SELECT 1 FROM server_groups WHERE group_id=?", (group_id,)
            ).fetchone()
        )

        await owner.close()
        await member_a.close()
        await member_b.close()
        for login in (
            "group_delete_owner",
            "group_delete_member_a",
            "group_delete_member_b",
        ):
            relogin = await self.connect(login)
            self.assertNotIn(
                group_id,
                {item["group_id"] for item in relogin.sync["groups"]},
            )

    async def test_group_message_edit_and_delete_are_live_and_persistent(self):
        owner = await self.connect("group_mutation_owner")
        member = await self.connect("group_mutation_member")
        group_id = "group-message-mutation"
        message_id = "group-message-edit-delete"
        members = [owner.node_id, member.node_id]

        await self.send_and_receive(
            owner,
            member,
            "group_update",
            group_id=group_id,
            group_name="Mutation group",
            members=members,
            owner_node=owner.node_id,
            admins=[],
            is_channel=False,
        )
        await self.send_and_receive(
            owner,
            member,
            "group_message",
            packet_id=message_id,
            group_message_id=message_id,
            group_id=group_id,
            group_name="Mutation group",
            members=members,
            owner_node=owner.node_id,
            admins=[],
            message="encrypted original",
            group_key_id="key-1",
        )
        edited = await self.send_and_receive(
            owner,
            member,
            "group_message_edit",
            group_id=group_id,
            group_message_id=message_id,
            message="encrypted edited",
            group_key_id="key-1",
        )
        self.assertEqual("encrypted edited", edited["message"])
        deleted = await self.send_and_receive(
            owner,
            member,
            "group_message_delete",
            group_id=group_id,
            group_message_id=message_id,
        )
        self.assertEqual(message_id, deleted["group_message_id"])

        await owner.close()
        await member.close()
        member_relogin = await self.connect("group_mutation_member")
        self.assertNotIn(
            message_id,
            {item["message_id"] for item in member_relogin.sync["group_messages"]},
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
            message_effect="stardust",
        )
        await self.send_and_receive(
            member,
            owner,
            "group_message",
            packet_id="channel-comment-1",
            group_message_id="channel-comment-1",
            group_id=group_id,
            group_name="News channel",
            members=[owner.node_id, member.node_id],
            owner_node=owner.node_id,
            admins=[owner.node_id],
            is_channel=True,
            message="encrypted channel comment",
            reply_to_message_id="channel-post-1",
            reply_to_text="Original post",
            group_key_id="key-1",
        )
        await self.send_and_receive(
            member,
            owner,
            "group_message",
            packet_id="channel-comment-1",
            group_message_id="channel-comment-1",
            group_id=group_id,
            group_name="News channel",
            members=[owner.node_id, member.node_id],
            owner_node=owner.node_id,
            admins=[owner.node_id],
            is_channel=True,
            message="encrypted channel comment",
            reply_to_message_id="channel-post-1",
            reply_to_text="Original post",
            is_channel_comment=True,
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
            message_effect="frost",
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
        comment = next(
            item
            for item in newcomer_relogin.sync["group_messages"]
            if item["message_id"] == "channel-comment-1"
        )
        self.assertEqual("channel-post-1", comment["reply_to_message_id"])
        self.assertEqual("Original post", comment["reply_to_text"])
        self.assertTrue(comment["is_channel_comment"])
        self.assertEqual(
            1,
            sum(
                1
                for item in newcomer_relogin.sync["group_messages"]
                if item["message_id"] == "channel-comment-1"
            ),
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
        self.assertEqual("frost", image_chunk["message_effect"])
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

    async def test_large_sticker_library_is_restored_from_chunks(self):
        alice_phone = await self.connect("sticker_chunked")
        observer = await self.connect("sticker_chunked_observer")
        library = {
            "packs": [
                {
                    "id": "large-pack",
                    "name": "Large pack",
                    "stickers": [
                        {
                            "id": "large-sticker",
                            "name": "Large sticker",
                            "file_name": "large.webp",
                            "mime_type": "image/webp",
                            "base64_data": "A" * (
                                server_sync.SERVER_STICKER_LIBRARY_INLINE_LIMIT
                                + 1024
                            ),
                        }
                    ],
                }
            ],
            "favorite_ids": ["large-sticker"],
        }
        await self.send_and_receive(
            alice_phone,
            observer,
            "sticker_library_update",
            login="sticker_chunked",
            sticker_library=library,
        )

        legacy_socket = CapturingWebSocket()
        await self.relay.send_account_sync(
            legacy_socket,
            "sticker_chunked",
            alice_phone.node_id,
            False,
        )
        legacy_sync = legacy_socket.sent[0]
        self.assertTrue(legacy_sync["sticker_library_omitted"])
        self.assertIsNone(legacy_sync["sticker_library"])
        self.assertNotIn(
            "server_sticker_library_sync_chunk",
            {packet["type"] for packet in legacy_socket.sent},
        )
        await alice_phone.close()

        alice_desktop = await self.connect("sticker_chunked")
        self.assertTrue(alice_desktop.sync["sticker_library_chunked"])
        self.assertEqual(library, alice_desktop.sync["sticker_library"])

    async def test_received_sticker_can_be_saved_to_another_account(self):
        sender = await self.connect("sticker_sender")
        receiver = await self.connect("sticker_receiver")
        sticker_id = "shared-sticker-file"

        delivered = await self.send_and_receive(
            sender,
            receiver,
            "file_chunk",
            file_id=sticker_id,
            filename="shared.webp",
            caption="",
            data="01020304",
            chunk_index=0,
            total_chunks=1,
            message_kind="sticker",
            sticker_id="shared-sticker",
            sticker_pack_id="shared-pack",
            sticker_pack_name="Shared pack",
        )
        self.assertEqual("sticker", delivered["message_kind"])

        receiver_library = {
            "packs": [
                {
                    "id": "saved-shared-pack",
                    "name": "Shared pack",
                    "stickers": [
                        {
                            "id": "shared-sticker",
                            "name": "Shared sticker",
                            "file_name": "shared.webp",
                            "mime_type": "image/webp",
                            "data": "01020304",
                        }
                    ],
                }
            ],
            "favorite_ids": ["shared-sticker"],
        }
        await receiver.send(
            {
                "type": "sticker_library_update",
                "packet_id": str(uuid.uuid4()),
                "protocol_version": 5,
                "source_node": receiver.node_id,
                "destination_node": "SERVER",
                "login": "sticker_receiver",
                "sticker_library": receiver_library,
                "ttl": 5,
            }
        )
        await asyncio.sleep(0.05)

        await receiver.close()
        receiver_tablet = await self.connect("sticker_receiver")
        self.assertEqual(receiver_library, receiver_tablet.sync["sticker_library"])
        self.assertIn(
            sticker_id,
            {item["file_id"] for item in receiver_tablet.sync["files"]},
        )

        await sender.close()
        sender_desktop = await self.connect("sticker_sender")
        self.assertNotEqual(receiver_library, sender_desktop.sync["sticker_library"])

    async def test_meshprivacy_service_requires_subscription_for_config(self):
        account = await self.connect("vpn_subscriber")
        await account.close()

        async def service_connect(node_id, session_token=None):
            websocket = await websockets.connect(
                self.uri,
                max_size=server_module.WEBSOCKET_MAX_SIZE,
            )
            hello = {
                "type": "server_hello",
                "node_id": node_id,
                "username": "vpn_subscriber",
                "display_name": "VPN Subscriber",
                "login": "vpn_subscriber",
                "server_token": "integration-test-token",
                "service": "meshprivacy",
                "register_if_missing": False,
                "protocol_version": 5,
                "min_protocol_version": 5,
                "app_version": "1.3.0",
            }
            if session_token:
                hello["service_session_token"] = session_token
            else:
                hello["password"] = "test-password"
            await websocket.send(json.dumps(hello))
            welcome = json.loads(await websocket.recv())
            return websocket, welcome

        inactive_socket, inactive_welcome = await service_connect(
            "meshprivacy-device-a"
        )
        self.assertFalse(inactive_welcome["subscription"]["active"])
        self.assertFalse(
            inactive_welcome["subscription"]["entitlements"]["features"]
            ["meshprivacy_vpn"]
        )
        session_token = inactive_welcome["service_session_token"]
        await inactive_socket.send(
            json.dumps({"type": "meshpro_catalog_request"})
        )
        catalog = json.loads(await inactive_socket.recv())
        self.assertTrue(catalog["ok"])
        self.assertEqual("meshpro", catalog["catalog"]["product"])
        await inactive_socket.send(json.dumps({"type": "vpn_config_request"}))
        denied = json.loads(await inactive_socket.recv())
        self.assertFalse(denied["ok"])
        self.assertEqual("subscription_required", denied["reason"])
        await inactive_socket.close()

        self.relay.grant_subscription("vpn_subscriber", days=30)
        active_socket, active_welcome = await service_connect(
            "meshprivacy-device-a",
            session_token,
        )
        self.assertTrue(active_welcome["subscription"]["active"])
        self.assertTrue(
            active_welcome["subscription"]["entitlements"]["features"]
            ["meshprivacy_vpn"]
        )
        await active_socket.send(json.dumps({"type": "vpn_config_request"}))
        granted = json.loads(await active_socket.recv())
        self.assertTrue(granted["ok"])
        self.assertIn("[Interface]", granted["config"])
        await active_socket.close()

    async def test_meshprivacy_rejects_retired_app_version(self):
        account = await self.connect("vpn_retired_client")
        await account.close()

        websocket = await websockets.connect(
            self.uri,
            max_size=server_module.WEBSOCKET_MAX_SIZE,
        )
        await websocket.send(
            json.dumps(
                {
                    "type": "server_hello",
                    "node_id": "meshprivacy-retired-device",
                    "username": "vpn_retired_client",
                    "display_name": "VPN Retired Client",
                    "login": "vpn_retired_client",
                    "password": "test-password",
                    "server_token": "integration-test-token",
                    "service": "meshprivacy",
                    "register_if_missing": False,
                    "protocol_version": 5,
                    "min_protocol_version": 5,
                    "app_version": "1.2.0",
                }
            )
        )
        rejected = json.loads(await websocket.recv())
        self.assertEqual("server_error", rejected["type"])
        self.assertEqual("meshprivacy_update_required", rejected["code"])
        self.assertEqual("1.3.0", rejected["minimum_app_version"])
        await websocket.close()


if __name__ == "__main__":
    unittest.main()
