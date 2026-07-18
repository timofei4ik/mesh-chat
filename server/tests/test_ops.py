import gzip
import json
import sqlite3
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path

from server import server as server_module
from server import server_storage
from server.ops.backup_server import create_backup
from server.ops.healthcheck_server import collect_health


class ServerOperationsTests(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.root = Path(self.temp_dir.name)
        self.database = self.root / "data" / "server.db"
        self.backups = self.root / "backups"
        self.previous_db_path = server_storage.DB_PATH
        server_storage.DB_PATH = self.database
        self.relay = server_module.MeshRelayServer()

    def tearDown(self):
        self.relay.db.close()
        server_storage.DB_PATH = self.previous_db_path
        self.temp_dir.cleanup()

    def test_verified_backup_can_be_restored_and_is_rotated(self):
        self.relay.db.execute(
            """
            INSERT INTO accounts(
                login,
                password_salt,
                password_hash,
                display_name
            )
            VALUES('backup-user', 'salt', 'hash', 'Backup User')
            """
        )
        self.relay.save_group_members(
            "backup-group",
            "Backup group",
            ["backup-owner-device", "backup-admin-device"],
            owner_node="backup-owner-device",
            admins=["backup-admin-device"],
        )
        event_packet = {
            "type": "message_delete",
            "packet_id": "backup-delete-packet",
            "operation_id": "message_delete:backup-message",
            "message_id": "backup-message",
            "source_node": "backup-owner-device",
            "destination_node": "backup-admin-device",
        }
        cursors = self.relay.record_sync_v2_event(
            event_packet,
            ["backup-user"],
        )
        cursor = cursors["backup-user"]
        self.assertTrue(
            self.relay.acknowledge_sync_v2_cursor(
                "backup-user",
                "backup-owner-device",
                cursor,
            )
        )
        self.assertTrue(
            self.relay.mark_mutation_processed(
                "backup-user",
                "message_delete:backup-message|backup-admin-device|",
                "message_delete:backup-message",
                "message_delete",
                "backup-message",
            )
        )
        self.relay.db.commit()

        start = datetime(2026, 7, 1, tzinfo=timezone.utc)
        results = [
            create_backup(
                self.database,
                self.backups,
                keep=2,
                now=start + timedelta(days=offset),
            )
            for offset in range(3)
        ]

        backups = sorted(self.backups.glob("server-*.db.gz"))
        self.assertEqual(2, len(backups))
        self.assertFalse(Path(results[0]["path"]).exists())
        self.assertTrue(Path(results[-1]["path"]).exists())
        self.assertTrue(
            Path(results[-1]["path"] + ".sha256").exists()
        )

        restored = self.root / "restored.db"
        with gzip.open(results[-1]["path"], "rb") as source:
            restored.write_bytes(source.read())
        connection = sqlite3.connect(restored)
        try:
            self.assertEqual(
                "backup-user",
                connection.execute("SELECT login FROM accounts").fetchone()[0],
            )
            self.assertEqual(
                "ok",
                connection.execute("PRAGMA integrity_check").fetchone()[0],
            )
            self.assertEqual(
                (
                    "backup-owner-device",
                    '["backup-admin-device"]',
                ),
                connection.execute(
                    """
                    SELECT owner_node, admins_json
                    FROM server_groups
                    WHERE group_id='backup-group'
                    """
                ).fetchone(),
            )
            self.assertEqual(
                (
                    "message_delete:backup-message",
                    "message_delete",
                ),
                connection.execute(
                    """
                    SELECT operation_id, packet_type
                    FROM sync_events
                    WHERE account_login='backup-user'
                    """
                ).fetchone(),
            )
            self.assertEqual(
                cursor,
                connection.execute(
                    """
                    SELECT cursor
                    FROM sync_cursors
                    WHERE account_login='backup-user'
                      AND node_id='backup-owner-device'
                    """
                ).fetchone()[0],
            )
            self.assertEqual(
                1,
                connection.execute(
                    """
                    SELECT COUNT(*)
                    FROM processed_mutations
                    WHERE account_login='backup-user'
                      AND operation_id='message_delete:backup-message'
                    """
                ).fetchone()[0],
            )
        finally:
            connection.close()

    def test_health_check_reports_clean_and_dirty_queue_states(self):
        create_backup(
            self.database,
            self.backups,
            keep=2,
            now=datetime.now(timezone.utc),
        )
        clean = collect_health(
            self.database,
            self.backups,
            check_service=False,
            check_port=False,
        )
        self.assertEqual([], clean["critical"])
        self.assertEqual(["ok"], clean["database"]["quick_check"])
        self.assertEqual(0, clean["database"]["offline_queue"]["total"])
        self.assertEqual(0, clean["database"]["orphan_reactions"])

        self.relay.db.execute(
            """
            INSERT INTO offline_packets(destination_node, packet_json)
            VALUES('device-1', ?)
            """,
            (json.dumps({"type": "typing"}),),
        )
        self.relay.db.execute(
            """
            INSERT INTO server_reactions(
                scope,
                message_id,
                reactor_node,
                reaction
            )
            VALUES('direct', 'missing-message', 'device-1', 'heart')
            """
        )
        self.relay.db.commit()

        warning = collect_health(
            self.database,
            self.backups,
            check_service=False,
            check_port=False,
        )
        self.assertEqual("warning", warning["status"])
        self.assertEqual(1, warning["database"]["offline_queue"]["unsupported"])
        self.assertEqual(1, warning["database"]["orphan_reactions"])


if __name__ == "__main__":
    unittest.main()
