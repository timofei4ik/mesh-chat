import json
import socket
import threading
import traceback

from network.transport import Transport, TransportError
from network.bluetooth_discovery import normalize_bluetooth_address


class BluetoothUnavailableError(TransportError):

    pass


def ensure_bluetooth_supported():

    required = (
        "AF_BLUETOOTH",
        "BTPROTO_RFCOMM"
    )

    missing = [
        name
        for name in required
        if not hasattr(socket, name)
    ]

    if missing:

        raise BluetoothUnavailableError(
            "Bluetooth RFCOMM is not available in this Python build."
        )


def get_bluetooth_any_address():

    return getattr(
        socket,
        "BDADDR_ANY",
        "00:00:00:00:00:00"
    )


class BluetoothTransport(Transport):

    name = "bluetooth"

    def send_packet(
        self,
        peer,
        packet
    ):

        try:

            ensure_bluetooth_supported()

            address = peer["address"]
            channel = peer.get(
                "channel",
                1
            )

            channels = [channel]

            if channel == 0:

                channels = range(
                    1,
                    31
                )

            last_error = None

            for current_channel in channels:

                if self.try_send_packet(
                    address,
                    current_channel,
                    packet
                ):

                    print(
                        "Bluetooth sent to",
                        address,
                        "on channel",
                        current_channel
                    )

                    return True

                last_error = current_channel

            print(
                "Bluetooth send failed to",
                address,
                "last channel:",
                last_error
            )

            return False

        except Exception as e:

            traceback.print_exc()

            print(
                "Bluetooth send error:",
                e
            )

            return False

    def try_send_packet(
        self,
        address,
        channel,
        packet
    ):

        try:

            sock = socket.socket(
                socket.AF_BLUETOOTH,
                socket.SOCK_STREAM,
                socket.BTPROTO_RFCOMM
            )

            sock.settimeout(
                2
            )

            sock.connect(
                (
                    address,
                    channel
                )
            )

            sock.sendall(
                (json.dumps(packet) + "\n").encode()
            )

            sock.close()

            return True

        except Exception as e:

            print(
                "Bluetooth address",
                address,
                "Bluetooth channel",
                channel,
                "failed:",
                e
            )

            return False


def send_bluetooth_packet(
    address,
    channel,
    packet
):

    transport = BluetoothTransport()

    return transport.send_packet(
        {
            "address": address,

            "channel": channel
        },
        packet
    )


class BluetoothServer:

    def __init__(
        self,
        channel,
        callback,
        started_callback=None
    ):

        self.channel = channel
        self.callback = callback
        self.started_callback = started_callback
        self.running = False
        self.bound_channel = None

    def start(self):

        self.running = True

        threading.Thread(
            target=self.run,
            daemon=True
        ).start()

    def run(self):

        try:

            ensure_bluetooth_supported()

            server = socket.socket(
                socket.AF_BLUETOOTH,
                socket.SOCK_STREAM,
                socket.BTPROTO_RFCOMM
            )

            self.bind_server(
                server
            )

            server.listen()

            print(
                "Bluetooth server listening on channel",
                self.bound_channel
            )

            if self.started_callback:

                self.started_callback(
                    self.bound_channel
                )

            while self.running:

                conn, addr = server.accept()

                threading.Thread(
                    target=self.handle_client,
                    args=(conn, addr),
                    daemon=True
                ).start()

        except Exception as e:

            traceback.print_exc()

            print(
                "Bluetooth server error:",
                e
            )

    def bind_server(
        self,
        server
    ):

        address = get_bluetooth_any_address()
        channels = [self.channel]

        if self.channel == 0:

            channels = range(
                1,
                31
            )

        for channel in channels:

            try:

                server.bind(
                    (
                        address,
                        channel
                    )
                )

                self.bound_channel = channel

                return

            except PermissionError as e:

                if getattr(
                    e,
                    "winerror",
                    None
                ) != 10013:

                    raise

                print(
                    "Bluetooth channel",
                    channel,
                    "is blocked or busy"
                )

            except OSError as e:

                print(
                    "Bluetooth channel",
                    channel,
                    "cannot be used:",
                    e
                )

        raise OSError(
            "No available Bluetooth RFCOMM channel found"
        )

    def handle_client(
        self,
        conn,
        addr
    ):

        try:

            buffer = b""

            while True:

                chunk = conn.recv(4096)

                if not chunk:
                    break

                buffer += chunk

            packet = json.loads(
                buffer.decode()
            )

            if addr:

                packet[
                    "remote_bluetooth_address"
                ] = normalize_bluetooth_address(
                    addr[0]
                )

            self.callback(
                packet
            )

        except Exception:

            traceback.print_exc()

        finally:

            conn.close()
