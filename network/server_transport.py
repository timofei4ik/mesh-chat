import asyncio
import json
import threading
import time

from version import (
    APP_VERSION,
    PROTOCOL_VERSION,
    MIN_SUPPORTED_PROTOCOL_VERSION,
    protocol_compatibility
)

WEBSOCKET_MAX_SIZE = 16 * 1024 * 1024


async def diagnose_server_connection(
    server_url,
    node_id,
    username,
    server_token="",
    login="",
    password="",
    public_username="",
    timeout=8
):

    try:

        import websockets

    except ImportError:

        return False, "Нужен пакет websockets: pip install websockets"

    try:

        async with websockets.connect(
            server_url,
            open_timeout=timeout,
            ping_interval=20,
            ping_timeout=20,
            max_size=WEBSOCKET_MAX_SIZE
        ) as websocket:

            await websocket.send(
                json.dumps(
                    {
                        "type": "server_hello",
                        "node_id": node_id,
                        "username": username,
                        "server_token": server_token or "",
                        "login": login or "",
                        "password": password or "",
                        "public_username": public_username or "",
                        "auth_check": True,
                        "app_version": APP_VERSION,
                        "protocol_version": PROTOCOL_VERSION,
                        "min_protocol_version": MIN_SUPPORTED_PROTOCOL_VERSION
                    },
                    ensure_ascii=False
                )
            )

            raw_message = await asyncio.wait_for(
                websocket.recv(),
                timeout=timeout
            )

            packet = json.loads(
                raw_message
            )

            if packet.get("type") == "server_error":

                if packet.get("code") == "incompatible_protocol":
                    return (
                        False,
                        "Несовместимые версии протокола: "
                        f"клиент {MIN_SUPPORTED_PROTOCOL_VERSION}..{PROTOCOL_VERSION}, "
                        f"сервер {packet.get('min_protocol_version', '?')}..{packet.get('protocol_version', '?')}. "
                        "Обновите клиент или сервер."
                    )

                return False, packet.get("message") or packet.get("reason") or "Ошибка сервера"

            if packet.get("type") == "server_welcome":

                server_protocol = packet.get(
                    "protocol_version"
                )
                server_min_protocol = packet.get(
                    "min_protocol_version",
                    packet.get("protocol_min_version")
                )

                compatible, _reason = protocol_compatibility(
                    server_protocol,
                    server_min_protocol
                )

                if not compatible:

                    return (
                        False,
                        "Несовместимые версии протокола: "
                        f"клиент {MIN_SUPPORTED_PROTOCOL_VERSION}..{PROTOCOL_VERSION}, "
                        f"сервер {server_min_protocol or server_protocol}..{server_protocol}. "
                        "Обновите клиент или сервер."
                    )

                return (
                    True,
                    f"OK: сервер {packet.get('server_version', 'unknown')}"
                )

            if packet.get("type") == "server_users":
                return True, "OK: сервер доступен"

            return True, f"OK: ответ сервера {packet.get('type', 'unknown')}"

    except websockets.exceptions.ConnectionClosedError as e:

        reason = e.reason or str(e)
        return False, f"Сервер закрыл соединение: {reason}"

    except websockets.exceptions.InvalidURI as e:

        return False, f"Неверный адрес сервера: {e}"

    except Exception as e:

        return False, f"Не удалось подключиться: {e}"


def diagnose_server_connection_sync(*args, **kwargs):

    return asyncio.run(
        diagnose_server_connection(
            *args,
            **kwargs
        )
    )


class ServerTransport:

    def __init__(
        self,
        server_url,
        node_id,
        username,
        packet_callback,
        users_callback=None,
        status_callback=None,
        server_token="",
        login="",
        password="",
        public_username="",
        about="",
        avatar_data="",
        encryption_public_key=""
    ):

        self.server_url = server_url
        self.node_id = node_id
        self.username = username
        self.server_token = server_token or ""
        self.login = login or ""
        self.password = password or ""
        self.public_username = public_username or ""
        self.about = about or ""
        self.avatar_data = avatar_data or ""
        self.encryption_public_key = encryption_public_key or ""
        self.packet_callback = packet_callback
        self.users_callback = users_callback
        self.status_callback = status_callback
        self.loop = None
        self.websocket = None
        self.stopped = False
        self.thread = None

    def set_status(
        self,
        status
    ):

        print(
            "Mesh server:",
            status
        )

        if self.status_callback:

            self.status_callback(
                status
            )

    def start(self):

        if self.thread:
            return

        self.thread = threading.Thread(
            target=self.run,
            daemon=True
        )

        self.thread.start()

    def stop(self):

        self.stopped = True

        if self.loop:

            self.loop.call_soon_threadsafe(
                self.loop.stop
            )

    def run(self):

        self.loop = asyncio.new_event_loop()

        asyncio.set_event_loop(
            self.loop
        )

        self.loop.create_task(
            self.connect_forever()
        )

        try:

            self.loop.run_forever()

        finally:

            self.loop.close()

    async def connect_forever(self):

        try:

            import websockets

        except ImportError:

            self.set_status(
                "Нужен пакет websockets: pip install websockets"
            )

            return

        while not self.stopped:

            try:

                self.set_status(
                    f"Подключение к {self.server_url}"
                )

                async with websockets.connect(
                    self.server_url,
                    ping_interval=20,
                    ping_timeout=20,
                    max_size=WEBSOCKET_MAX_SIZE
                ) as websocket:

                    self.websocket = websocket

                    await websocket.send(
                        json.dumps(
                            {
                                "type": "server_hello",
                                "node_id": self.node_id,
                                "username": self.username,
                                "server_token": self.server_token,
                                "login": self.login,
                                "password": self.password,
                                "public_username": self.public_username,
                                "about": self.about,
                                "avatar_data": self.avatar_data,
                                "encryption_public_key": self.encryption_public_key,
                                "app_version": APP_VERSION,
                                "protocol_version": PROTOCOL_VERSION,
                                "min_protocol_version": MIN_SUPPORTED_PROTOCOL_VERSION
                            },
                            ensure_ascii=False
                        )
                    )

                    self.set_status(
                        f"Подключено: {self.server_url}"
                    )

                    async for raw_message in websocket:

                        packet = json.loads(
                            raw_message
                        )

                        if packet.get("type") == "server_welcome":

                            server_protocol = packet.get(
                                "protocol_version"
                            )
                            server_min_protocol = packet.get(
                                "min_protocol_version",
                                packet.get("protocol_min_version")
                            )

                            compatible, _reason = protocol_compatibility(
                                server_protocol,
                                server_min_protocol
                            )

                            if not compatible:

                                self.set_status(
                                    "Несовместимые версии протокола: "
                                    f"клиент {MIN_SUPPORTED_PROTOCOL_VERSION}..{PROTOCOL_VERSION}, "
                                    f"сервер {server_min_protocol or server_protocol}..{server_protocol}"
                                )

                            continue

                        if packet.get("type") == "server_error":

                            if packet.get("code") == "incompatible_protocol":
                                self.set_status(
                                    "Несовместимые версии протокола: "
                                    f"клиент {MIN_SUPPORTED_PROTOCOL_VERSION}..{PROTOCOL_VERSION}, "
                                    f"сервер {packet.get('min_protocol_version', '?')}..{packet.get('protocol_version', '?')}"
                                )
                            else:
                                self.set_status(
                                    packet.get("message")
                                    or packet.get("reason")
                                    or "Ошибка сервера"
                                )

                            continue

                        if packet.get("type") == "server_users":

                            if self.users_callback:

                                self.users_callback(
                                    packet.get(
                                        "users",
                                        []
                                    )
                                )

                            continue

                        self.packet_callback(
                            packet
                        )

            except websockets.exceptions.ConnectionClosedError as e:

                reason = e.reason or str(e)

                self.set_status(
                    f"Ошибка: сервер закрыл соединение ({reason})"
                )

            except websockets.exceptions.InvalidURI as e:

                self.set_status(
                    f"Ошибка: неверный адрес сервера ({e})"
                )

            except Exception as e:

                self.set_status(
                    f"Ошибка: {e}"
                )

            finally:

                self.websocket = None

                if not self.stopped:

                    self.set_status(
                        "Переподключение через 3 секунды"
                    )

            await asyncio.sleep(
                3
            )

    def send_packet(
        self,
        packet
    ):

        if (
            not self.loop
            or not self.websocket
        ):

            return False

        future = asyncio.run_coroutine_threadsafe(
            self.send_packet_async(
                packet
            ),
            self.loop
        )

        try:

            future.result(
                timeout=2
            )

            return True

        except Exception as e:

            print(
                "Mesh server send error:",
                e
            )

            return False

    async def send_packet_async(
        self,
        packet
    ):

        await self.websocket.send(
            json.dumps(
                packet,
                ensure_ascii=False
            )
        )
