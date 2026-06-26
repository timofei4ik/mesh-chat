import hashlib
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
        encryption_public_key=None
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

        cursor = self.db.cursor()

        if public_username:

            cursor.execute(
                """
                SELECT login
                FROM accounts
                WHERE public_username=?
                AND login!=?
                """,
                (
                    public_username,
                    login
                )
            )

            if cursor.fetchone():
                return False, "username is already taken"

        cursor.execute(
            """
            SELECT password_salt,
                   password_hash
            FROM accounts
            WHERE login=?
            """,
            (
                login,
            )
        )

        row = cursor.fetchone()

        if not row:

            salt_hex = secrets.token_bytes(
                16
            ).hex()

            password_hash = self.hash_password(
                password,
                salt_hex
            )

            self.db.execute(
                """
                INSERT INTO accounts(
                    login,
                    password_salt,
                    password_hash,
                    node_id,
                    display_name,
                    public_username,
                    about,
                    avatar_data,
                    encryption_public_key,
                    last_login
                )
                VALUES(?,?,?,?,?,?,?,?,?,CURRENT_TIMESTAMP)
                """,
                (
                    login,
                    salt_hex,
                    password_hash,
                    node_id,
                    display_name,
                    public_username,
                    about,
                    avatar_data,
                    encryption_public_key
                )
            )

            self.db.commit()

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

        self.db.execute(
            """
            UPDATE accounts
            SET node_id=?,
                encryption_public_key=COALESCE(
                    ?,
                    encryption_public_key
                ),
                last_login=CURRENT_TIMESTAMP
            WHERE login=?
            """,
            (
                node_id,
                encryption_public_key,
                login
            )
        )

        self.db.commit()

        return True, "ok"

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
