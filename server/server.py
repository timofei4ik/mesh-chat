import asyncio
import signal
import sys
from pathlib import Path

import websockets

ROOT_DIR = Path(__file__).resolve().parents[1]

if str(ROOT_DIR) not in sys.path:
    sys.path.insert(0, str(ROOT_DIR))

try:
    from server.config import (
        HOST,
        PORT,
        SERVER_TOKEN,
        REQUIRE_LOGIN,
        MESHPRIVACY_MIN_APP_VERSION,
        EMAIL_2FA_LEGACY_CLIENTS_ALLOWED,
        SYNC_V2_DELTA_ENABLED,
        SYNC_V2_DELTA_TEST_ACCOUNTS,
    )
    from server.server_storage import ServerStorageMixin
    from server.server_auth import ServerAuthMixin
    from server.server_email_auth import ServerEmailAuthMixin
    from server.server_ai import ServerAiMixin
    from server.server_sync import ServerSyncMixin
    from server.server_push import ServerPushMixin
    from server.server_billing import ServerBillingMixin
    from server.server_boosty import ServerBoostyMixin
    from server.server_subscription import ServerSubscriptionMixin
    from server.server_scheduler import ServerSchedulerMixin
    from server.server_wireguard import ServerWireGuardMixin
    from server.server_protocol import (
        APP_VERSION,
        PROTOCOL_VERSION,
        MIN_SUPPORTED_PROTOCOL_VERSION,
        WEBSOCKET_MAX_SIZE,
        WEBSOCKET_PING_INTERVAL_SECONDS,
        WEBSOCKET_PING_TIMEOUT_SECONDS,
        SUPPORTED_SERVICES,
        ACCOUNT_LIVE_FANOUT_PACKET_TYPES,
        app_version_supported,
        protocol_compatibility,
        version_payload,
    )
    from server.server_transport import ServerTransportMixin
    from server.server_workers import ServerWorkerSupervisor
    from server.server_commands import (
        build_control_command_registry,
        build_command_registry,
    )
    from server.server_connection import (
        HandshakeConfig,
        handle_connection,
    )
    from server.persistence.sqlite_account_deletion import (
        build_sqlite_account_deletion_orchestrator,
    )
except ModuleNotFoundError:
    from config import (
        HOST,
        PORT,
        SERVER_TOKEN,
        REQUIRE_LOGIN,
        MESHPRIVACY_MIN_APP_VERSION,
        EMAIL_2FA_LEGACY_CLIENTS_ALLOWED,
        SYNC_V2_DELTA_ENABLED,
        SYNC_V2_DELTA_TEST_ACCOUNTS,
    )
    from server_storage import ServerStorageMixin
    from server_auth import ServerAuthMixin
    from server_email_auth import ServerEmailAuthMixin
    from server_ai import ServerAiMixin
    from server_sync import ServerSyncMixin
    from server_push import ServerPushMixin
    from server_billing import ServerBillingMixin
    from server_boosty import ServerBoostyMixin
    from server_subscription import ServerSubscriptionMixin
    from server_scheduler import ServerSchedulerMixin
    from server_wireguard import ServerWireGuardMixin
    from server_protocol import (
        APP_VERSION,
        PROTOCOL_VERSION,
        MIN_SUPPORTED_PROTOCOL_VERSION,
        WEBSOCKET_MAX_SIZE,
        WEBSOCKET_PING_INTERVAL_SECONDS,
        WEBSOCKET_PING_TIMEOUT_SECONDS,
        SUPPORTED_SERVICES,
        ACCOUNT_LIVE_FANOUT_PACKET_TYPES,
        app_version_supported,
        protocol_compatibility,
        version_payload,
    )
    from server_transport import ServerTransportMixin
    from server_workers import ServerWorkerSupervisor
    from server_commands import (
        build_control_command_registry,
        build_command_registry,
    )
    from server_connection import (
        HandshakeConfig,
        handle_connection,
    )
    from persistence.sqlite_account_deletion import (
        build_sqlite_account_deletion_orchestrator,
    )


class MeshRelayServer(
    ServerTransportMixin,
    ServerStorageMixin,
    ServerAuthMixin,
    ServerEmailAuthMixin,
    ServerAiMixin,
    ServerSyncMixin,
    ServerPushMixin,
    ServerBillingMixin,
    ServerBoostyMixin,
    ServerWireGuardMixin,
    ServerSchedulerMixin,
    ServerSubscriptionMixin
):
    async def issue_email_challenge_async(
        self,
        login,
        node_id,
        email,
        purpose,
    ):
        challenge, code, reason = self.create_email_challenge(
            login,
            node_id,
            email,
            purpose,
        )
        if not challenge:
            return None, reason
        try:
            await asyncio.to_thread(
                self.send_email_verification_code,
                email,
                code,
                purpose,
            )
        except Exception as error:
            self.discard_email_challenge(challenge["challenge_id"])
            print(f"Email delivery failed for {login}: {error!r}")
            return None, "email_delivery_unavailable"
        return challenge, "ok"

    async def authorize_email_2fa(self, packet, login, password, node_id):
        if str(packet.get("service") or "").strip():
            return True, None, ""

        supports_email_2fa = bool(packet.get("supports_email_2fa", False))
        normalized_login = str(login or "").strip().lower()
        if not normalized_login or not password:
            return False, {
                "code": "authentication_failed",
                "message": "missing login or password",
            }, ""

        account_exists = self.account_exists(normalized_login)
        if account_exists and not self.verify_account_password(
            normalized_login,
            password,
        ):
            return False, {
                "code": "authentication_failed",
                "message": "bad login or password",
            }, ""

        if not supports_email_2fa and EMAIL_2FA_LEGACY_CLIENTS_ALLOWED:
            return True, None, ""

        verified_email = self.account_email(normalized_login)
        if account_exists and not verified_email:
            # Legacy accounts are allowed through once, but the new client
            # blocks the application behind the mandatory binding screen.
            return True, None, ""
        if account_exists and self.is_email_device_trusted(
            normalized_login,
            node_id,
        ):
            return True, None, verified_email
        if account_exists and verified_email and not supports_email_2fa:
            return False, {
                "code": "email_2fa_update_required",
                "message": "Update MeshChat to verify this device by email",
            }, ""
        if not account_exists and not supports_email_2fa:
            return False, {
                "code": "email_2fa_update_required",
                "message": "Update MeshChat to create an account with email verification",
            }, ""

        purpose = "login" if account_exists else "registration"
        target_email = verified_email or self.normalize_email(packet.get("email"))
        if not target_email:
            return False, {
                "code": "email_required",
                "message": "Email is required to create a MeshChat account",
            }, ""
        if not account_exists:
            with self.unit_of_work_factory() as unit_of_work:
                email_owner = unit_of_work.identity.email_owner(
                    target_email,
                )
            if email_owner:
                return False, {
                    "code": "email_already_used",
                    "message": "This email is already linked to another account",
                }, ""

        challenge_id = str(packet.get("email_challenge_id") or "").strip()
        code = str(packet.get("email_code") or "").strip()
        if challenge_id and code:
            ok, reason, challenge_email = self.verify_email_challenge(
                challenge_id,
                normalized_login,
                node_id,
                code,
                purpose,
            )
            if not ok:
                return False, {
                    "code": reason,
                    "message": "The email verification code is invalid or expired",
                }, ""
            if account_exists:
                self.trust_email_device(normalized_login, node_id)
            return True, None, challenge_email

        challenge, reason = await self.issue_email_challenge_async(
            normalized_login,
            node_id,
            target_email,
            purpose,
        )
        if not challenge:
            retry_after = 0
            if str(reason).startswith("retry_after:"):
                retry_after = int(str(reason).split(":", 1)[1] or 0)
            return False, {
                "code": reason.split(":", 1)[0],
                "message": (
                    "Wait before requesting another code"
                    if retry_after
                    else "Could not send the verification email"
                ),
                "retry_after": retry_after,
            }, ""
        return False, {
            "code": "email_verification_required",
            "message": "Enter the code sent to your email",
            **challenge,
        }, ""

    def sync_v2_delta_enabled_for(self, login):
        normalized_login = str(login or "").strip().lower()
        return bool(
            SYNC_V2_DELTA_ENABLED
            or (
                normalized_login
                and normalized_login in SYNC_V2_DELTA_TEST_ACCOUNTS
            )
        )

    def __init__(self):

        self.clients = {}
        self.client_names = {}
        self.client_logins = {}
        self.service_clients = {}
        self.service_logins = {}
        self.client_services = {}
        self.client_capabilities = {}
        self.file_chunks = {}
        self.db = self.open_db()
        self.account_deletion_orchestrator = (
            build_sqlite_account_deletion_orchestrator(
                self.db,
                self.atomic_storage_transaction,
                pending_path_factory=getattr(
                    self,
                    "_file_transfer_pending_path",
                    None,
                ),
            )
        )
        self.command_registry = build_command_registry()
        self.control_command_registry = build_control_command_registry()


    async def handler(
        self,
        websocket,
        path=None
    ):
        await handle_connection(
            self,
            websocket,
            HandshakeConfig(
                server_token=SERVER_TOKEN,
                require_login=REQUIRE_LOGIN,
                meshprivacy_min_app_version=MESHPRIVACY_MIN_APP_VERSION,
            ),
        )


async def main():

    relay = MeshRelayServer()
    workers = ServerWorkerSupervisor(relay)
    await workers.start()

    loop = asyncio.get_running_loop()

    for sig in (
        signal.SIGINT,
        signal.SIGTERM
    ):

        try:

            loop.add_signal_handler(
                sig,
                workers.stop_event.set
            )

        except NotImplementedError:

            pass

    try:
        async with websockets.serve(
            relay.handler,
            HOST,
            PORT,
            max_size=WEBSOCKET_MAX_SIZE,
            ping_interval=WEBSOCKET_PING_INTERVAL_SECONDS,
            ping_timeout=WEBSOCKET_PING_TIMEOUT_SECONDS
        ):

            print(
                f"Mesh relay server listening on ws://{HOST}:{PORT}"
            )

            print(
                "Protocol compatibility: "
                f"{MIN_SUPPORTED_PROTOCOL_VERSION}..{PROTOCOL_VERSION}"
            )

            if SYNC_V2_DELTA_ENABLED:
                sync_v2_delta_rollout = "global"
            elif SYNC_V2_DELTA_TEST_ACCOUNTS:
                sync_v2_delta_rollout = (
                    "canary "
                    f"({len(SYNC_V2_DELTA_TEST_ACCOUNTS)} accounts)"
                )
            else:
                sync_v2_delta_rollout = "disabled"
            print(f"Sync v2 delta rollout: {sync_v2_delta_rollout}")

            if SERVER_TOKEN:

                print(
                    "Server token auth: enabled"
                )

            else:

                print(
                    "Server token auth: disabled"
                )

            if REQUIRE_LOGIN:

                print(
                    "Login auth: required"
                )

            else:

                print(
                    "Login auth: optional"
                )

            if relay.web_push_enabled:

                print(
                    "Web Push: enabled"
                )

            else:

                print(
                    "Web Push: disabled"
                )

            print(
                "MeshPro billing HTTP: "
                + ("enabled" if workers.billing_started else "disabled")
            )

            print(
                "Boosty Telegram bridge: "
                + ("enabled" if workers.boosty_started else "disabled")
            )

            print(
                f"For ngrok/localtonet, expose local port {PORT} and use the wss:// URL in clients."
            )

            await workers.stop_event.wait()
    finally:
        await workers.stop()


if __name__ == "__main__":

    asyncio.run(
        main()
    )
