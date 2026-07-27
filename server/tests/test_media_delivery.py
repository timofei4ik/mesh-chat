import hashlib
import sqlite3
import tempfile
import unittest
from pathlib import Path

from server.server_media import ServerMediaMixin
from server.server_media_http import MediaHttpServer


class _Relay(ServerMediaMixin):
    def __init__(self, root):
        self.db = sqlite3.connect(":memory:")
        self.db.executescript(
            """
            CREATE TABLE account_devices(login TEXT, node_id TEXT);
            CREATE TABLE server_group_members(
                group_id TEXT,
                login TEXT,
                node_id TEXT
            );
            CREATE TABLE server_files(
                file_id TEXT PRIMARY KEY,
                media_id TEXT,
                storage_path TEXT,
                data TEXT,
                sha256 TEXT,
                size_bytes INTEGER,
                filename TEXT,
                group_id TEXT,
                group_key_id TEXT,
                sender_login TEXT,
                receiver_login TEXT,
                sender_node TEXT,
                receiver_node TEXT
            );
            """
        )
        payload = b"mesh-media-range-test"
        path = Path(root) / "payload.bin"
        path.write_bytes(payload)
        digest = hashlib.sha256(payload).hexdigest()
        self.db.execute(
            """
            INSERT INTO account_devices(login, node_id)
            VALUES ('alice', 'alice-phone'), ('bob', 'bob-phone')
            """
        )
        self.db.execute(
            """
            INSERT INTO server_group_members(group_id, login, node_id)
            VALUES ('group-1', 'bob', 'bob-phone')
            """
        )
        self.db.execute(
            """
            INSERT INTO server_files(
                file_id, media_id, storage_path, data, sha256, size_bytes,
                filename, group_id, group_key_id, sender_login,
                receiver_login, sender_node, receiver_node
            ) VALUES (?, ?, ?, '', ?, ?, 'report.bin', '', '', 'alice',
                      'bob', 'alice-phone', 'bob-phone')
            """,
            ("direct-file", digest, str(path), digest, len(payload)),
        )
        self.db.execute(
            """
            INSERT INTO server_files(
                file_id, media_id, storage_path, data, sha256, size_bytes,
                filename, group_id, group_key_id, sender_login,
                receiver_login, sender_node, receiver_node
            ) VALUES ('group-file', 'group-media', '', '01020304', '', 4,
                      'secret.bin', 'group-1', 'key-1', 'alice', '',
                      'alice-phone', '')
            """
        )
        self.db.commit()
        self.initialize_media_delivery()


class MediaDeliveryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.relay = _Relay(self.temp.name)

    def tearDown(self):
        self.relay.db.close()
        self.temp.cleanup()

    def test_direct_participants_and_group_members_are_authorized(self):
        self.assertIsNotNone(
            self.relay.resolve_media_file("alice", "direct-file")
        )
        self.assertIsNotNone(
            self.relay.resolve_media_file("bob", "direct-file")
        )
        self.assertIsNotNone(
            self.relay.resolve_media_file("bob", "group-file")
        )
        self.assertIsNone(
            self.relay.resolve_media_file("mallory", "direct-file")
        )
        self.assertIsNone(
            self.relay.resolve_media_file("mallory", "group-file")
        )

    def test_download_token_is_scoped_and_tamper_proof(self):
        issued = self.relay.issue_media_download("bob", "direct-file")
        self.assertIsNotNone(issued)
        authorized = self.relay.authorize_media_download(
            issued["download_token"],
            "direct-file",
        )
        self.assertEqual("direct-file", authorized["file_id"])
        self.assertIsNone(
            self.relay.authorize_media_download(
                issued["download_token"],
                "group-file",
            )
        )
        self.assertIsNone(
            self.relay.authorize_media_download(
                f'{issued["download_token"]}x',
                "direct-file",
            )
        )

    def test_download_token_is_valid_across_media_runtimes(self):
        second_relay = _Relay(self.temp.name)
        try:
            issued = self.relay.issue_media_download("bob", "direct-file")
            authorized = second_relay.authorize_media_download(
                issued["download_token"],
                "direct-file",
            )
            self.assertEqual("direct-file", authorized["file_id"])
        finally:
            second_relay.db.close()

    def test_single_http_ranges_are_normalized(self):
        parse = MediaHttpServer._requested_range
        self.assertEqual((200, 0, 9), parse("", 10))
        self.assertEqual((206, 3, 7), parse("bytes=3-7", 10))
        self.assertEqual((206, 8, 9), parse("bytes=-2", 10))
        self.assertEqual((206, 4, 9), parse("bytes=4-", 10))
        self.assertEqual(416, parse("bytes=20-", 10)[0])
        self.assertEqual(416, parse("bytes=0-1,4-5", 10)[0])
