import json
import socket
import traceback

from network.transport import Transport


class TcpTransport(Transport):

    name = "tcp"

    def send_packet(
        self,
        peer,
        packet
    ):

        ip = peer["ip"]
        port = peer["port"]

        try:

            sock = socket.socket(
                socket.AF_INET,
                socket.SOCK_STREAM
            )

            sock.settimeout(
                2
            )

            sock.connect(
                (
                    ip,
                    port
                )
            )

            sock.sendall(
                (json.dumps(packet) + "\n").encode()
            )

            sock.close()

            return True

        except Exception as e:

            traceback.print_exc()

            print(
                "Send error:",
                e
            )

            return False
