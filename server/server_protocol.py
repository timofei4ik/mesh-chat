import re

try:
    from version import (
        APP_VERSION,
        PROTOCOL_VERSION,
        MIN_SUPPORTED_PROTOCOL_VERSION,
        protocol_compatibility,
        version_payload,
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
            "protocol_min_version": MIN_SUPPORTED_PROTOCOL_VERSION,
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
        "message_read",
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
