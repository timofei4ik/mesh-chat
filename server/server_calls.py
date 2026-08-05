"""Call signaling and short-lived TURN credential delivery."""

import base64
import hashlib
import hmac
import json
import time
from collections import OrderedDict

try:
    from server.config import (
        TURN_CREDENTIAL_TTL_SECONDS,
        TURN_SHARED_SECRET,
        TURN_STUN_URLS,
        TURN_URLS,
        CALL_SFU_API_KEY,
        CALL_SFU_API_SECRET,
        CALL_SFU_ENABLED,
        CALL_SFU_REQUIRE_E2EE,
        CALL_SFU_TOKEN_TTL_SECONDS,
        CALL_SFU_URL,
    )
    from server.call_access import (
        build_livekit_access_token,
        private_room_name,
        sfu_is_configured,
    )
    from server.server_command_bus import account_login, send_json
except ModuleNotFoundError:
    from config import (
        TURN_CREDENTIAL_TTL_SECONDS,
        TURN_SHARED_SECRET,
        TURN_STUN_URLS,
        TURN_URLS,
        CALL_SFU_API_KEY,
        CALL_SFU_API_SECRET,
        CALL_SFU_ENABLED,
        CALL_SFU_REQUIRE_E2EE,
        CALL_SFU_TOKEN_TTL_SECONDS,
        CALL_SFU_URL,
    )
    from call_access import (
        build_livekit_access_token,
        private_room_name,
        sfu_is_configured,
    )
    from server_command_bus import account_login, send_json


CALL_SIGNAL_PACKET_TYPES = frozenset(
    {
        "call_offer",
        "call_answer",
        "call_ice",
        "call_end",
        "call_restart_offer",
        "call_restart_answer",
        "call_screen_offer",
        "call_screen_answer",
        "call_screen_stop",
    }
)

_SEEN_OPERATION_TTL_SECONDS = 5 * 60
_SEEN_OPERATION_LIMIT = 4096
_seen_operations = OrderedDict()

_MAX_CALL_ID_LENGTH = 128
_MAX_NODE_ID_LENGTH = 256
_MAX_OPERATION_ID_LENGTH = 256
_MAX_SDP_LENGTH = 2 * 1024 * 1024
_MAX_ICE_CANDIDATE_LENGTH = 16 * 1024


def _claim_operation(operation_id, now=None):
    if not operation_id:
        return True
    current = float(time.time() if now is None else now)
    while _seen_operations:
        _, created_at = next(iter(_seen_operations.items()))
        if current - created_at <= _SEEN_OPERATION_TTL_SECONDS:
            break
        _seen_operations.popitem(last=False)
    if operation_id in _seen_operations:
        return False
    _seen_operations[operation_id] = current
    while len(_seen_operations) > _SEEN_OPERATION_LIMIT:
        _seen_operations.popitem(last=False)
    return True


def is_call_signal_packet(packet):
    return str(packet.get("type") or "") in CALL_SIGNAL_PACKET_TYPES


def _valid_identifier(value, maximum):
    return bool(value) and len(value) <= maximum and all(
        character.isprintable() and character not in "\r\n\0"
        for character in value
    )


def validate_call_signal(packet):
    destination = str(packet.get("destination_node") or "").strip()
    call_id = str(packet.get("call_id") or "").strip()
    operation_id = str(packet.get("operation_id") or "").strip()
    if not _valid_identifier(destination, _MAX_NODE_ID_LENGTH):
        return "Invalid destination_node"
    if not _valid_identifier(call_id, _MAX_CALL_ID_LENGTH):
        return "Invalid call_id"
    if operation_id and not _valid_identifier(
        operation_id,
        _MAX_OPERATION_ID_LENGTH,
    ):
        return "Invalid operation_id"
    sdp = packet.get("sdp")
    if sdp is not None and (
        not isinstance(sdp, str) or len(sdp) > _MAX_SDP_LENGTH
    ):
        return "Invalid or oversized SDP"
    candidate = packet.get("candidate")
    if candidate is not None and len(
        json.dumps(candidate, separators=(",", ":"), ensure_ascii=False)
    ) > _MAX_ICE_CANDIDATE_LENGTH:
        return "Invalid or oversized ICE candidate"
    return ""


def build_ice_servers(login, node_id, now=None):
    servers = [{"urls": url} for url in TURN_STUN_URLS]
    if not TURN_SHARED_SECRET or not TURN_URLS:
        return servers

    expires_at = int(now if now is not None else time.time())
    expires_at += TURN_CREDENTIAL_TTL_SECONDS
    identity = str(login or node_id or "meshchat").replace(":", "_")
    username = f"{expires_at}:{identity}"
    credential = base64.b64encode(
        hmac.new(
            TURN_SHARED_SECRET.encode("utf-8"),
            username.encode("utf-8"),
            hashlib.sha1,
        ).digest()
    ).decode("ascii")
    servers.append(
        {
            "urls": list(TURN_URLS),
            "username": username,
            "credential": credential,
        }
    )
    return servers


async def route_call_signal(server, packet):
    destination_node = str(packet.get("destination_node") or "").strip()
    if not destination_node or destination_node.upper() == "SERVER":
        return False

    signaling = getattr(server, "call_signaling", None)
    if signaling is not None and await signaling.submit(packet):
        await server.send_web_push_for_packet(destination_node, packet)
        return True

    delivered_nodes = set()

    async def deliver(target_node):
        if not target_node or target_node in delivered_nodes:
            return False
        routed = packet
        if target_node != destination_node:
            routed = {
                **packet,
                "destination_node": target_node,
                "original_destination_node": destination_node,
            }
        sender = getattr(server, "send_packet_to_node", None)
        if callable(sender):
            sent = await sender(target_node, routed)
        else:
            target_socket = server.clients.get(target_node)
            if not target_socket:
                return False
            await send_json(target_socket, routed)
            sent = True
        if not sent:
            return False
        delivered_nodes.add(target_node)
        return True

    delivered = await deliver(destination_node)
    source_node = str(packet.get("source_node") or "").strip()
    destination_login = server.get_login_by_node(destination_node)
    if destination_login:
        resolver = getattr(server, "get_realtime_account_nodes", None)
        target_nodes = (
            await resolver(destination_login)
            if callable(resolver)
            else server.get_online_account_nodes(destination_login)
        )
        for target_node in target_nodes:
            if target_node == source_node:
                continue
            delivered = await deliver(target_node) or delivered

    await server.send_web_push_for_packet(destination_node, packet)
    return delivered


async def _route_terminal_to_source_devices(server, packet, context):
    source_login = account_login(server, context.node_id)
    if not source_login:
        return
    resolver = getattr(server, "get_realtime_account_nodes", None)
    target_nodes = (
        await resolver(source_login)
        if callable(resolver)
        else server.get_online_account_nodes(source_login)
    )
    for target_node in target_nodes:
        if target_node == context.node_id:
            continue
        mirrored = {
            **packet,
            "source_node": context.node_id,
            "destination_node": target_node,
            "mirrored_terminal": True,
        }
        sender = getattr(server, "send_packet_to_node", None)
        if callable(sender):
            await sender(target_node, mirrored)
        else:
            target_socket = server.clients.get(target_node)
            if target_socket:
                await send_json(target_socket, mirrored)


async def handle_call_signal(server, packet, context):
    packet_type = str(packet.get("type") or "")
    if packet_type not in CALL_SIGNAL_PACKET_TYPES:
        return False
    validation_error = validate_call_signal(packet)
    if validation_error:
        await server.send_server_error(
            context.websocket,
            "invalid_call_signal",
            validation_error,
        )
        return True
    operation_id = str(packet.get("operation_id") or "").strip()
    if packet_type == "call_end":
        distributed_claim = getattr(server, "claim_realtime_operation", None)
        claimed = (
            await distributed_claim("call-end", operation_id)
            if callable(distributed_claim)
            else None
        )
        if claimed is False or (
            claimed is None and not _claim_operation(operation_id)
        ):
            return True

    packet["source_node"] = context.node_id
    sender_login = account_login(server, context.node_id)
    if sender_login:
        packet["sender_login"] = sender_login
    await route_call_signal(server, packet)
    if packet_type == "call_end":
        await _route_terminal_to_source_devices(server, packet, context)
    return True


async def handle_call_ice_servers_request(server, packet, context):
    login = account_login(server, context.node_id)
    await send_json(
        context.websocket,
        {
            "type": "call_ice_servers_result",
            "request_id": str(packet.get("request_id") or ""),
            "ice_servers": build_ice_servers(login, context.node_id),
            "ttl_seconds": TURN_CREDENTIAL_TTL_SECONDS,
            "turn_available": bool(TURN_SHARED_SECRET and TURN_URLS),
            "sfu_available": sfu_is_configured(
                CALL_SFU_ENABLED,
                CALL_SFU_URL,
                CALL_SFU_API_KEY,
                CALL_SFU_API_SECRET,
            ),
        },
    )
    return True


async def handle_call_sfu_access_request(server, packet, context):
    request_id = str(packet.get("request_id") or "")[:256]
    call_id = str(packet.get("call_id") or "").strip()
    configured = sfu_is_configured(
        CALL_SFU_ENABLED,
        CALL_SFU_URL,
        CALL_SFU_API_KEY,
        CALL_SFU_API_SECRET,
    )
    if not configured:
        await send_json(
            context.websocket,
            {
                "type": "call_sfu_access_result",
                "request_id": request_id,
                "enabled": False,
                "fallback": "p2p",
            },
        )
        return True
    if (
        CALL_SFU_REQUIRE_E2EE
        and str(packet.get("media_e2ee_capability") or "") != "frame-v1"
    ):
        await send_json(
            context.websocket,
            {
                "type": "call_sfu_access_result",
                "request_id": request_id,
                "enabled": False,
                "fallback": "p2p",
                "reason": "media_e2ee_required",
            },
        )
        return True
    if not _valid_identifier(call_id, _MAX_CALL_ID_LENGTH):
        await server.send_server_error(
            context.websocket,
            "invalid_call_id",
            "Invalid call_id",
        )
        return True

    login = account_login(server, context.node_id)
    identity = f"{login or 'device'}:{context.node_id}"[:255]
    room = private_room_name(call_id, CALL_SFU_API_SECRET)
    issued_at = int(time.time())
    token = build_livekit_access_token(
        api_key=CALL_SFU_API_KEY,
        api_secret=CALL_SFU_API_SECRET,
        room=room,
        identity=identity,
        display_name=login or context.node_id,
        ttl_seconds=CALL_SFU_TOKEN_TTL_SECONDS,
        now=issued_at,
    )
    await send_json(
        context.websocket,
        {
            "type": "call_sfu_access_result",
            "request_id": request_id,
            "enabled": True,
            "url": CALL_SFU_URL,
            "room": room,
            "token": token,
            "expires_at": issued_at + CALL_SFU_TOKEN_TTL_SECONDS,
            "media_e2ee": "frame-v1",
        },
    )
    return True


def register_call_commands(registry):
    registry.register(
        "call_ice_servers_request",
        handle_call_ice_servers_request,
    )
    registry.register(
        "call_sfu_access_request",
        handle_call_sfu_access_request,
    )
    for packet_type in CALL_SIGNAL_PACKET_TYPES:
        registry.register(packet_type, handle_call_signal)
