import argparse
import os
import socket

from PyQt6.QtWidgets import QApplication

from network.discovery import Discovery
from gui.main_window import MainWindow
from gui.app_icon import app_icon
from network.server import ChatServer
from network.bluetooth_transport import BluetoothServer
from network.server_url import normalize_server_url
from storage.database import Database, get_account_database_path
from gui.name_dialog import ask_username
from gui.login_dialog import ask_server_login, ask_account_manager


def find_free_port(
    start=5000,
    end=5999
):

    for port in range(
        start,
        end + 1
    ):

        with socket.socket(
            socket.AF_INET,
            socket.SOCK_STREAM
        ) as sock:

            sock.setsockopt(
                socket.SOL_SOCKET,
                socket.SO_REUSEADDR,
                1
            )

            try:

                sock.bind(
                    (
                        "0.0.0.0",
                        port
                    )
                )

            except OSError:

                continue

            return port

    raise RuntimeError(
        f"No free port found in {start}-{end}"
    )


def main():

    parser = argparse.ArgumentParser()
    

    parser.add_argument(
        "--port",
        default="auto",
        help="TCP port or 'auto'. Default: auto"
    )

    parser.add_argument(
        "--bluetooth-channel",
        type=int,
        default=None
    )

    parser.add_argument(
        "--server",
        default=None,
        help="WebSocket server URL, for example ws://127.0.0.1:8765"
    )

    parser.add_argument(
        "--server-token",
        default=None,
        help="Invite token required by the relay server"
    )

    parser.add_argument(
        "--login",
        default=None,
        help="Server account login"
    )

    parser.add_argument(
        "--password",
        default=None,
        help="Server account password"
    )

    args = parser.parse_args()

    if str(args.port).lower() == "auto":

        port = find_free_port()

    else:

        port = int(
            args.port
        )

    app = QApplication([])

    app.setWindowIcon(
        app_icon()
    )

    settings_db = Database()

    server_url = (
        args.server
        or settings_db.get_setting(
            "server_url"
        )
        or ""
    )

    server_url = normalize_server_url(
        server_url
    )

    if args.server:

        settings_db.set_setting(
            "server_url",
            server_url
        )

    server_token = (
        args.server_token
        or settings_db.get_setting(
            "server_token"
        )
        or ""
    )

    if args.server_token is not None:

        settings_db.set_setting(
            "server_token",
            server_token
        )

    server_login = (
        args.login
        or settings_db.get_setting(
            "server_login"
        )
        or ""
    )

    if args.login is not None:

        settings_db.set_setting(
            "server_login",
            server_login
        )

    server_password = (
        args.password
        or settings_db.get_setting(
            "server_password"
        )
        or ""
    )

    if args.password is not None:

        settings_db.set_setting(
            "server_password",
            server_password
        )

    if (
        server_url
        and args.login is None
        and args.password is None
    ):

        login_values = ask_account_manager(
            server_url,
            server_token
        )

        if not login_values:
            return

        server_url = login_values[
            "server_url"
        ]

        server_token = login_values[
            "server_token"
        ]

        server_login = login_values[
            "login"
        ]

        server_password = login_values[
            "password"
        ]

        public_username = login_values.get(
            "public_username",
            server_login
        )

        settings_db.set_setting(
            "server_url",
            server_url
        )

        settings_db.set_setting(
            "server_token",
            server_token
        )

        settings_db.set_setting(
            "server_login",
            server_login
        )

        settings_db.set_setting(
            "server_password",
            server_password
        )

        settings_db.set_setting(
            "public_username",
            public_username
        )

    if server_url and server_login:

        os.environ[
            "MESHCHAT_DB_PATH"
        ] = get_account_database_path(
            server_login
        )

    db = Database()

    if server_url:

        db.set_setting(
            "server_url",
            server_url
        )

        db.set_setting(
            "server_token",
            server_token
        )

        db.set_setting(
            "server_login",
            server_login
        )

        db.set_setting(
            "server_password",
            server_password
        )

        db.set_setting(
            "public_username",
            public_username if "public_username" in locals() else server_login
        )

    node_id = db.get_setting(
        "node_id"
    )

    if not node_id:

        node_id = db.get_or_create_node_id(
            "default"
        )

        db.set_setting(
            "node_id",
            node_id
        )

    setting_key = "username"

    old_setting_key = f"username_{port}"

    old_username = db.get_setting(
        old_setting_key
    )

    if old_username and not db.get_setting(
        setting_key
    ):

        db.set_setting(
            setting_key,
            old_username
        )

    print(
        f"Node ID: {node_id}"
    )

    print(
        f"TCP port: {port}"
    )

    print(
        f"Database: {db.path}"
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
        port,
        node_id
    )

    discovery.start()

    window = MainWindow(
        username,
        discovery,
        node_id,
        args.bluetooth_channel,
        server_url,
        server_token,
        server_login,
        server_password
    )

    def packet_received(packet):

        window.packet_signal.emit(
            packet
        )

    server = ChatServer(
        port,
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
