import asyncio
import json
import re
import signal
import sys
import uuid
from pathlib import Path

import websockets

ROOT_DIR = Path(__file__).resolve().parents[1]

if str(ROOT_DIR) not in sys.path:
    sys.path.insert(0, str(ROOT_DIR))

try:
    from version import (
        APP_VERSION,
        PROTOCOL_VERSION,
        MIN_SUPPORTED_PROTOCOL_VERSION,
        protocol_compatibility,
        version_payload
    )
except ModuleNotFoundError:
    APP_VERSION = "unknown"
    PROTOCOL_VERSION = 1
    MIN_SUPPORTED_PROTOCOL_VERSION = 1

    def protocol_compatibility(peer_protocol, peer_min_protocol=None):
        return peer_protocol in (None, PROTOCOL_VERSION), "compatible"

    def version_payload():
        return {
            "server_version": APP_VERSION,
            "protocol_version": PROTOCOL_VERSION,
            "min_protocol_version": MIN_SUPPORTED_PROTOCOL_VERSION,
            "protocol_min_version": MIN_SUPPORTED_PROTOCOL_VERSION
        }

WEBSOCKET_MAX_SIZE = 16 * 1024 * 1024
WEBSOCKET_PING_INTERVAL_SECONDS = 30
WEBSOCKET_PING_TIMEOUT_SECONDS = 120
SUPPORTED_SERVICES = frozenset({"meshprivacy"})
ACCOUNT_LIVE_FANOUT_PACKET_TYPES = frozenset(
    {
        "chat_message",
        "message_edit",
        "message_delete",
        "chat_delete",
        "message_pin",
        "message_reaction",
        "group_message",
        "group_update",
        "group_member_leave",
        "group_delete",
        "group_message_edit",
        "group_message_delete",
        "group_pin",
        "group_reaction",
        "story_update",
        "story_reaction",
        "story_delete",
    }
)


def _version_tuple(value):
    match = re.match(r"^\s*(\d+)(?:\.(\d+))?(?:\.(\d+))?", str(value or ""))
    if not match:
        return None
    return tuple(int(part or 0) for part in match.groups())


def app_version_supported(value, minimum):
    if not minimum:
        return True
    current = _version_tuple(value)
    required = _version_tuple(minimum)
    return current is not None and required is not None and current >= required

try:
    from server.config import (
        HOST,
        PORT,
        SERVER_TOKEN,
        REQUIRE_LOGIN,
        MESHPRIVACY_MIN_APP_VERSION,
        SYNC_V2_DELTA_ENABLED,
        SYNC_V2_DELTA_TEST_ACCOUNTS,
    )
    from server.server_storage import ServerStorageMixin
    from server.server_auth import ServerAuthMixin
    from server.server_ai import ServerAiMixin
    from server.server_sync import ServerSyncMixin
    from server.server_push import ServerPushMixin
    from server.server_billing import BillingError, ServerBillingMixin
    from server.server_billing_http import BillingHttpServer
    from server.server_boosty import ServerBoostyMixin
    from server.server_subscription import ServerSubscriptionMixin
    from server.server_scheduler import ServerSchedulerMixin
    from server.server_wireguard import ServerWireGuardMixin
except ModuleNotFoundError:
    from config import (
        HOST,
        PORT,
        SERVER_TOKEN,
        REQUIRE_LOGIN,
        MESHPRIVACY_MIN_APP_VERSION,
        SYNC_V2_DELTA_ENABLED,
        SYNC_V2_DELTA_TEST_ACCOUNTS,
    )
    from server_storage import ServerStorageMixin
    from server_auth import ServerAuthMixin
    from server_ai import ServerAiMixin
    from server_sync import ServerSyncMixin
    from server_push import ServerPushMixin
    from server_billing import BillingError, ServerBillingMixin
    from server_billing_http import BillingHttpServer
    from server_boosty import ServerBoostyMixin
    from server_subscription import ServerSubscriptionMixin
    from server_scheduler import ServerSchedulerMixin
    from server_wireguard import ServerWireGuardMixin


class MeshRelayServer(
    ServerStorageMixin,
    ServerAuthMixin,
    ServerAiMixin,
    ServerSyncMixin,
    ServerPushMixin,
    ServerBillingMixin,
    ServerBoostyMixin,
    ServerWireGuardMixin,
    ServerSchedulerMixin,
    ServerSubscriptionMixin
):

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


    async def handler(
        self,
        websocket,
        path=None
    ):

        node_id = None

        try:

            async for raw_message in websocket:

                try:

                    packet = json.loads(
                        raw_message
                    )

                except json.JSONDecodeError:

                    continue

                if packet.get("type") == "server_hello":

                    compatible, reason = protocol_compatibility(
                        packet.get("protocol_version"),
                        packet.get("min_protocol_version")
                    )

                    if not compatible:

                        response = {
                            "type": "server_error",
                            "code": "incompatible_protocol",
                            "reason": reason,
                            "message": (
                                "Incompatible protocol versions. "
                                "Update MeshChat on the client or server."
                            ),
                            "client_protocol_version": packet.get("protocol_version"),
                            "client_min_protocol_version": packet.get("min_protocol_version"),
                            **version_payload()
                        }

                        await websocket.send(
                            json.dumps(
                                response,
                                ensure_ascii=False
                            )
                        )

                        await websocket.close(
                            code=1002,
                            reason="incompatible protocol"
                        )

                        return

                    if (
                        SERVER_TOKEN
                        and packet.get("server_token") != SERVER_TOKEN
                    ):

                        print(
                            "Client rejected: bad server token"
                        )

                        await websocket.close(
                            code=1008,
                            reason="bad server token"
                        )

                        return

                    node_id = packet.get(
                        "node_id"
                    )

                    username = packet.get(
                        "username"
                    ) or node_id

                    display_name = packet.get(
                        "display_name"
                    ) or username

                    if not node_id:
                        continue

                    login = packet.get(
                        "login"
                    )

                    password = packet.get(
                        "password"
                    )

                    auth_check = bool(
                        packet.get(
                            "auth_check"
                        )
                    )

                    service = str(
                        packet.get("service") or ""
                    ).strip().lower()

                    if service and service not in SUPPORTED_SERVICES:

                        await websocket.close(
                            code=1008,
                            reason="unsupported service"
                        )

                        return

                    if (
                        service == "meshprivacy"
                        and not app_version_supported(
                            packet.get("app_version"),
                            MESHPRIVACY_MIN_APP_VERSION,
                        )
                    ):

                        await websocket.send(
                            json.dumps(
                                {
                                    "type": "server_error",
                                    "code": "meshprivacy_update_required",
                                    "message": (
                                        "This MeshPrivacy version is retired. "
                                        f"Install version {MESHPRIVACY_MIN_APP_VERSION} or newer."
                                    ),
                                    "minimum_app_version": MESHPRIVACY_MIN_APP_VERSION,
                                },
                                ensure_ascii=False,
                            )
                        )

                        await websocket.close(
                            code=1008,
                            reason="MeshPrivacy update required",
                        )

                        return

                    service_session_token = str(
                        packet.get("service_session_token") or ""
                    ).strip()

                    issued_service_token = None

                    if service_session_token:

                        login = self.authenticate_service_session(
                            service_session_token,
                            service,
                            node_id
                        )

                        if not login:

                            await websocket.send(
                                json.dumps(
                                    {
                                        "type": "server_error",
                                        "code": "service_session_invalid",
                                        "message": "Service session expired or was revoked"
                                    },
                                    ensure_ascii=False
                                )
                            )

                            await websocket.close(
                                code=1008,
                                reason="service session expired"
                            )

                            return

                    elif (
                        REQUIRE_LOGIN
                        or login
                        or password
                        or service
                    ):

                        ok, reason = self.authenticate_account(
                            login,
                            password,
                            node_id,
                            display_name,
                            auth_check,
                            packet.get("public_username"),
                            packet.get("about"),
                            packet.get("avatar_data"),
                            packet.get("encryption_public_key"),
                            bool(packet.get("register_if_missing", True)),
                            bool(packet.get("reactivate_device", False))
                        )

                        if not ok:

                            if service:

                                await websocket.send(
                                    json.dumps(
                                        {
                                            "type": "server_error",
                                            "code": "authentication_failed",
                                            "message": reason
                                        },
                                        ensure_ascii=False
                                    )
                                )

                            print(
                                f"Client rejected: {reason}"
                            )

                            await websocket.close(
                                code=1008,
                                reason=reason
                            )

                            return

                        if service and not auth_check:

                            issued_service_token = self.create_service_session(
                                login,
                                service,
                                node_id
                            )

                    if auth_check:

                        await websocket.send(
                            json.dumps(
                        {
                            "type": "server_welcome",
                            "web_push_vapid_public_key": self.web_push_public_key(),
                            **version_payload()
                        },
                                ensure_ascii=False
                            )
                        )

                        return

                    if service:

                        normalized_login = login.strip().lower()

                        self.service_clients[node_id] = websocket
                        self.client_services[node_id] = service
                        self.service_logins[node_id] = normalized_login

                        welcome = {
                            "type": "server_welcome",
                            "service": service,
                            "login": normalized_login,
                            "subscription": self.subscription_status(
                                normalized_login,
                                service
                            ),
                            **version_payload()
                        }

                        if issued_service_token:
                            welcome["service_session_token"] = issued_service_token

                        await websocket.send(
                            json.dumps(welcome, ensure_ascii=False)
                        )

                        print(
                            f"Service online: {service}/{normalized_login} ({node_id})"
                        )

                        continue

                    self.clients[
                        node_id
                    ] = websocket

                    self.client_names[
                        node_id
                    ] = username

                    delta_enabled = self.sync_v2_delta_enabled_for(login)
                    self.client_capabilities[node_id] = {
                        "sync_v2": bool(packet.get("supports_sync_v2", False)),
                        "sync_v2_delta": bool(
                            packet.get("supports_sync_v2_delta", False)
                        ) and delta_enabled,
                        "sticker_library_chunks": bool(
                            packet.get("supports_sticker_library_chunks", False)
                        ),
                        "offline_packet_ack": bool(
                            packet.get("supports_offline_packet_ack", False)
                        ),
                        "mutation_ack": bool(
                            packet.get("supports_mutation_ack", False)
                        ),
                        "file_transfer_v2": bool(
                            packet.get("supports_file_transfer_v2", False)
                        ),
                        "account_live_fanout": bool(
                            packet.get("supports_account_live_fanout", False)
                        ),
                    }

                    if login:

                        normalized_login = login.strip().lower()

                        self.client_logins[
                            node_id
                        ] = normalized_login

                        self.save_account_device(
                            normalized_login,
                            node_id,
                            display_name,
                            packet.get("app_version"),
                            True,
                            packet.get("device_name")
                        )

                    welcome = {
                        "type": "server_welcome",
                        "web_push_vapid_public_key": self.web_push_public_key(),
                        "capabilities": {
                            "sync_v2": True,
                            "sync_v2_delta": delta_enabled,
                            "offline_packet_ack": True,
                            "mutation_ack": True,
                            "file_transfer_v2": True,
                            "account_live_fanout": True,
                        },
                        **version_payload()
                    }

                    if login:
                        welcome["subscription"] = self.subscription_status(
                            normalized_login,
                            "meshpro"
                        )

                    await websocket.send(
                        json.dumps(welcome, ensure_ascii=False)
                    )

                    print(
                        f"Client online: {username} ({node_id})"
                    )

                    if login:

                        await self.send_account_sync(
                            websocket,
                            login.strip().lower(),
                            node_id,
                            bool(
                                packet.get(
                                    "supports_sticker_library_chunks",
                                    False
                                )
                            ),
                            bool(packet.get("supports_sync_v2", False)),
                            bool(packet.get("supports_sync_v2_delta", False))
                            and delta_enabled,
                            packet.get("sync_cursor", 0),
                        )

                    await self.send_user_list()
                    await self.flush_offline_packets(
                        node_id,
                        websocket,
                        bool(
                            packet.get(
                                "supports_offline_packet_ack",
                                False
                            )
                        )
                    )

                    continue

                if not node_id:
                    continue

                packet_source = packet.get(
                    "source_node"
                )

                if (
                    packet_source
                    and packet_source != node_id
                ):

                    print(
                        "Rejected packet with forged source:",
                        node_id,
                        packet_source
                    )

                    continue

                is_service_connection = (
                    self.service_clients.get(node_id) is websocket
                )

                if (
                    not is_service_connection
                    and self.clients.get(node_id) is not websocket
                ):

                    await websocket.close(
                        code=1008,
                        reason="connection was replaced"
                    )

                    return

                if (
                    is_service_connection
                    and packet.get("type") not in {
                        "meshpro_catalog_request",
                        "subscription_status_request",
                        "subscription_checkout_request",
                        "vpn_config_request",
                        "service_logout"
                    }
                ):

                    await websocket.send(
                        json.dumps(
                            {
                                "type": "server_error",
                                "code": "unsupported_service_packet",
                                "message": "Packet is not available for this service"
                            },
                            ensure_ascii=False
                        )
                    )

                    continue

                if packet.get("type") == "offline_packet_ack":

                    self.acknowledge_offline_packet(
                        node_id,
                        packet.get("queue_id")
                    )
                    continue

                if packet.get("type") == "sync_v2_ack":

                    login = (
                        self.client_logins.get(node_id)
                        or self.get_login_by_node(node_id)
                        or ""
                    )
                    self.acknowledge_sync_v2_cursor(
                        login,
                        node_id,
                        packet.get("cursor")
                    )
                    continue

                if packet.get("type") == "sync_v2_snapshot_request":

                    login = (
                        self.client_logins.get(node_id)
                        or self.get_login_by_node(node_id)
                        or ""
                    )
                    capabilities = self.client_capabilities.get(node_id, {})
                    if login:
                        await self.send_account_sync(
                            websocket,
                            login,
                            node_id,
                            capabilities.get("sticker_library_chunks") is True,
                            capabilities.get("sync_v2") is True,
                            False,
                            0,
                        )
                    continue

                file_transfer_v2 = (
                    self.client_capabilities.get(node_id, {}).get(
                        "file_transfer_v2"
                    ) is True
                )
                if (
                    file_transfer_v2
                    and packet.get("type") == "file_transfer_cancel"
                ):
                    account_login = (
                        self.client_logins.get(node_id)
                        or self.get_login_by_node(node_id)
                        or f"@node:{node_id}"
                    )
                    cancelled = self.cancel_file_transfer(
                        account_login,
                        packet.get("transfer_id"),
                    )
                    await websocket.send(
                        json.dumps(
                            {
                                "type": "file_chunk_ack",
                                "ok": True,
                                "cancelled": cancelled,
                                "transfer_id": packet.get("transfer_id"),
                                "file_id": packet.get("file_id"),
                                "operation_id": packet.get("operation_id"),
                                "received_ranges": [],
                                "complete": False,
                                **version_payload(),
                            },
                            ensure_ascii=False,
                        )
                    )
                    continue

                if (
                    file_transfer_v2
                    and packet.get("type") == "file_chunk"
                    and packet.get("file_transfer_v2") is True
                ):
                    packet["source_node"] = node_id
                    account_login = (
                        self.client_logins.get(node_id)
                        or self.get_login_by_node(node_id)
                        or f"@node:{node_id}"
                    )
                    transfer_result = self.save_file_transfer_chunk(
                        packet,
                        account_login,
                    )
                    await self.send_file_transfer_ack(
                        websocket,
                        packet,
                        transfer_result,
                    )
                    if transfer_result.get("newly_completed") is True:
                        await self.deliver_completed_file_transfer(
                            transfer_result
                        )
                    continue

                mutation_context = self.mutation_ack_context(
                    node_id,
                    packet
                )
                if (
                    mutation_context
                    and self.mutation_was_processed(
                        mutation_context["account_login"],
                        mutation_context["outbox_id"]
                    )
                ):
                    await self.send_mutation_ack(
                        websocket,
                        packet,
                        mutation_context,
                        duplicate=True
                    )
                    continue

                if packet.get("type") == "meshpro_catalog_request":

                    product = str(
                        packet.get("product") or "meshpro"
                    ).strip().lower()
                    catalog = self.subscription_catalog(product)

                    await websocket.send(
                        json.dumps(
                            {
                                "type": "meshpro_catalog_result",
                                "ok": catalog is not None,
                                "catalog": catalog,
                                "error": (
                                    None
                                    if catalog is not None
                                    else "unsupported_product"
                                ),
                            },
                            ensure_ascii=False,
                        )
                    )

                    continue

                if packet.get("type") == "push_subscribe":

                    self.save_web_push_subscription(
                        self.client_logins.get(node_id)
                        or self.get_login_by_node(node_id),
                        node_id,
                        packet.get("subscription"),
                        packet.get("user_agent") or ""
                    )

                    await websocket.send(
                        json.dumps(
                            {
                                "type": "push_subscribe_result",
                                "ok": True
                            },
                            ensure_ascii=False
                        )
                    )

                    continue

                if packet.get("type") == "fcm_subscribe":

                    self.save_android_push_token(
                        self.client_logins.get(node_id)
                        or self.get_login_by_node(node_id),
                        node_id,
                        packet.get("token")
                    )

                    await websocket.send(
                        json.dumps(
                            {
                                "type": "fcm_subscribe_result",
                                "ok": True
                            },
                            ensure_ascii=False
                        )
                    )

                    continue

                if packet.get("type") == "subscription_status_request":

                    authenticated_login = (
                        self.service_logins.get(node_id)
                        if is_service_connection
                        else self.client_logins.get(node_id)
                    )
                    product = str(
                        packet.get("product") or "meshpro"
                    ).strip().lower()

                    await websocket.send(
                        json.dumps(
                            {
                                "type": "subscription_status_result",
                                "ok": bool(authenticated_login),
                                "subscription": self.subscription_status(
                                    authenticated_login,
                                    product
                                ) if authenticated_login else None
                            },
                            ensure_ascii=False
                        )
                    )

                    continue

                if packet.get("type") == "ai_text_rewrite_request":

                    authenticated_login = self.client_logins.get(node_id)
                    result = await self.rewrite_text_with_ai(
                        authenticated_login,
                        packet.get("text"),
                        packet.get("style"),
                    )

                    await websocket.send(
                        json.dumps(
                            {
                                "type": "ai_text_rewrite_result",
                                "request_id": packet.get("request_id"),
                                **result,
                            },
                            ensure_ascii=False,
                        )
                    )

                    continue

                if packet.get("type") == "ai_message_translation_request":

                    authenticated_login = self.client_logins.get(node_id)
                    result = await self.translate_message_with_ai(
                        authenticated_login,
                        packet.get("text"),
                        packet.get("target_language"),
                    )

                    await websocket.send(
                        json.dumps(
                            {
                                "type": "ai_message_translation_result",
                                "request_id": packet.get("request_id"),
                                **result,
                            },
                            ensure_ascii=False,
                        )
                    )

                    continue

                if packet.get("type") == "ai_chat_summary_request":

                    authenticated_login = self.client_logins.get(node_id)
                    result = await self.summarize_chat_with_ai(
                        authenticated_login,
                        packet.get("messages"),
                    )

                    await websocket.send(
                        json.dumps(
                            {
                                "type": "ai_chat_summary_result",
                                "request_id": packet.get("request_id"),
                                **result,
                            },
                            ensure_ascii=False,
                        )
                    )

                    continue

                if packet.get("type") == "ai_voice_transcription_request":

                    authenticated_login = self.client_logins.get(node_id)
                    result = await self.transcribe_voice_with_ai(
                        authenticated_login,
                        packet.get("message_id"),
                        packet.get("filename"),
                        packet.get("audio_base64"),
                        packet.get("duration_seconds"),
                    )

                    await websocket.send(
                        json.dumps(
                            {
                                "type": "ai_voice_transcription_result",
                                "request_id": packet.get("request_id"),
                                "message_id": packet.get("message_id"),
                                **result,
                            },
                            ensure_ascii=False,
                        )
                    )

                    continue

                if packet.get("type") == "ai_image_ocr_request":

                    authenticated_login = self.client_logins.get(node_id)
                    result = await self.extract_image_text_with_ai(
                        authenticated_login,
                        packet.get("message_id"),
                        packet.get("filename"),
                        packet.get("image_base64"),
                    )

                    await websocket.send(
                        json.dumps(
                            {
                                "type": "ai_image_ocr_result",
                                "request_id": packet.get("request_id"),
                                "message_id": packet.get("message_id"),
                                **result,
                            },
                            ensure_ascii=False,
                        )
                    )

                    continue

                if packet.get("type") == "ai_smart_replies_request":

                    authenticated_login = self.client_logins.get(node_id)
                    result = await self.suggest_replies_with_ai(
                        authenticated_login,
                        packet.get("messages"),
                    )

                    await websocket.send(
                        json.dumps(
                            {
                                "type": "ai_smart_replies_result",
                                "request_id": packet.get("request_id"),
                                **result,
                            },
                            ensure_ascii=False,
                        )
                    )

                    continue

                if packet.get("type") == "subscription_checkout_request":

                    is_meshprivacy = (
                        self.service_clients.get(node_id) is websocket
                        and self.client_services.get(node_id) == "meshprivacy"
                    )
                    authenticated_login = (
                        self.service_logins.get(node_id)
                        if is_meshprivacy
                        else None
                    )
                    result = None
                    error = "unauthorized_service"
                    if authenticated_login:
                        try:
                            result = await self.create_subscription_checkout(
                                authenticated_login,
                                node_id,
                                packet.get("client_request_id"),
                                packet.get("product") or "meshpro",
                                packet.get("plan_code") or "monthly",
                                buyer_email=packet.get("email"),
                            )
                            error = None
                        except BillingError as billing_error:
                            error = str(billing_error)
                        except Exception as checkout_error:
                            print(
                                "Subscription checkout failed:",
                                authenticated_login,
                                checkout_error,
                            )
                            error = "checkout_failed"

                    await websocket.send(
                        json.dumps(
                            {
                                "type": "subscription_checkout_result",
                                "ok": bool(result),
                                "error": error,
                                "checkout": result,
                            },
                            ensure_ascii=False,
                        )
                    )

                    continue

                if packet.get("type") == "vpn_config_request":

                    is_meshprivacy = (
                        self.service_clients.get(node_id) is websocket
                        and self.client_services.get(node_id) == "meshprivacy"
                    )
                    authenticated_login = (
                        self.service_logins.get(node_id)
                        if is_meshprivacy
                        else None
                    )

                    config = None
                    subscription = None
                    reason = "unauthorized_service"

                    if authenticated_login and is_meshprivacy:
                        config, subscription, reason = self.vpn_config_for(
                            authenticated_login,
                            node_id,
                        )

                    await websocket.send(
                        json.dumps(
                            {
                                "type": "vpn_config_result",
                                "ok": bool(config),
                                "reason": reason,
                                "config": config,
                                "subscription": subscription
                            },
                            ensure_ascii=False
                        )
                    )

                    continue

                if packet.get("type") == "service_logout":

                    if is_service_connection:

                        service_name = self.client_services.get(node_id)
                        service_login = self.service_logins.get(node_id)

                        self.revoke_service_session(
                            packet.get("service_session_token"),
                            service_name
                        )

                        if service_name == "meshprivacy" and service_login:
                            self.revoke_wireguard_peers(
                                service_login,
                                "meshpro",
                                node_id,
                            )

                    await websocket.send(
                        json.dumps(
                            {
                                "type": "service_logout_result",
                                "ok": True
                            },
                            ensure_ascii=False
                        )
                    )

                    continue

                if packet.get("type") == "push_unsubscribe":

                    self.delete_web_push_subscription(
                        endpoint=packet.get("endpoint"),
                        node_id=node_id if not packet.get("endpoint") else None
                    )

                    await websocket.send(
                        json.dumps(
                            {
                                "type": "push_unsubscribe_result",
                                "ok": True
                            },
                            ensure_ascii=False
                        )
                    )

                    continue

                if packet.get("type") == "username_lookup":

                    profile = self.find_account_by_public_username(
                        packet.get("username")
                    )

                    await websocket.send(
                        json.dumps(
                            {
                                "type": "username_lookup_result",
                                "ok": bool(profile),
                                "username": packet.get("username"),
                                "profile": profile
                            },
                            ensure_ascii=False
                        )
                    )

                    continue

                if packet.get("type") == "profile_update":

                    ok, reason = self.save_account_profile(
                        packet.get("login"),
                        packet.get("source_node"),
                        packet.get("display_name"),
                        packet.get("public_username"),
                        packet.get("about"),
                        packet.get("avatar_data"),
                        packet.get("encryption_public_key"),
                        packet.get("profile_background"),
                        packet.get("profile_effect"),
                        packet.get("profile_blink_shape"),
                        packet.get("avatar_decoration"),
                        packet.get("profile_glow"),
                        packet.get("profile_accent"),
                        packet.get("emoji_status")
                    )

                    await websocket.send(
                        json.dumps(
                            {
                                "type": "profile_update_result",
                                "ok": ok,
                                "reason": reason,
                                "public_username": packet.get("public_username")
                            },
                            ensure_ascii=False
                        )
                    )

                    if ok:

                        await self.send_user_list()

                    continue

                if packet.get("type") == "active_devices_request":

                    login_for_devices = (
                        self.client_logins.get(node_id)
                        or self.get_login_by_node(node_id)
                    )

                    await websocket.send(
                        json.dumps(
                            {
                                "type": "active_devices",
                                "devices": self.get_account_devices(
                                    login_for_devices
                                )
                            },
                            ensure_ascii=False
                        )
                    )

                    continue

                if not self.authorize_group_management(
                    packet
                ):

                    print(
                        "Rejected unauthorized group management:",
                        packet.get("type"),
                        packet.get("group_id"),
                        node_id
                    )

                    if mutation_context:
                        await self.send_mutation_ack(
                            websocket,
                            packet,
                            mutation_context,
                            ok=False,
                            reason="unauthorized_group_management"
                        )

                    continue

                if packet.get("type") == "active_device_action_request":

                    device_login = (
                        self.client_logins.get(node_id)
                        or self.get_login_by_node(node_id)
                        or ""
                    )
                    target_node = str(
                        packet.get("target_node") or ""
                    ).strip()
                    action = str(packet.get("action") or "").strip().lower()

                    if action == "revoke" and target_node == node_id:
                        ok, reason = False, "cannot_revoke_current_device"
                    else:
                        ok, reason = self.update_account_device(
                            device_login,
                            target_node,
                            action,
                            packet.get("device_name"),
                        )

                    await websocket.send(
                        json.dumps(
                            {
                                "type": "active_device_action_result",
                                "request_id": packet.get("request_id"),
                                "ok": ok,
                                "reason": reason,
                                "devices": self.get_account_devices(
                                    device_login
                                ),
                            },
                            ensure_ascii=False,
                        )
                    )

                    if ok and action == "revoke":
                        target_socket = self.clients.get(target_node)
                        if target_socket:
                            try:
                                await target_socket.send(
                                    json.dumps(
                                        {
                                            "type": "server_error",
                                            "code": "device_revoked",
                                            "message": (
                                                "This device session was revoked "
                                                "from another signed-in device."
                                            ),
                                        },
                                        ensure_ascii=False,
                                    )
                                )
                                await target_socket.close(
                                    code=4003,
                                    reason="device session revoked",
                                )
                            except Exception as revoke_error:
                                print(
                                    "Device session close failed:",
                                    target_node,
                                    revoke_error,
                                )

                    continue

                if packet.get("type") == "meshpro_preferences_update":

                    preference_login = (
                        self.client_logins.get(node_id)
                        or self.get_login_by_node(node_id)
                        or ""
                    )
                    ok, reason = self.save_meshpro_preferences(
                        preference_login,
                        packet.get("quick_reactions"),
                        packet.get("hd_audio") is True,
                        packet.get("enhanced_noise_suppression") is True,
                    )
                    preferences = self.get_meshpro_preferences(
                        preference_login
                    )
                    if ok:
                        self.invalidate_sync_v2_snapshot(
                            preference_login,
                            "meshpro_preferences_changed",
                            packet.get("operation_id")
                            or packet.get("request_id")
                            or str(uuid.uuid4()),
                        )
                    await websocket.send(
                        json.dumps(
                            {
                                "type": "meshpro_preferences_result",
                                "request_id": packet.get("request_id"),
                                "ok": ok,
                                "reason": reason,
                                "preferences": preferences,
                            },
                            ensure_ascii=False,
                        )
                    )

                    if ok:
                        update_packet = json.dumps(
                            {
                                "type": "meshpro_preferences_changed",
                                "preferences": preferences,
                            },
                            ensure_ascii=False,
                        )
                        for account_node in self.get_online_account_nodes(
                            preference_login
                        ):
                            if account_node == node_id:
                                continue
                            account_socket = self.clients.get(account_node)
                            if account_socket:
                                await account_socket.send(update_packet)

                    continue

                if packet.get("type") == "fcm_unsubscribe":

                    self.delete_android_push_token(
                        token=packet.get("token"),
                        node_id=(
                            node_id
                            if not packet.get("token")
                            else None
                        )
                    )

                    await websocket.send(
                        json.dumps(
                            {
                                "type": "fcm_unsubscribe_result",
                                "ok": True
                            },
                            ensure_ascii=False
                        )
                    )

                    continue

                if packet.get("type") == "chat_preferences_update":

                    preference_login = (
                        self.client_logins.get(node_id)
                        or self.get_login_by_node(node_id)
                        or ""
                    )
                    ok, reason = self.save_chat_preferences(
                        preference_login,
                        packet.get("chat_key"),
                        packet.get("theme_id"),
                        packet.get("bubble_style"),
                        packet.get("animated_background") is True
                    )
                    if ok:
                        self.invalidate_sync_v2_snapshot(
                            preference_login,
                            "chat_preferences_changed",
                            packet.get("operation_id")
                            or packet.get("request_id")
                            or str(uuid.uuid4()),
                            {"chat_key": packet.get("chat_key")},
                        )
                    await websocket.send(
                        json.dumps(
                            {
                                "type": "chat_preferences_result",
                                "ok": ok,
                                "reason": reason,
                                "chat_key": packet.get("chat_key")
                            },
                            ensure_ascii=False
                        )
                    )
                    continue

                if packet.get("type") == "scheduled_message_create":

                    ok, reason, item = self.create_scheduled_message(
                        node_id,
                        packet
                    )
                    await websocket.send(
                        json.dumps(
                            {
                                "type": "scheduled_message_result",
                                "action": "create",
                                "request_id": packet.get("request_id"),
                                "ok": ok,
                                "reason": reason,
                                "item": item
                            },
                            ensure_ascii=False
                        )
                    )
                    continue

                if packet.get("type") == "scheduled_message_cancel":

                    schedule_id = packet.get("schedule_id")
                    ok = self.cancel_scheduled_message(
                        node_id,
                        schedule_id
                    )
                    await websocket.send(
                        json.dumps(
                            {
                                "type": "scheduled_message_result",
                                "action": "cancel",
                                "request_id": packet.get("request_id"),
                                "ok": ok,
                                "reason": "ok" if ok else "not_found",
                                "schedule_id": schedule_id
                            },
                            ensure_ascii=False
                        )
                    )
                    continue

                if packet.get("type") == "scheduled_messages_request":

                    schedule_login = (
                        self.client_logins.get(node_id)
                        or self.get_login_by_node(node_id)
                        or ""
                    )
                    await websocket.send(
                        json.dumps(
                            {
                                "type": "scheduled_messages",
                                "items": self.list_scheduled_messages(
                                    schedule_login
                                )
                            },
                            ensure_ascii=False
                        )
                    )
                    continue

                group_delete_targets = (
                    self.get_group_delivery_nodes(packet.get("group_id"))
                    if packet.get("type") == "group_delete"
                    else []
                )

                source_login = str(
                    self.client_logins.get(node_id)
                    or self.get_login_by_node(node_id)
                    or ""
                ).strip().lower()
                destination_login = str(
                    self.get_login_by_node(packet.get("destination_node"))
                    or ""
                ).strip().lower()
                if source_login:
                    packet["sender_login"] = source_login
                    if packet.get("type") in {
                        "message_reaction",
                        "group_reaction",
                        "story_reaction",
                    }:
                        packet["reactor_login"] = source_login
                        packet["reactor_identity"] = f"login:{source_login}"
                if destination_login:
                    packet["receiver_login"] = destination_login

                sync_event_accounts = self.sync_v2_accounts_for_packet(
                    packet,
                    group_delete_targets
                )

                mutation_result = self.persist_history_mutation(
                    packet,
                    sync_event_accounts,
                    mutation_context,
                )
                saved = mutation_result["saved"]

                if saved == "duplicate":
                    if mutation_context:
                        await self.send_mutation_ack(
                            websocket,
                            packet,
                            mutation_context,
                            duplicate=True
                        )
                    continue

                if saved is False:
                    if mutation_context:
                        await self.send_mutation_ack(
                            websocket,
                            packet,
                            mutation_context,
                            ok=False,
                            reason="rejected"
                        )
                    continue

                if mutation_context:
                    inserted = mutation_result["processed_inserted"]
                    await self.send_mutation_ack(
                        websocket,
                        packet,
                        mutation_context,
                        duplicate=not inserted
                    )

                await self.mirror_packet_to_source_account_devices(packet)

                if packet.get("type") == "group_delete":
                    source_node = packet.get("source_node") or ""
                    for target_node in group_delete_targets:
                        if not target_node or target_node == source_node:
                            continue
                        await self.route_packet(
                            {
                                **packet,
                                "packet_id": str(uuid.uuid4()),
                                "destination_node": target_node
                            }
                        )
                    continue

                await self.route_packet(
                    packet
                )

        finally:

            if (
                node_id
                and self.service_clients.get(node_id) is websocket
            ):

                service = self.client_services.pop(node_id, None)
                login = self.service_logins.pop(node_id, None)
                self.service_clients.pop(node_id, None)

                print(
                    f"Service offline: {service}/{login} ({node_id})"
                )

            if (
                node_id
                and self.clients.get(
                    node_id
                ) is websocket
            ):

                self.clients.pop(
                    node_id,
                    None
                )

                self.client_names.pop(
                    node_id,
                    None
                )

                self.client_capabilities.pop(
                    node_id,
                    None
                )

                login = self.client_logins.pop(
                    node_id,
                    None
                )

                if login:

                    self.set_account_device_online(
                        login,
                        node_id,
                        False
                    )

                print(
                    f"Client offline: {node_id}"
                )

                await self.send_user_list()

    def mutation_ack_context(self, node_id, packet):

        capabilities = self.client_capabilities.get(node_id) or {}
        if capabilities.get("mutation_ack") is not True:
            return None

        outbox_id = str(packet.get("outbox_id") or "").strip()
        operation_id = str(packet.get("operation_id") or "").strip()
        if not outbox_id or not operation_id:
            return None

        account_login = str(
            self.client_logins.get(node_id)
            or self.get_login_by_node(node_id)
            or f"@node:{node_id}"
        ).strip().lower()
        if not account_login:
            return None

        return {
            "account_login": account_login,
            "outbox_id": outbox_id,
            "operation_id": operation_id,
        }

    async def send_mutation_ack(
        self,
        websocket,
        packet,
        context,
        ok=True,
        duplicate=False,
        reason=""
    ):

        response = {
            "type": "mutation_ack",
            "ok": bool(ok),
            "duplicate": bool(duplicate),
            "outbox_id": context["outbox_id"],
            "operation_id": context["operation_id"],
            "packet_type": packet.get("type"),
            "packet_id": (
                packet.get("packet_id")
                or packet.get("group_message_id")
                or packet.get("message_id")
                or packet.get("story_id")
                or ""
            ),
            **version_payload()
        }
        if reason:
            response["reason"] = reason
        await websocket.send(
            json.dumps(response, ensure_ascii=False)
        )

    async def send_file_transfer_ack(
        self,
        websocket,
        packet,
        transfer_result,
    ):

        response = {
            "type": "file_chunk_ack",
            "ok": transfer_result.get("ok") is True,
            "transfer_id": transfer_result.get("transfer_id") or "",
            "operation_id": packet.get("operation_id") or "",
            "file_id": transfer_result.get("file_id") or "",
            "chunk_index": transfer_result.get("chunk_index"),
            "received_ranges": transfer_result.get("received_ranges") or [],
            "complete": transfer_result.get("complete") is True,
            "retryable": transfer_result.get("retryable") is True,
            "reset": transfer_result.get("reset") is True,
            **version_payload(),
        }
        reason = str(transfer_result.get("reason") or "").strip()
        if reason:
            response["reason"] = reason
        await websocket.send(json.dumps(response, ensure_ascii=False))

    async def deliver_completed_file_transfer(self, transfer_result):

        metadata = transfer_result.get("metadata") or {}
        destination_node = str(
            metadata.get("destination_node") or ""
        ).strip()
        if not destination_node or destination_node.upper() == "SERVER":
            return
        destination_socket = self.clients.get(destination_node)
        if not destination_socket:
            return
        try:
            for delivery_packet in self.iter_file_transfer_delivery_packets(
                transfer_result
            ):
                await destination_socket.send(
                    json.dumps(delivery_packet, ensure_ascii=False)
                )
        except (OSError, websockets.exceptions.ConnectionClosed) as error:
            print(
                "Deferred durable file delivery:",
                transfer_result.get("file_id"),
                destination_node,
                error,
            )

    async def route_packet(
        self,
        packet
    ):

        destination_node = packet.get(
            "destination_node"
        )

        if not destination_node:
            return

        if str(destination_node).strip().upper() == "SERVER":
            return

        is_call_packet = str(packet.get("type") or "").startswith("call_")

        if not is_call_packet:
            destination_login = str(
                self.get_login_by_node(destination_node) or ""
            ).strip().lower()
            target_nodes = [str(destination_node)]
            if destination_login:
                target_nodes.extend(
                    self.get_online_account_nodes(destination_login)
                )

            delivered = False
            delivered_nodes = set()
            for target_node in target_nodes:
                if not target_node or target_node in delivered_nodes:
                    continue
                target_socket = self.clients.get(target_node)
                if not target_socket:
                    continue
                routed_packet = packet
                if target_node != destination_node:
                    routed_packet = {
                        **packet,
                        "destination_node": target_node,
                        "original_destination_node": destination_node,
                    }
                await target_socket.send(
                    json.dumps(routed_packet, ensure_ascii=False)
                )
                delivered_nodes.add(target_node)
                delivered = True

            if delivered:
                return

            self.save_offline_packet(
                destination_node,
                packet
            )

            await self.send_web_push_for_packet(
                destination_node,
                packet
            )

            return

        websocket = self.clients.get(
            destination_node
        )

        if websocket:

            await websocket.send(
                json.dumps(
                    packet,
                    ensure_ascii=False
                )
            )

        if is_call_packet:
            source_node = packet.get("source_node") or ""
            login = self.get_login_by_node(destination_node)
            if login:
                delivered = False
                for node_id in self.get_online_account_nodes(login):
                    if node_id == source_node or node_id == destination_node:
                        continue
                    websocket = self.clients.get(node_id)
                    if not websocket:
                        continue
                    await websocket.send(
                        json.dumps(
                            {
                                **packet,
                                "destination_node": node_id,
                                "original_destination_node": destination_node
                            },
                            ensure_ascii=False
                        )
                    )
                    delivered = True
                if delivered:
                    return

            await self.send_web_push_for_packet(
                destination_node,
                packet
            )

            return

    async def mirror_packet_to_source_account_devices(self, packet):

        if str(packet.get("type") or "") not in ACCOUNT_LIVE_FANOUT_PACKET_TYPES:
            return

        source_node = str(packet.get("source_node") or "").strip()
        if not source_node:
            return

        source_login = str(
            packet.get("sender_login")
            or self.client_logins.get(source_node)
            or self.get_login_by_node(source_node)
            or ""
        ).strip().lower()
        if not source_login:
            return

        original_destination = packet.get("destination_node")
        for target_node in self.get_online_account_nodes(source_login):
            if not target_node or target_node == source_node:
                continue
            if not self.client_capabilities.get(target_node, {}).get(
                "account_live_fanout", False
            ):
                continue
            target_socket = self.clients.get(target_node)
            if not target_socket:
                continue
            await target_socket.send(
                json.dumps(
                    {
                        **packet,
                        "account_mirror": True,
                        "original_destination_node": original_destination,
                    },
                    ensure_ascii=False,
                )
            )


async def main():

    relay = MeshRelayServer()

    stop_event = asyncio.Event()

    boosty_started = await relay.start_boosty_bridge()
    billing_http = BillingHttpServer(relay)
    billing_started = await billing_http.start()
    try:
        wireguard_stats = relay.reconcile_wireguard_peers()
        print(f"WireGuard peer reconcile: {wireguard_stats}")
    except Exception as wireguard_error:
        print(f"WireGuard peer reconcile failed: {wireguard_error}")

    async def wireguard_maintenance():
        while not stop_event.is_set():
            try:
                await asyncio.wait_for(stop_event.wait(), timeout=60)
            except asyncio.TimeoutError:
                try:
                    relay.reconcile_wireguard_peers()
                except Exception as maintenance_error:
                    print(
                        "WireGuard maintenance failed:",
                        maintenance_error,
                    )

    async def scheduled_message_maintenance():
        while not stop_event.is_set():
            try:
                await relay.dispatch_due_scheduled_messages()
            except Exception as maintenance_error:
                print(
                    "Scheduled message maintenance failed:",
                    maintenance_error,
                )
            try:
                await asyncio.wait_for(stop_event.wait(), timeout=1)
            except asyncio.TimeoutError:
                pass

    wireguard_task = asyncio.create_task(wireguard_maintenance())
    scheduled_message_task = asyncio.create_task(
        scheduled_message_maintenance()
    )

    loop = asyncio.get_running_loop()

    for sig in (
        signal.SIGINT,
        signal.SIGTERM
    ):

        try:

            loop.add_signal_handler(
                sig,
                stop_event.set
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
                + ("enabled" if billing_started else "disabled")
            )

            print(
                "Boosty Telegram bridge: "
                + ("enabled" if boosty_started else "disabled")
            )

            print(
                f"For ngrok/localtonet, expose local port {PORT} and use the wss:// URL in clients."
            )

            await stop_event.wait()
    finally:
        stop_event.set()
        wireguard_task.cancel()
        scheduled_message_task.cancel()
        await asyncio.gather(
            wireguard_task,
            scheduled_message_task,
            return_exceptions=True
        )
        await billing_http.close()
        await relay.stop_boosty_bridge()


if __name__ == "__main__":

    asyncio.run(
        main()
    )
