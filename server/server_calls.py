"""Call signaling and short-lived TURN credential delivery."""

import base64
import hashlib
import hmac
import time
from collections import OrderedDict

try:
    from server.config import (
        TURN_CREDENTIAL_TTL_SECONDS,
        TURN_SHARED_SECRET,
        TURN_STUN_URLS,
        TURN_URLS,
    )
    from server.server_command_bus import account_login, send_json
except ModuleNotFoundError:
    from config import (
        TURN_CREDENTIAL_TTL_SECONDS,
        TURN_SHARED_SECRET,
        TURN_STUN_URLS,
        TURN_URLS,
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

    delivered_nodes = set()

    async def deliver(target_node):
        if not target_node or target_node in delivered_nodes:
            return False
        target_socket = server.clients.get(target_node)
        if not target_socket:
            return False
        routed = packet
        if target_node != destination_node:
            routed = {
                **packet,
                "destination_node": target_node,
                "original_destination_node": destination_node,
            }
        await send_json(target_socket, routed)
        delivered_nodes.add(target_node)
        return True

    delivered = await deliver(destination_node)
    source_node = str(packet.get("source_node") or "").strip()
    destination_login = server.get_login_by_node(destination_node)
    if destination_login:
        for target_node in server.get_online_account_nodes(destination_login):
            if target_node == source_node:
                continue
            delivered = await deliver(target_node) or delivered

    if not delivered:
        await server.send_web_push_for_packet(destination_node, packet)
    return delivered


async def _route_terminal_to_source_devices(server, packet, context):
    source_login = account_login(server, context.node_id)
    if not source_login:
        return
    for target_node in server.get_online_account_nodes(source_login):
        if target_node == context.node_id:
            continue
        target_socket = server.clients.get(target_node)
        if not target_socket:
            continue
        await send_json(
            target_socket,
            {
                **packet,
                "source_node": context.node_id,
                "destination_node": target_node,
                "mirrored_terminal": True,
            },
        )


async def handle_call_signal(server, packet, context):
    packet_type = str(packet.get("type") or "")
    destination = str(packet.get("destination_node") or "").strip()
    call_id = str(packet.get("call_id") or "").strip()
    if packet_type not in CALL_SIGNAL_PACKET_TYPES:
        return False
    if not destination or not call_id:
        await server.send_server_error(
            context.websocket,
            "invalid_call_signal",
            "Call signal requires destination_node and call_id",
        )
        return True
    operation_id = str(packet.get("operation_id") or "").strip()
    if packet_type == "call_end" and not _claim_operation(operation_id):
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
        },
    )
    return True


def register_call_commands(registry):
    registry.register(
        "call_ice_servers_request",
        handle_call_ice_servers_request,
    )
    for packet_type in CALL_SIGNAL_PACKET_TYPES:
        registry.register(packet_type, handle_call_signal)
