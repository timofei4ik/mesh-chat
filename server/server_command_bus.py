import json
from dataclasses import dataclass


@dataclass(frozen=True)
class ConnectionContext:
    websocket: object
    node_id: str
    is_service_connection: bool = False
    start_account_sync: object | None = None


class StopConnectionHandler(RuntimeError):
    pass


class PacketCommandRegistry:
    def __init__(self):
        self._handlers = {}

    def register(self, packet_type, handler):
        normalized_type = str(packet_type or "").strip()
        if not normalized_type:
            raise ValueError("packet type is required")
        if normalized_type in self._handlers:
            raise ValueError(f"duplicate packet command: {normalized_type}")
        self._handlers[normalized_type] = handler

    async def dispatch(self, server, packet, context):
        handler = self._handlers.get(str(packet.get("type") or ""))
        if handler is None:
            return False
        result = await handler(server, packet, context)
        return result is not False

    @property
    def packet_types(self):
        return frozenset(self._handlers)


async def send_json(websocket, payload):
    await websocket.send(json.dumps(payload, ensure_ascii=False))


def account_login(server, node_id):
    return (
        server.client_logins.get(node_id)
        or server.get_login_by_node(node_id)
        or ""
    )
