import asyncio
import json
import signal
import sys
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

try:
    from server.config import HOST, PORT, SERVER_TOKEN, REQUIRE_LOGIN
    from server.server_storage import ServerStorageMixin
    from server.server_auth import ServerAuthMixin
    from server.server_sync import ServerSyncMixin
    from server.server_push import ServerPushMixin
except ModuleNotFoundError:
    from config import HOST, PORT, SERVER_TOKEN, REQUIRE_LOGIN
    from server_storage import ServerStorageMixin
    from server_auth import ServerAuthMixin
    from server_sync import ServerSyncMixin
    from server_push import ServerPushMixin


class MeshRelayServer(
    ServerStorageMixin,
    ServerAuthMixin,
    ServerSyncMixin,
    ServerPushMixin
):

    def __init__(self):

        self.clients = {}
        self.client_names = {}
        self.client_logins = {}
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

                    if (
                        REQUIRE_LOGIN
                        or login
                        or password
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
                            packet.get("encryption_public_key")
                        )

                        if not ok:

                            print(
                                f"Client rejected: {reason}"
                            )

                            await websocket.close(
                                code=1008,
                                reason=reason
                            )

                            return

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

                    self.clients[
                        node_id
                    ] = websocket

                    self.client_names[
                        node_id
                    ] = username

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
                            True
                        )

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

                    print(
                        f"Client online: {username} ({node_id})"
                    )

                    if login:

                        await self.send_account_sync(
                            websocket,
                            login.strip().lower(),
                            node_id
                        )

                    await self.send_user_list()
                    await self.flush_offline_packets(
                        node_id,
                        websocket
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
                        packet.get("encryption_public_key")
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

                    continue

                self.save_history_packet(
                    packet
                )

                await self.route_packet(
                    packet
                )

        finally:

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

    async def route_packet(
        self,
        packet
    ):

        destination_node = packet.get(
            "destination_node"
        )

        if not destination_node:
            return

        websocket = self.clients.get(
            destination_node
        )

        is_call_packet = str(packet.get("type") or "").startswith("call_")

        if websocket:

            await websocket.send(
                json.dumps(
                    packet,
                    ensure_ascii=False
                )
            )

            if not is_call_packet:
                return

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

        self.save_offline_packet(
            destination_node,
            packet
        )

        await self.send_web_push_for_packet(
            destination_node,
            packet
        )


async def main():

    relay = MeshRelayServer()

    stop_event = asyncio.Event()

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

    async with websockets.serve(
        relay.handler,
        HOST,
        PORT,
        max_size=WEBSOCKET_MAX_SIZE
    ):

        print(
            f"Mesh relay server listening on ws://{HOST}:{PORT}"
        )

        print(
            "Protocol compatibility: "
            f"{MIN_SUPPORTED_PROTOCOL_VERSION}..{PROTOCOL_VERSION}"
        )

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
            f"For ngrok/localtonet, expose local port {PORT} and use the wss:// URL in clients."
        )

        await stop_event.wait()


if __name__ == "__main__":

    asyncio.run(
        main()
    )
