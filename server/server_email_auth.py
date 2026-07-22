import hashlib
import hmac
import re
import secrets
import smtplib
from email.message import EmailMessage

try:
    from server.config import (
        EMAIL_2FA_CODE_TTL_SECONDS,
        EMAIL_2FA_MAX_ATTEMPTS,
        EMAIL_2FA_RESEND_SECONDS,
        EMAIL_2FA_SECRET,
        SMTP_FROM_EMAIL,
        SMTP_HOST,
        SMTP_PASSWORD,
        SMTP_PORT,
        SMTP_USERNAME,
        SMTP_USE_SSL,
        SMTP_USE_TLS,
    )
except ModuleNotFoundError:
    from config import (
        EMAIL_2FA_CODE_TTL_SECONDS,
        EMAIL_2FA_MAX_ATTEMPTS,
        EMAIL_2FA_RESEND_SECONDS,
        EMAIL_2FA_SECRET,
        SMTP_FROM_EMAIL,
        SMTP_HOST,
        SMTP_PASSWORD,
        SMTP_PORT,
        SMTP_USERNAME,
        SMTP_USE_SSL,
        SMTP_USE_TLS,
    )


EMAIL_PATTERN = re.compile(r"^[^\s@]+@[^\s@]+\.[^\s@]+$")


class ServerEmailAuthMixin:
    @staticmethod
    def normalize_email(value):
        email = str(value or "").strip().lower()
        if len(email) > 254 or not EMAIL_PATTERN.fullmatch(email):
            return ""
        return email

    @staticmethod
    def mask_email(value):
        email = str(value or "").strip()
        if "@" not in email:
            return ""
        local, domain = email.split("@", 1)
        visible = local[:2] if len(local) > 2 else local[:1]
        return f"{visible}{'*' * max(2, len(local) - len(visible))}@{domain}"

    def account_email(self, login):
        row = self.db.execute(
            """
            SELECT COALESCE(email, ''), email_verified_at
            FROM accounts
            WHERE login=?
            """,
            (str(login or "").strip().lower(),),
        ).fetchone()
        if not row or not row[1]:
            return ""
        return self.normalize_email(row[0])

    def account_exists(self, login):
        return self.db.execute(
            "SELECT 1 FROM accounts WHERE login=?",
            (str(login or "").strip().lower(),),
        ).fetchone() is not None

    def email_binding_required(self, login):
        return self.account_exists(login) and not self.account_email(login)

    def verify_account_password(self, login, password):
        row = self.db.execute(
            "SELECT password_salt, password_hash FROM accounts WHERE login=?",
            (str(login or "").strip().lower(),),
        ).fetchone()
        if not row:
            return False
        candidate = self.hash_password(str(password or ""), row[0])
        return secrets.compare_digest(candidate, row[1])

    def is_email_device_trusted(self, login, node_id):
        row = self.db.execute(
            """
            SELECT 1
            FROM account_email_trusted_devices
            WHERE login=? AND node_id=?
            """,
            (
                str(login or "").strip().lower(),
                str(node_id or "").strip(),
            ),
        ).fetchone()
        return row is not None

    def trust_email_device(self, login, node_id):
        normalized_login = str(login or "").strip().lower()
        normalized_node = str(node_id or "").strip()
        if not normalized_login or not normalized_node:
            return
        self.db.execute(
            """
            INSERT INTO account_email_trusted_devices(login, node_id, verified_at)
            VALUES(?,?,CURRENT_TIMESTAMP)
            ON CONFLICT(login, node_id) DO UPDATE SET
                verified_at=CURRENT_TIMESTAMP
            """,
            (normalized_login, normalized_node),
        )
        self.db.commit()

    def bind_account_email(self, login, email, node_id):
        normalized_login = str(login or "").strip().lower()
        normalized_email = self.normalize_email(email)
        if not normalized_login or not normalized_email:
            return False, "invalid_email"
        owner = self.db.execute(
            """
            SELECT login FROM accounts
            WHERE lower(email)=? AND email_verified_at IS NOT NULL AND login!=?
            """,
            (normalized_email, normalized_login),
        ).fetchone()
        if owner:
            return False, "email_already_used"
        with self.db:
            self.db.execute(
                """
                UPDATE accounts
                SET email=?, email_verified_at=CURRENT_TIMESTAMP
                WHERE login=?
                """,
                (normalized_email, normalized_login),
            )
            self.db.execute(
                """
                INSERT INTO account_email_trusted_devices(login, node_id, verified_at)
                VALUES(?,?,CURRENT_TIMESTAMP)
                ON CONFLICT(login, node_id) DO UPDATE SET
                    verified_at=CURRENT_TIMESTAMP
                """,
                (normalized_login, str(node_id or "").strip()),
            )
        return True, "ok"

    def _email_code_hash(self, challenge_id, salt, code):
        if not EMAIL_2FA_SECRET:
            raise RuntimeError("MESH_EMAIL_2FA_SECRET is not configured")
        secret = EMAIL_2FA_SECRET
        payload = f"{challenge_id}:{salt}:{code}".encode("utf-8")
        return hmac.new(secret.encode("utf-8"), payload, hashlib.sha256).hexdigest()

    def create_email_challenge(self, login, node_id, email, purpose):
        normalized_login = str(login or "").strip().lower()
        normalized_node = str(node_id or "").strip()
        normalized_email = self.normalize_email(email)
        if not normalized_login or not normalized_node or not normalized_email:
            return None, None, "invalid_email"
        recent = self.db.execute(
            """
            SELECT CAST(strftime('%s','now') - strftime('%s', created_at) AS INTEGER)
            FROM email_auth_challenges
            WHERE login=? AND node_id=? AND purpose=? AND consumed_at IS NULL
            ORDER BY created_at DESC LIMIT 1
            """,
            (normalized_login, normalized_node, purpose),
        ).fetchone()
        if recent and recent[0] is not None and recent[0] < EMAIL_2FA_RESEND_SECONDS:
            return None, None, f"retry_after:{EMAIL_2FA_RESEND_SECONDS - recent[0]}"
        challenge_id = secrets.token_urlsafe(24)
        code = f"{secrets.randbelow(1_000_000):06d}"
        salt = secrets.token_hex(16)
        code_hash = self._email_code_hash(challenge_id, salt, code)
        self.db.execute(
            """
            INSERT INTO email_auth_challenges(
                challenge_id, login, node_id, email, purpose,
                code_salt, code_hash, expires_at
            ) VALUES(?,?,?,?,?,?,?,datetime('now', ?))
            """,
            (
                challenge_id,
                normalized_login,
                normalized_node,
                normalized_email,
                purpose,
                salt,
                code_hash,
                f"+{EMAIL_2FA_CODE_TTL_SECONDS} seconds",
            ),
        )
        self.db.commit()
        return {
            "challenge_id": challenge_id,
            "masked_email": self.mask_email(normalized_email),
            "purpose": purpose,
            "expires_in": EMAIL_2FA_CODE_TTL_SECONDS,
            "retry_after": EMAIL_2FA_RESEND_SECONDS,
        }, code, "ok"

    def discard_email_challenge(self, challenge_id):
        self.db.execute(
            "DELETE FROM email_auth_challenges WHERE challenge_id=?",
            (str(challenge_id or "").strip(),),
        )
        self.db.commit()

    def issue_email_challenge(self, login, node_id, email, purpose):
        challenge, code, reason = self.create_email_challenge(
            login,
            node_id,
            email,
            purpose,
        )
        if not challenge:
            return None, reason
        try:
            self.send_email_verification_code(email, code, purpose)
        except Exception as error:
            self.discard_email_challenge(challenge["challenge_id"])
            print(f"Email delivery failed for {login}: {error!r}")
            return None, "email_delivery_unavailable"
        return challenge, "ok"

    def verify_email_challenge(self, challenge_id, login, node_id, code, purpose):
        row = self.db.execute(
            """
            SELECT login, node_id, email, code_salt, code_hash, attempts,
                   expires_at > CURRENT_TIMESTAMP, consumed_at
            FROM email_auth_challenges
            WHERE challenge_id=? AND purpose=?
            """,
            (str(challenge_id or "").strip(), purpose),
        ).fetchone()
        if not row:
            return False, "invalid_code", ""
        if row[7] is not None or not row[6]:
            return False, "code_expired", ""
        if row[0] != str(login or "").strip().lower() or row[1] != str(node_id or "").strip():
            return False, "invalid_code", ""
        attempts = int(row[5] or 0)
        if attempts >= EMAIL_2FA_MAX_ATTEMPTS:
            return False, "too_many_attempts", ""
        expected = self._email_code_hash(challenge_id, row[3], str(code or "").strip())
        if not secrets.compare_digest(expected, row[4]):
            self.db.execute(
                "UPDATE email_auth_challenges SET attempts=attempts+1 WHERE challenge_id=?",
                (challenge_id,),
            )
            self.db.commit()
            return False, "invalid_code", ""
        self.db.execute(
            "UPDATE email_auth_challenges SET consumed_at=CURRENT_TIMESTAMP WHERE challenge_id=?",
            (challenge_id,),
        )
        self.db.commit()
        return True, "ok", row[2]

    def send_email_verification_code(self, email, code, purpose):
        if not SMTP_HOST or not SMTP_FROM_EMAIL:
            raise RuntimeError("SMTP is not configured")
        message = EmailMessage()
        message["Subject"] = "MeshChat verification code"
        message["From"] = SMTP_FROM_EMAIL
        message["To"] = email
        action = "finish registration" if purpose == "registration" else "confirm this device"
        if purpose == "binding":
            action = "bind this email to your MeshChat account"
        message.set_content(
            f"Your MeshChat code is: {code}\n\nUse it to {action}. "
            f"The code expires in {EMAIL_2FA_CODE_TTL_SECONDS // 60} minutes.\n\n"
            "If you did not request this code, ignore this email."
        )
        smtp_class = smtplib.SMTP_SSL if SMTP_USE_SSL else smtplib.SMTP
        with smtp_class(SMTP_HOST, SMTP_PORT, timeout=15) as client:
            if SMTP_USE_TLS and not SMTP_USE_SSL:
                client.starttls()
            if SMTP_USERNAME:
                client.login(SMTP_USERNAME, SMTP_PASSWORD)
            client.send_message(message)
