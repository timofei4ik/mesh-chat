import hashlib
import json
import re
import secrets

try:
    from server.config import PASSWORD_ITERATIONS
except ModuleNotFoundError:
    from config import PASSWORD_ITERATIONS


class ServerAuthMixin:
    def hash_password(
        self,
        password,
        salt_hex
    ):

        return hashlib.pbkdf2_hmac(
            "sha256",
            password.encode(
                "utf-8"
            ),
            bytes.fromhex(
                salt_hex
            ),
            PASSWORD_ITERATIONS
        ).hex()

    def authenticate_account(
        self,
        login,
        password,
        node_id,
        display_name,
        verify_only=False,
        public_username=None,
        about=None,
        avatar_data=None,
        encryption_public_key=None,
        allow_registration=True,
        reactivate_device=False,
        email=None,
        email_verified=False,
    ):

        login = (
            login
            or ""
        ).strip().lower()

        password = password or ""
        public_username = self.normalize_public_username(
            public_username
            or login
        )

        if not login or not password:
            return False, "missing login or password"

        if public_username:
            with self.unit_of_work_factory() as unit_of_work:
                username_owner = (
                    unit_of_work.identity.public_username_owner(
                        public_username,
                        login,
                    )
                )
            if username_owner:
                return False, "username is already taken"

        with self.unit_of_work_factory() as unit_of_work:
            row = unit_of_work.identity.credentials(login)

        if not row:

            if not allow_registration:
                return False, "account does not exist"

            salt_hex = secrets.token_bytes(
                16
            ).hex()

            password_hash = self.hash_password(
                password,
                salt_hex
            )

            with self.unit_of_work_factory(write=True) as unit_of_work:
                unit_of_work.identity.create_account(
                    {
                        "login": login,
                        "password_salt": salt_hex,
                        "password_hash": password_hash,
                        "node_id": node_id,
                        "display_name": display_name,
                        "public_username": public_username,
                        "about": about,
                        "avatar_data": avatar_data,
                        "encryption_public_key": encryption_public_key,
                        "email": (
                            self.normalize_email(email)
                            if email_verified
                            else ""
                        ),
                        "email_verified": bool(email_verified),
                    }
                )

            print(
                f"Account registered: {login}"
            )

            return True, "registered"

        salt_hex, expected_hash = row

        password_hash = self.hash_password(
            password,
            salt_hex
        )

        if not secrets.compare_digest(
            password_hash,
            expected_hash
        ):
            return False, "bad login or password"

        if verify_only:

            return True, "ok"

        if self.is_account_device_revoked(login, node_id):

            if not reactivate_device:
                return False, "device session was revoked"

            self.reactivate_account_device(login, node_id)

        with self.unit_of_work_factory(write=True) as unit_of_work:
            unit_of_work.identity.record_login(
                login,
                node_id,
                encryption_public_key,
            )

        return True, "ok"

    def get_account_encryption_recovery(self, login):

        normalized_login = (
            login
            or ""
        ).strip().lower()

        if not normalized_login:
            return ""

        with self.unit_of_work_factory() as unit_of_work:
            return unit_of_work.identity.encryption_recovery(
                normalized_login
            )

    def delete_account(self, login, password):
        normalized_login = str(login or "").strip().lower()
        if not normalized_login or not self.verify_account_password(
            normalized_login,
            password,
        ):
            return False, "bad login or password"
        self.account_deletion_orchestrator.delete(normalized_login)
        return True, "ok"

    def change_account_password(
        self,
        login,
        current_password,
        new_password,
        encryption_recovery
    ):

        normalized_login = (
            login
            or ""
        ).strip().lower()
        current_password = current_password or ""
        new_password = new_password or ""

        if not normalized_login:
            return False, "account_not_found"

        if len(new_password) < 8:
            return False, "password_too_short"

        if len(new_password) > 256:
            return False, "password_too_long"

        if new_password == current_password:
            return False, "password_unchanged"

        if not self._valid_encryption_recovery(encryption_recovery):
            return False, "invalid_encryption_recovery"

        with self.unit_of_work_factory() as unit_of_work:
            row = unit_of_work.identity.credentials(normalized_login)

        if not row:
            return False, "account_not_found"

        current_hash = self.hash_password(
            current_password,
            row[0]
        )

        if not secrets.compare_digest(current_hash, row[1]):
            return False, "invalid_current_password"

        salt_hex = secrets.token_bytes(16).hex()
        password_hash = self.hash_password(new_password, salt_hex)

        try:
            with self.unit_of_work_factory(write=True) as unit_of_work:
                unit_of_work.identity.change_credentials(
                    normalized_login,
                    salt_hex,
                    password_hash,
                    encryption_recovery,
                )
        except Exception:
            return False, "password_change_failed"

        return True, "ok"

    @staticmethod
    def _valid_encryption_recovery(value):

        if not isinstance(value, str) or not value or len(value) > 4096:
            return False

        try:
            payload = json.loads(value)
        except (TypeError, ValueError):
            return False

        if not isinstance(payload, dict) or payload.get("v") != 1:
            return False

        for field in ("s", "n", "c", "m"):
            item = payload.get(field)
            if not isinstance(item, str) or not item or len(item) > 512:
                return False

        return payload.get("i") == 300000

    def normalize_public_username(
        self,
        username
    ):

        username = (
            username
            or ""
        ).strip().lower().lstrip("@")

        username = re.sub(
            r"[^a-z0-9_]",
            "_",
            username
        ).strip("_")

        return username[:32]
