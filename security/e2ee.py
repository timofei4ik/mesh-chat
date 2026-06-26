import base64
import json
import os

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric.x25519 import (
    X25519PrivateKey,
    X25519PublicKey,
)
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.kdf.hkdf import HKDF
from cryptography.hazmat.primitives.kdf.pbkdf2 import PBKDF2HMAC


ENCRYPTED_PREFIX = "MCENC1:"
BINARY_PREFIX = b"MCBIN1:"
GROUP_PREFIX = "MCGRP1:"
GROUP_BINARY_PREFIX = b"MCGBIN1:"
PRIVATE_KEY_ITERATIONS = 300_000


def _encode(data):
    return base64.urlsafe_b64encode(data).decode("ascii")


def _decode(data):
    return base64.urlsafe_b64decode(data.encode("ascii"))


class EncryptionIdentity:
    def __init__(self, db, password, login=""):
        self.db = db
        self.password = password or ""
        self.login = (login or "").strip().lower()
        self.private_key = self._load_or_create_private_key()
        self.public_key = self.private_key.public_key()

    @property
    def public_key_text(self):
        return _encode(
            self.public_key.public_bytes(
                serialization.Encoding.Raw,
                serialization.PublicFormat.Raw,
            )
        )

    def encrypt_text(self, recipient_public_key, text):
        if not recipient_public_key:
            return text

        payload = {
            "v": 1,
            "to": self._seal(
                recipient_public_key,
                text.encode("utf-8"),
            ),
            "from": self._seal(
                self.public_key_text,
                text.encode("utf-8"),
            ),
        }

        return ENCRYPTED_PREFIX + _encode(
            json.dumps(
                payload,
                separators=(",", ":"),
            ).encode("utf-8")
        )

    def decrypt_text(self, value):
        if not isinstance(value, str) or not value.startswith(ENCRYPTED_PREFIX):
            return value

        try:
            payload = json.loads(
                _decode(
                    value[len(ENCRYPTED_PREFIX):]
                ).decode("utf-8")
            )

            for field in ("to", "from"):
                sealed = payload.get(field)
                if not sealed:
                    continue

                try:
                    return self._open(sealed).decode("utf-8")
                except Exception:
                    continue

        except Exception:
            pass

        return "[Зашифрованное сообщение: ключ недоступен]"

    def encrypt_bytes(self, recipient_public_key, data):
        if not recipient_public_key:
            return data

        return BINARY_PREFIX + json.dumps(
            {
                "v": 1,
                "to": self._seal(
                    recipient_public_key,
                    data,
                ),
                "from": self._seal(
                    self.public_key_text,
                    data,
                ),
            },
            separators=(",", ":"),
        ).encode("utf-8")

    def decrypt_bytes(self, data):
        if not data.startswith(BINARY_PREFIX):
            return data

        payload = json.loads(
            data[len(BINARY_PREFIX):].decode("utf-8")
        )

        for field in ("to", "from"):
            sealed = payload.get(field)

            if not sealed:
                continue

            try:
                return self._open(sealed)
            except Exception:
                continue

        raise ValueError(
            "Ключ для расшифровки файла недоступен."
            )

    def generate_group_key(self):
        return os.urandom(32)

    def wrap_group_key(self, recipient_public_key, group_key):
        if not recipient_public_key:
            return ""

        return self.encrypt_text(
            recipient_public_key,
            _encode(group_key),
        )

    def unwrap_group_key(self, envelope):
        value = self.decrypt_text(envelope)

        if value.startswith("[Зашифрованное сообщение:"):
            raise ValueError("Не удалось расшифровать ключ группы.")

        return _decode(value)

    def encrypt_group_text(self, group_key, text):
        nonce = os.urandom(12)
        ciphertext = AESGCM(group_key).encrypt(
            nonce,
            text.encode("utf-8"),
            b"meshchat-group-v1",
        )

        return GROUP_PREFIX + _encode(
            nonce + ciphertext
        )

    def decrypt_group_text(self, group_key, value):
        if not isinstance(value, str) or not value.startswith(GROUP_PREFIX):
            return value

        payload = _decode(
            value[len(GROUP_PREFIX):]
        )

        return AESGCM(group_key).decrypt(
            payload[:12],
            payload[12:],
            b"meshchat-group-v1",
        ).decode("utf-8")

    def encrypt_group_bytes(self, group_key, data):
        nonce = os.urandom(12)

        return GROUP_BINARY_PREFIX + nonce + AESGCM(
            group_key
        ).encrypt(
            nonce,
            data,
            b"meshchat-group-file-v1",
        )

    def decrypt_group_bytes(self, group_key, data):
        if not data.startswith(GROUP_BINARY_PREFIX):
            return data

        payload = data[len(GROUP_BINARY_PREFIX):]

        return AESGCM(group_key).decrypt(
            payload[:12],
            payload[12:],
            b"meshchat-group-file-v1",
        )

    def _seal(self, recipient_public_key, plaintext):
        ephemeral_private = X25519PrivateKey.generate()
        recipient_key = X25519PublicKey.from_public_bytes(
            _decode(recipient_public_key)
        )
        shared_key = ephemeral_private.exchange(recipient_key)
        key = HKDF(
            algorithm=hashes.SHA256(),
            length=32,
            salt=None,
            info=b"meshchat-e2ee-v1",
        ).derive(shared_key)
        nonce = os.urandom(12)
        ciphertext = AESGCM(key).encrypt(
            nonce,
            plaintext,
            b"meshchat-e2ee-v1",
        )

        return {
            "e": _encode(
                ephemeral_private.public_key().public_bytes(
                    serialization.Encoding.Raw,
                    serialization.PublicFormat.Raw,
                )
            ),
            "n": _encode(nonce),
            "c": _encode(ciphertext),
        }

    def _open(self, sealed):
        ephemeral_key = X25519PublicKey.from_public_bytes(
            _decode(sealed["e"])
        )
        shared_key = self.private_key.exchange(ephemeral_key)
        key = HKDF(
            algorithm=hashes.SHA256(),
            length=32,
            salt=None,
            info=b"meshchat-e2ee-v1",
        ).derive(shared_key)

        return AESGCM(key).decrypt(
            _decode(sealed["n"]),
            _decode(sealed["c"]),
            b"meshchat-e2ee-v1",
        )

    def _load_or_create_private_key(self):
        wrapped = self.db.get_setting("e2ee_private_key")
        salt_text = self.db.get_setting("e2ee_private_salt")

        if wrapped and salt_text:
            try:
                salt = _decode(salt_text)
                key = self._password_key(salt)
                payload = json.loads(wrapped)
                raw = AESGCM(key).decrypt(
                    _decode(payload["n"]),
                    _decode(payload["c"]),
                    b"meshchat-private-key-v1",
                )
                return X25519PrivateKey.from_private_bytes(raw)
            except Exception:
                raise ValueError(
                    "Не удалось открыть ключ шифрования: неверный пароль "
                    "или повреждены данные профиля."
                )

        if self.login and self.password:

            identity_salt = hashes.Hash(
                hashes.SHA256()
            )
            identity_salt.update(
                (
                    "meshchat-e2ee-identity:"
                    + self.login
                ).encode("utf-8")
            )

            raw = PBKDF2HMAC(
                algorithm=hashes.SHA256(),
                length=32,
                salt=identity_salt.finalize(),
                iterations=PRIVATE_KEY_ITERATIONS,
            ).derive(
                self.password.encode("utf-8")
            )

            private_key = X25519PrivateKey.from_private_bytes(
                raw
            )

        else:

            private_key = X25519PrivateKey.generate()

        raw = private_key.private_bytes(
            serialization.Encoding.Raw,
            serialization.PrivateFormat.Raw,
            serialization.NoEncryption(),
        )
        salt = os.urandom(16)
        nonce = os.urandom(12)
        ciphertext = AESGCM(
            self._password_key(salt)
        ).encrypt(
            nonce,
            raw,
            b"meshchat-private-key-v1",
        )
        self.db.set_setting(
            "e2ee_private_key",
            json.dumps(
                {
                    "n": _encode(nonce),
                    "c": _encode(ciphertext),
                },
                separators=(",", ":"),
            ),
        )
        self.db.set_setting(
            "e2ee_private_salt",
            _encode(salt),
        )
        return private_key

    def _password_key(self, salt):
        return PBKDF2HMAC(
            algorithm=hashes.SHA256(),
            length=32,
            salt=salt,
            iterations=PRIVATE_KEY_ITERATIONS,
        ).derive(
            self.password.encode("utf-8")
        )
