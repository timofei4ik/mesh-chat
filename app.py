import argparse

from PyQt6.QtWidgets import QApplication

from network.discovery import Discovery
from gui.main_window import MainWindow
from network.server import ChatServer
from network.bluetooth_transport import BluetoothServer
from storage.database import Database
from gui.name_dialog import ask_username


def main():

    parser = argparse.ArgumentParser()
    

    parser.add_argument(
        "--port",
        type=int,
        required=True
    )

    parser.add_argument(
        "--bluetooth-channel",
        type=int,
        default=None
    )

    args = parser.parse_args()

    app = QApplication([])

    db = Database()

    node_id = db.get_or_create_node_id(
        args.port
    )

    setting_key = f"username_{args.port}"

    print(
        f"Node ID: {node_id}"
    )

    username = db.get_setting(
        setting_key
    )

    if not username:

        username = ask_username()

        if not username:
            return

        db.set_setting(
            setting_key,
            username
        )

    discovery = Discovery(
        username,
        args.port,
        node_id
    )

    discovery.start()

    window = MainWindow(
        username,
        discovery,
        node_id,
        args.bluetooth_channel
    )

    def packet_received(packet):

        window.packet_signal.emit(
            packet
        )

    server = ChatServer(
        args.port,
        packet_received
    )

    server.start()

    bluetooth_server = None

    if args.bluetooth_channel is not None:

        bluetooth_server = BluetoothServer(
            args.bluetooth_channel,
            packet_received,
            window.set_bluetooth_channel
        )

        bluetooth_server.start()

    window.show()

    app.exec()


if __name__ == "__main__":
    main()
