import hashlib
import os
import shutil
import uuid
from pathlib import Path


class LocalMediaObjectStore:
    """Content-addressed local backend behind the media storage interface."""

    def __init__(self, root):
        self.root = Path(root).resolve()

    def ensure_ready(self):
        self.root.mkdir(parents=True, exist_ok=True)
        return self.root

    def path_for(self, media_id):
        normalized = str(media_id or "").strip().lower()
        if (
            len(normalized) != 64
            or any(character not in "0123456789abcdef" for character in normalized)
        ):
            raise ValueError("media_id must be a SHA-256 digest")
        return self.root / normalized[:2] / f"{normalized}.bin"

    def resolve(self, storage_path="", media_id=""):
        stored = str(storage_path or "").strip()
        if stored:
            candidate = Path(stored)
            if candidate.is_file():
                return candidate
        if media_id:
            try:
                candidate = self.path_for(media_id)
            except ValueError:
                return None
            if candidate.is_file():
                return candidate
        return None

    def commit(self, source_path, media_id, expected_size=0):
        source = Path(source_path)
        destination = self.path_for(media_id)
        destination.parent.mkdir(parents=True, exist_ok=True)
        temporary = destination.with_name(
            f".{destination.name}.{uuid.uuid4().hex}.uploading"
        )
        digest = hashlib.sha256()
        size = 0
        with source.open("rb") as input_file, temporary.open("wb") as output_file:
            while True:
                block = input_file.read(1024 * 1024)
                if not block:
                    break
                output_file.write(block)
                digest.update(block)
                size += len(block)
            output_file.flush()
            os.fsync(output_file.fileno())
        if digest.hexdigest() != str(media_id).strip().lower():
            temporary.unlink(missing_ok=True)
            raise ValueError("media object checksum mismatch")
        if expected_size and size != int(expected_size):
            temporary.unlink(missing_ok=True)
            raise ValueError("media object size mismatch")
        os.replace(temporary, destination)
        return destination

    def health(self):
        root = self.ensure_ready()
        usage = shutil.disk_usage(root)
        return {
            "backend": "local",
            "root": str(root),
            "available_bytes": int(usage.free),
        }
