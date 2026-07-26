import base64
import hashlib
import hmac
import json
import secrets
import time
from pathlib import Path
from urllib.parse import quote

try:
    from server.config import (
        MEDIA_DOWNLOAD_TOKEN_TTL_SECONDS,
        MEDIA_PUBLIC_BASE_URL,
    )
except ModuleNotFoundError:
    from config import (
        MEDIA_DOWNLOAD_TOKEN_TTL_SECONDS,
        MEDIA_PUBLIC_BASE_URL,
    )


class ServerMediaMixin:
    def initialize_media_delivery(self):
        self._media_signing_secret = secrets.token_bytes(32)

    def resolve_media_file(self, login, file_id):
        normalized_login = str(login or "").strip().lower()
        normalized_file_id = str(file_id or "").strip()
        if not normalized_login or not normalized_file_id:
            return None

        row = self.db.execute(
            """
            SELECT file.file_id,
                   COALESCE(file.media_id, ''),
                   COALESCE(file.storage_path, ''),
                   COALESCE(file.data, ''),
                   COALESCE(file.sha256, ''),
                   COALESCE(file.size_bytes, 0),
                   COALESCE(file.filename, ''),
                   COALESCE(file.group_id, ''),
                   COALESCE(file.group_key_id, '')
            FROM server_files file
            WHERE file.file_id=?
              AND (
                LOWER(COALESCE(file.sender_login, ''))=?
                OR LOWER(COALESCE(file.receiver_login, ''))=?
                OR file.sender_node IN (
                    SELECT node_id
                    FROM account_devices
                    WHERE LOWER(login)=?
                )
                OR file.receiver_node IN (
                    SELECT node_id
                    FROM account_devices
                    WHERE LOWER(login)=?
                )
                OR (
                    COALESCE(file.group_id, '')!=''
                    AND EXISTS(
                        SELECT 1
                        FROM server_group_members member
                        WHERE member.group_id=file.group_id
                          AND (
                            LOWER(COALESCE(member.login, ''))=?
                            OR member.node_id IN (
                                SELECT node_id
                                FROM account_devices
                                WHERE LOWER(login)=?
                            )
                          )
                    )
                )
              )
            LIMIT 1
            """,
            (
                normalized_file_id,
                normalized_login,
                normalized_login,
                normalized_login,
                normalized_login,
                normalized_login,
                normalized_login,
            ),
        ).fetchone()
        if not row:
            return None

        storage_path = str(row[2] or "")
        inline_hex = str(row[3] or "")
        size_bytes = int(row[5] or 0)
        if storage_path and Path(storage_path).is_file():
            size_bytes = Path(storage_path).stat().st_size
        elif inline_hex:
            size_bytes = len(inline_hex) // 2
        else:
            return None

        sha256 = str(row[4] or "").strip().lower()
        media_id = str(row[1] or sha256 or row[0]).strip().lower()
        return {
            "file_id": str(row[0]),
            "media_id": media_id,
            "storage_path": storage_path,
            "inline_hex": inline_hex,
            "sha256": sha256,
            "size_bytes": size_bytes,
            "filename": str(row[6] or ""),
            "group_id": str(row[7] or ""),
            "group_key_id": str(row[8] or ""),
        }

    def issue_media_download(self, login, file_id):
        media = self.resolve_media_file(login, file_id)
        if not media:
            return None
        expires_at = int(time.time()) + MEDIA_DOWNLOAD_TOKEN_TTL_SECONDS
        payload = {
            "login": str(login or "").strip().lower(),
            "file_id": media["file_id"],
            "expires_at": expires_at,
        }
        encoded = self._encode_media_token_part(
            json.dumps(
                payload,
                ensure_ascii=True,
                separators=(",", ":"),
                sort_keys=True,
            ).encode("utf-8")
        )
        signature = self._encode_media_token_part(
            hmac.new(
                self._media_signing_secret,
                encoded.encode("ascii"),
                hashlib.sha256,
            ).digest()
        )
        return {
            **media,
            "download_url": (
                f"{MEDIA_PUBLIC_BASE_URL}/{quote(media['file_id'], safe='')}"
            ),
            "download_token": f"{encoded}.{signature}",
            "expires_at": expires_at,
        }

    def authorize_media_download(self, token, file_id):
        raw_token = str(token or "").strip()
        try:
            encoded, supplied_signature = raw_token.split(".", 1)
        except ValueError:
            return None
        expected_signature = self._encode_media_token_part(
            hmac.new(
                self._media_signing_secret,
                encoded.encode("ascii"),
                hashlib.sha256,
            ).digest()
        )
        if not hmac.compare_digest(supplied_signature, expected_signature):
            return None
        try:
            payload = json.loads(
                self._decode_media_token_part(encoded).decode("utf-8")
            )
        except (ValueError, UnicodeDecodeError, json.JSONDecodeError):
            return None
        if int(payload.get("expires_at") or 0) < int(time.time()):
            return None
        if not hmac.compare_digest(
            str(payload.get("file_id") or ""),
            str(file_id or ""),
        ):
            return None
        return self.resolve_media_file(
            payload.get("login"),
            payload.get("file_id"),
        )

    @staticmethod
    def _encode_media_token_part(value):
        return base64.urlsafe_b64encode(value).rstrip(b"=").decode("ascii")

    @staticmethod
    def _decode_media_token_part(value):
        padding = "=" * (-len(value) % 4)
        return base64.urlsafe_b64decode(f"{value}{padding}")
