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
        EMAIL_2FA_CODE_TTL_SECONDS,
        SYNC_V2_DELTA_ENABLED,
        SYNC_V2_DELTA_TEST_ACCOUNTS,
        REDIS_URL,
        REDIS_PREFIX,
        REALTIME_PRESENCE_TTL_SECONDS,
        REALTIME_HEARTBEAT_SECONDS,
        WORKER_COUNT,
        WORKER_INDEX,
        WORKER_ID,
        SERVER_REUSE_PORT,
        RUN_AUXILIARY,
        CALL_SIGNALING_ENABLED,
        CALL_SIGNALING_STREAM_MAXLEN,
    )
    from server.server_storage import ServerStorageMixin
    from server.server_media import ServerMediaMixin
    from server.server_auth import ServerAuthMixin
    from server.server_email_auth import ServerEmailAuthMixin
    from server.server_ai import ServerAiMixin
    from server.server_sync import ServerSyncMixin
    from server.server_push import ServerPushMixin
    from server.server_billing import ServerBillingMixin
    from server.server_boosty import ServerBoostyMixin
    from server.server_subscription import ServerSubscriptionMixin
    from server.server_moderation import ServerModerationMixin
    from server.server_scheduler import ServerSchedulerMixin
    from server.server_polls import ServerPollsMixin
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
    from server.server_realtime import ServerRealtimeMixin
    from server.server_workers import ServerWorkerSupervisor
    from server.call_signaling import CallSignalingPublisher
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
        EMAIL_2FA_CODE_TTL_SECONDS,
        SYNC_V2_DELTA_ENABLED,
        SYNC_V2_DELTA_TEST_ACCOUNTS,
        REDIS_URL,
        REDIS_PREFIX,
        REALTIME_PRESENCE_TTL_SECONDS,
        REALTIME_HEARTBEAT_SECONDS,
        WORKER_COUNT,
        WORKER_INDEX,
        WORKER_ID,
        SERVER_REUSE_PORT,
        RUN_AUXILIARY,
        CALL_SIGNALING_ENABLED,
        CALL_SIGNALING_STREAM_MAXLEN,
    )
    from server_storage import ServerStorageMixin
    from server_media import ServerMediaMixin
    from server_auth import ServerAuthMixin
    from server_email_auth import ServerEmailAuthMixin
    from server_ai import ServerAiMixin
    from server_sync import ServerSyncMixin
    from server_push import ServerPushMixin
    from server_billing import ServerBillingMixin
    from server_boosty import ServerBoostyMixin
    from server_subscription import ServerSubscriptionMixin
    from server_moderation import ServerModerationMixin
    from server_scheduler import ServerSchedulerMixin
    from server_polls import ServerPollsMixin
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
    from server_realtime import ServerRealtimeMixin
    from server_workers import ServerWorkerSupervisor
    from call_signaling import CallSignalingPublisher
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
    ServerRealtimeMixin,
    ServerTransportMixin,
    ServerMediaMixin,
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
    ServerPollsMixin,
    ServerSubscriptionMixin,
    ServerModerationMixin
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
        registration_intent = packet.get("register_if_missing")
        if registration_intent is False and not account_exists:
            return False, {
                "code": "account_not_found",
                "message": "No account exists with this login",
            }, ""
        if registration_intent is True and account_exists:
            return False, {
                "code": "account_already_exists",
                "message": "This login is already registered",
            }, ""
        if account_exists and not await self.verify_account_password_async(
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
            response = {
                "code": reason.split(":", 1)[0],
                "message": (
                    "Wait before requesting another code"
                    if retry_after
                    else "Could not send the verification email"
                ),
                "retry_after": retry_after,
            }
            if retry_after:
                with self.unit_of_work_factory() as unit_of_work:
                    active = unit_of_work.identity.latest_active_email_challenge(
                        normalized_login,
                        node_id,
                        purpose,
                    )
                if active:
                    response.update(
                        {
                            "challenge_id": active["challenge_id"],
                            "masked_email": self.mask_email(active["email"]),
                            "purpose": purpose,
                            "expires_in": EMAIL_2FA_CODE_TTL_SECONDS,
                        }
                    )
            return False, response, ""
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
        self.client_sessions = {}
        self.service_sessions = {}
        self.file_chunks = {}
        self.initialize_realtime(
            redis_url=REDIS_URL,
            prefix=REDIS_PREFIX,
            worker_id=WORKER_ID,
            presence_ttl=REALTIME_PRESENCE_TTL_SECONDS,
            heartbeat_interval=REALTIME_HEARTBEAT_SECONDS,
        )
        self.call_signaling = CallSignalingPublisher(
            REDIS_URL,
            prefix=REDIS_PREFIX,
            enabled=CALL_SIGNALING_ENABLED,
            stream_maxlen=CALL_SIGNALING_STREAM_MAXLEN,
        )
        self.db = self.open_db()
        self.initialize_poll_storage()
        self.initialize_media_delivery()
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

    if WORKER_COUNT > 1 and not REDIS_URL:
        raise RuntimeError(
            "MESH_REDIS_URL is required when MESH_WORKER_COUNT is greater "
            "than one"
        )

    relay = MeshRelayServer()
    workers = ServerWorkerSupervisor(
        relay,
        run_auxiliary=RUN_AUXILIARY,
    )
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
        serve_options = {
            "max_size": WEBSOCKET_MAX_SIZE,
            "ping_interval": WEBSOCKET_PING_INTERVAL_SECONDS,
            "ping_timeout": WEBSOCKET_PING_TIMEOUT_SECONDS,
        }
        if SERVER_REUSE_PORT:
            serve_options["reuse_port"] = True
        async with websockets.serve(
            relay.handler,
            HOST,
            PORT,
            **serve_options,
        ):

            print(
                "Mesh relay server listening on "
                f"ws://{HOST}:{PORT} ({WORKER_ID}, "
                f"{WORKER_INDEX + 1}/{WORKER_COUNT})"
            )

            print(
                "Realtime coordination: "
                + ("Redis" if relay.realtime.enabled else "local")
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
                "Android Push: "
                + ("enabled" if relay.android_push_enabled else "disabled")
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
