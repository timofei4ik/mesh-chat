import socket
import threading
import json
import time
from storage.database import Database


BROADCAST_PORT = 37020


class Discovery:

    def __init__(
        self,
        username,
        tcp_port,
        node_id
    ):

        self.username = username
        self.tcp_port = tcp_port
        self.node_id = node_id

        self.db = Database()

        self.users = {}

        self.running = True

    def start(self):

        threading.Thread(
            target=self.broadcast_loop,
            daemon=True
        ).start()

        threading.Thread(
            target=self.listen_loop,
            daemon=True
        ).start()

    def get_local_ip(self):

        try:

            s = socket.socket(
                socket.AF_INET,
                socket.SOCK_DGRAM
            )

            s.connect(
                ("8.8.8.8", 80)
            )

            ip = s.getsockname()[0]

            s.close()

            return ip

        except:

            return "127.0.0.1"

    def broadcast_loop(self):

        sock = socket.socket(
            socket.AF_INET,
            socket.SOCK_DGRAM
        )

        sock.setsockopt(
            socket.SOL_SOCKET,
            socket.SO_BROADCAST,
            1
        )

        while self.running:

            packet = {

                "node_id": self.node_id,

                "name": self.username,

                "port": self.tcp_port
            }

            try:

                sock.sendto(
                    json.dumps(packet).encode(),
                    (
                        "255.255.255.255",
                        BROADCAST_PORT
                    )
                )

            except Exception as e:

                print(
                    "Broadcast error:",
                    e
                )

            time.sleep(3)

    def listen_loop(self):

        sock = socket.socket(
            socket.AF_INET,
            socket.SOCK_DGRAM
        )

        sock.setsockopt(
            socket.SOL_SOCKET,
            socket.SO_REUSEADDR,
            1
        )

        sock.bind(
            ("", BROADCAST_PORT)
        )

        while self.running:

            try:

                data, addr = sock.recvfrom(
                    4096
                )

                packet = json.loads(
                    data.decode()
                )

                if packet.get(
                    "node_id"
                ) == self.node_id:

                    continue

                user_key = (
                    addr[0],
                    packet["port"]
                )

                self.users[
                    user_key
                ] = {

                    "node_id": packet.get(
                        "node_id"
                    ),

                    "name": packet.get(
                        "name"
                    ),

                    "port": packet.get(
                        "port"
                    ),

                    "last_seen": time.time()
                }

                self.db.update_user(
                    packet["node_id"],
                    packet["name"],
                    addr[0],
                    packet["port"]
                )

            except Exception as e:

                print(
                    "Discovery error:",
                    e
                )

    def get_users(self):

        result = []

        now = time.time()

        for (
            ip,
            port
        ), info in list(
            self.users.items()
        ):

            if now - info[
                "last_seen"
            ] > 10:

                del self.users[
                    (
                        ip,
                        port
                    )
                ]

                continue

            result.append(
                (
                    (info["node_id"],
                    info["name"],
                    ip,
                    info["port"])
                )
            )

        return result

    def get_user_by_name(
        self,
        username
    ):

        for (ip, port), info in self.users.items():

            if info["name"] == username:

                return (
                    ip,
                    info["port"]
                )

        return None


    def get_user_by_node_id(
        self,
        node_id
    ):

        for (ip, port), info in self.users.items():

            if info["node_id"] == node_id:

                return (
                    ip,
                    info["port"]
                )

        return None


    def get_node_id_by_name(
        self,
        username
    ):

        for (ip, port), info in self.users.items():

            if info["name"] == username:

                return info["node_id"]

        return None


    def get_name_by_node_id(
        self,
        node_id
    ):

        for info in self.users.values():

            if info["node_id"] == node_id:

                return info["name"]

        return node_id[:8]