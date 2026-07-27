import hashlib
import tempfile
import unittest
from pathlib import Path

from server.media_object_store import LocalMediaObjectStore


class LocalMediaObjectStoreTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.store = LocalMediaObjectStore(self.temp.name)

    def tearDown(self):
        self.temp.cleanup()

    def test_commit_is_content_addressed_and_resolvable(self):
        payload = b"mesh-object-storage"
        media_id = hashlib.sha256(payload).hexdigest()
        source = Path(self.temp.name) / "source.bin"
        source.write_bytes(payload)

        stored = self.store.commit(source, media_id, len(payload))

        self.assertEqual(self.store.path_for(media_id), stored)
        self.assertEqual(payload, stored.read_bytes())
        self.assertEqual(stored, self.store.resolve("", media_id))

    def test_commit_rejects_checksum_and_removes_temporary_file(self):
        source = Path(self.temp.name) / "source.bin"
        source.write_bytes(b"wrong payload")
        expected = hashlib.sha256(b"expected payload").hexdigest()

        with self.assertRaisesRegex(ValueError, "checksum"):
            self.store.commit(source, expected)

        self.assertFalse(self.store.path_for(expected).exists())
        self.assertEqual([], list(Path(self.temp.name).rglob("*.uploading")))

    def test_health_reports_available_storage(self):
        health = self.store.health()

        self.assertEqual("local", health["backend"])
        self.assertGreater(health["available_bytes"], 0)


if __name__ == "__main__":
    unittest.main()
