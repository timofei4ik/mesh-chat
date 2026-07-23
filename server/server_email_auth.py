import hashlib
import hmac
import re
import secrets
import smtplib
from email.message import EmailMessage
from email.utils import formataddr, formatdate, make_msgid

try:
    from server.config import (
        EMAIL_2FA_CODE_TTL_SECONDS,
        EMAIL_2FA_MAX_ATTEMPTS,
        EMAIL_2FA_RESEND_SECONDS,
        EMAIL_2FA_SECRET,
        SMTP_FROM_EMAIL,
        SMTP_FROM_NAME,
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
        SMTP_FROM_NAME,
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
        with self.unit_of_work_factory() as unit_of_work:
            return self.normalize_email(
                unit_of_work.identity.verified_email(login)
            )

    def account_exists(self, login):
        with self.unit_of_work_factory() as unit_of_work:
            return unit_of_work.identity.account_exists(login)

    def email_binding_required(self, login):
        return self.account_exists(login) and not self.account_email(login)

    def verify_account_password(self, login, password):
        with self.unit_of_work_factory() as unit_of_work:
            row = unit_of_work.identity.credentials(login)
        if not row:
            return False
        candidate = self.hash_password(str(password or ""), row[0])
        return secrets.compare_digest(candidate, row[1])

    def is_email_device_trusted(self, login, node_id):
        with self.unit_of_work_factory() as unit_of_work:
            return unit_of_work.identity.is_email_device_trusted(
                login,
                node_id,
            )

    def trust_email_device(self, login, node_id):
        normalized_login = str(login or "").strip().lower()
        normalized_node = str(node_id or "").strip()
        if not normalized_login or not normalized_node:
            return
        with self.unit_of_work_factory(write=True) as unit_of_work:
            unit_of_work.identity.trust_email_device(
                normalized_login,
                normalized_node,
            )

    def bind_account_email(self, login, email, node_id):
        normalized_login = str(login or "").strip().lower()
        normalized_email = self.normalize_email(email)
        if not normalized_login or not normalized_email:
            return False, "invalid_email"
        with self.unit_of_work_factory(write=True) as unit_of_work:
            owner = unit_of_work.identity.email_owner(
                normalized_email,
                normalized_login,
            )
            if owner:
                return False, "email_already_used"
            unit_of_work.identity.bind_email(
                normalized_login,
                normalized_email,
                node_id,
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
        with self.unit_of_work_factory() as unit_of_work:
            recent_age = unit_of_work.identity.latest_email_challenge_age(
                normalized_login,
                normalized_node,
                purpose,
            )
        if (
            recent_age is not None
            and recent_age < EMAIL_2FA_RESEND_SECONDS
        ):
            return (
                None,
                None,
                f"retry_after:{EMAIL_2FA_RESEND_SECONDS - recent_age}",
            )
        challenge_id = secrets.token_urlsafe(24)
        code = f"{secrets.randbelow(1_000_000):06d}"
        salt = secrets.token_hex(16)
        code_hash = self._email_code_hash(challenge_id, salt, code)
        with self.unit_of_work_factory(write=True) as unit_of_work:
            unit_of_work.identity.create_email_challenge(
                {
                    "challenge_id": challenge_id,
                    "login": normalized_login,
                    "node_id": normalized_node,
                    "email": normalized_email,
                    "purpose": purpose,
                    "code_salt": salt,
                    "code_hash": code_hash,
                    "expires_delta": (
                        f"+{EMAIL_2FA_CODE_TTL_SECONDS} seconds"
                    ),
                }
            )
        return {
            "challenge_id": challenge_id,
            "masked_email": self.mask_email(normalized_email),
            "purpose": purpose,
            "expires_in": EMAIL_2FA_CODE_TTL_SECONDS,
            "retry_after": EMAIL_2FA_RESEND_SECONDS,
        }, code, "ok"

    def discard_email_challenge(self, challenge_id):
        with self.unit_of_work_factory(write=True) as unit_of_work:
            unit_of_work.identity.discard_email_challenge(challenge_id)

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
        with self.unit_of_work_factory() as unit_of_work:
            challenge = unit_of_work.identity.email_challenge(
                challenge_id,
                purpose,
            )
        if not challenge:
            return False, "invalid_code", ""
        if not challenge["active"]:
            return False, "code_expired", ""
        if (
            challenge["login"] != str(login or "").strip().lower()
            or challenge["node_id"] != str(node_id or "").strip()
        ):
            return False, "invalid_code", ""
        attempts = challenge["attempts"]
        if attempts >= EMAIL_2FA_MAX_ATTEMPTS:
            return False, "too_many_attempts", ""
        expected = self._email_code_hash(
            challenge_id,
            challenge["code_salt"],
            str(code or "").strip(),
        )
        if not secrets.compare_digest(expected, challenge["code_hash"]):
            with self.unit_of_work_factory(write=True) as unit_of_work:
                unit_of_work.identity.increment_email_challenge_attempts(
                    challenge_id
                )
            return False, "invalid_code", ""
        with self.unit_of_work_factory(write=True) as unit_of_work:
            unit_of_work.identity.consume_email_challenge(challenge_id)
        return True, "ok", challenge["email"]

    def send_email_verification_code(self, email, code, purpose):
        if not SMTP_HOST or not SMTP_FROM_EMAIL:
            raise RuntimeError("SMTP is not configured")
        message = EmailMessage()
        message["Subject"] = "MeshChat verification code"
        message["From"] = formataddr(
            (SMTP_FROM_NAME or "MeshChat", SMTP_FROM_EMAIL)
        )
        message["To"] = email
        message["Date"] = formatdate(localtime=False)
        message["Message-ID"] = make_msgid(
            domain=SMTP_FROM_EMAIL.rsplit("@", 1)[-1]
        )
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
