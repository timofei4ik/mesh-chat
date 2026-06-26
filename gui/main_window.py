import socket
import threading
import json
import base64
import time
from PyQt6.QtCore import (
    QByteArray,
    QBuffer,
    QIODevice,
    QTimer,
    pyqtSignal,
    Qt
)

from PyQt6.QtWidgets import (
    QWidget,
    QVBoxLayout,
    QHBoxLayout,
    QFormLayout,
    QLabel,
    QLineEdit,
    QListWidget,
    QPushButton,
    QCheckBox,
    QMessageBox,
    QMenu,
    QSystemTrayIcon,
    QApplication,
    QStyle,
    QTabWidget,
    QDialog,
    QDialogButtonBox,
    QFileDialog
)

from gui.request_dialog import ChatRequestDialog
from gui.chat_window import ChatWindow
from gui.main_window_server import ServerMixin
from gui.main_window_tray import TrayMixin
from gui.main_window_bluetooth import BluetoothMixin
from gui.main_window_groups import GroupsMixin
from gui.main_window_chats import MainChatsMixin
from gui.main_window_pending import MainPendingMixin
from gui.main_window_packets import MainPacketMixin
from gui.app_icon import app_icon, app_logo
from gui.avatar import round_pixmap
from storage.database import Database, get_database_dir
from PyQt6.QtWidgets import QInputDialog
from network.packet_cache import PacketCache
from PyQt6.QtWidgets import QListWidgetItem
from PyQt6.QtGui import QPixmap
from network.router import forward_packet
from network.message_id import generate_message_id
from network.protocol import (
    chat_message_packet,
    message_received_packet,
)
from network.server_url import normalize_server_url
from network.bluetooth_discovery import get_local_bluetooth_address
from security.e2ee import EncryptionIdentity


from network.client import (
    send_packet,
    send_chat_response
)


class MainWindow(ServerMixin, TrayMixin, BluetoothMixin, GroupsMixin, MainChatsMixin, MainPendingMixin, MainPacketMixin, QWidget):

    incoming_request = pyqtSignal(dict)
    incoming_response = pyqtSignal(dict)
    packet_signal = pyqtSignal(dict)

    file_received_signal = pyqtSignal(
        str,  #sender
        str,  #sender_node_id
        str,  #filename
        str,  #data
        str   #file_id
    )

    message_received_signal = pyqtSignal(
        str,  # sender
        str,  # sender_node_id
        str   # message
    )

    typing_signal = pyqtSignal(
        str,
        str
    )

    bluetooth_scan_done = pyqtSignal(
        int
    )

    pending_message_sent = pyqtSignal(
        str
    )

    server_users_signal = pyqtSignal(
        list
    )

    server_status_signal = pyqtSignal(
        str
    )

    server_test_done_signal = pyqtSignal(
        str
    )

    def __init__(
        self,
        username,
        discovery,
        node_id,
        bluetooth_channel=None,
        server_url="",
        server_token="",
        server_login="",
        server_password=""
    ):

        self.chat_windows = {}
        self.group_windows = {}
        self.file_chunks = {}
        self.server_file_sync_chunks = {}
        self.pending_sent_files = {}
        self.pending_retry_in_progress = False
        self.server_transport = None
        self.server_users = {}
        self.visible_users = []
        self.showing_archive = False

        self.port = discovery.tcp_port
        self.bluetooth_channel = bluetooth_channel
        self.bluetooth_address = get_local_bluetooth_address()

        super().__init__()

        self.username = username
        self.node_id = node_id
        self.discovery = discovery
        self.db = Database()
        self.packet_cache = PacketCache()
        self.server_url = server_url or self.db.get_setting(
            "server_url"
        ) or ""

        self.server_url = normalize_server_url(
            self.server_url
        )

        self.server_token = server_token or self.db.get_setting(
            "server_token"
        ) or ""

        self.server_login = server_login or self.db.get_setting(
            "server_login"
        ) or ""

        self.server_password = server_password or self.db.get_setting(
            "server_password"
        ) or ""

        self.encryption = EncryptionIdentity(
            self.db,
            self.server_password,
            self.server_login
        )

        self.encryption_public_key = (
            self.encryption.public_key_text
        )

        self.profile_avatar_path = self.db.get_setting(
            "profile_avatar_path"
        ) or ""

        self.profile_about = self.db.get_setting(
            "profile_about"
        ) or ""

        self.profile_avatar_data = self.db.get_setting(
            "profile_avatar_data"
        ) or ""

        self.public_username = (
            self.db.get_setting(
                "public_username"
            )
            or self.server_login
            or ""
        ).strip().lower().lstrip("@")

        self.compress_images = (
            self.db.get_setting(
                "compress_images",
                "1"
            ) != "0"
        )

        self.message_received_signal.connect(
            self.show_message
        )

        self.typing_signal.connect(
            self.show_typing
        )

        self.packet_signal.connect(
            self.handle_packet
        )

        self.file_received_signal.connect(
            self.show_file_message
        )

        self.selected_user = None

        self.setWindowTitle(
            f"MeshChat - {username}"
        )

        self.setWindowIcon(
            app_icon()
        )

        self.incoming_response.connect(
            self.show_chat_response
        )

        self.resize(
            600,
            500
        )

        self.tray_icon = None
        self.force_quit = False
        self.setup_notifications()

        layout = QVBoxLayout()

        self.logo_label = QLabel()

        self.logo_label.setPixmap(
            app_logo(46)
        )

        self.header_avatar_label = QLabel()

        self.header_avatar_label.setFixedSize(
            46,
            46
        )

        self.me_label = QLabel(
            f"You: {username}\nID: {node_id[:8]}"
        )

        self.users_label = QLabel(
            "Network users"
        )

        self.users_list = QListWidget()

        self.chats_label = QLabel(
            "My chats"
        )
        self.chats_list = QListWidget()

        self.info_label = QLabel(
            "Select a user"
        )

        self.chat_button = QPushButton(
            "Start chat"
        )

        self.create_group_button = QPushButton(
            "Create group"
        )

        self.archive_button = QPushButton(
            "Archive"
        )

        self.username_search_input = QLineEdit()
        self.username_search_input.setPlaceholderText(
            "@username"
        )

        self.username_search_button = QPushButton(
            "Find"
        )

        self.rename_button = QPushButton(
            "Change name"
        )

        self.bluetooth_button = QPushButton(
            "Bluetooth chat"
        )

        self.bluetooth_scan_button = QPushButton(
            "Find Bluetooth"
        )

        self.bluetooth_status_label = QLabel(
            "Bluetooth is not running"
        )

        self.settings_name_input = QLineEdit(
            username
        )

        self.settings_avatar_label = QLabel()

        self.settings_avatar_label.setFixedSize(
            64,
            64
        )

        self.settings_avatar_button = QPushButton(
            "Choose avatar"
        )

        self.settings_about_input = QLineEdit(
            self.profile_about
        )

        self.settings_about_input.setPlaceholderText(
            "About"
        )

        self.settings_public_username_input = QLineEdit(
            self.public_username
        )
        self.settings_public_username_input.setPlaceholderText(
            "username"
        )

        self.settings_compress_images_checkbox = QCheckBox(
            "Compress photos before sending"
        )

        self.settings_compress_images_checkbox.setChecked(
            self.compress_images
        )

        self.settings_save_button = QPushButton(
            "Save"
        )

        self.settings_server_test_button = QPushButton(
            "Test server"
        )

        self.settings_logout_button = QPushButton(
            "Logout"
        )

        self.settings_node_label = QLabel(
            node_id
        )

        self.settings_port_label = QLabel(
            str(self.port)
        )

        self.settings_database_label = QLabel(
            self.db.path
        )

        self.settings_bluetooth_label = QLabel(
            ""
        )

        self.settings_server_input = QLineEdit(
            self.server_url
        )

        self.settings_server_input.setPlaceholderText(
            "wss://example.ngrok-free.app"
        )

        self.settings_server_token_input = QLineEdit(
            self.server_token
        )

        self.settings_server_token_input.setEchoMode(
            QLineEdit.EchoMode.Password
        )

        self.settings_server_token_input.setPlaceholderText(
            "invite token"
        )

        self.settings_server_login_input = QLineEdit(
            self.server_login
        )

        self.settings_server_login_input.setPlaceholderText(
            "login"
        )

        self.settings_server_password_input = QLineEdit(
            self.server_password
        )

        self.settings_server_password_input.setEchoMode(
            QLineEdit.EchoMode.Password
        )

        self.settings_server_password_input.setPlaceholderText(
            "password"
        )

        self.settings_server_status_label = QLabel(
            "Server is not configured"
        )

        self.chat_button.setEnabled(
            False
        )

        self.tabs = QTabWidget()

        self.network_tab = QWidget()
        network_layout = QVBoxLayout()
        network_actions = QHBoxLayout()

        network_actions.addWidget(
            self.chat_button
        )

        network_layout.addWidget(
            self.users_label
        )

        network_layout.addWidget(
            self.users_list
        )

        network_layout.addWidget(
            self.info_label
        )

        network_layout.addLayout(
            network_actions
        )

        self.network_tab.setLayout(
            network_layout
        )

        self.chats_tab = QWidget()
        chats_layout = QVBoxLayout()
        username_search_layout = QHBoxLayout()

        username_search_layout.addWidget(
            self.username_search_input
        )
        username_search_layout.addWidget(
            self.username_search_button
        )

        chats_layout.addWidget(
            self.chats_label
        )

        chats_layout.addWidget(
            self.create_group_button
        )

        chats_layout.addWidget(
            self.archive_button
        )

        chats_layout.addLayout(
            username_search_layout
        )

        chats_layout.addWidget(
            self.chats_list
        )

        self.chats_tab.setLayout(
            chats_layout
        )

        self.bluetooth_tab = QWidget()
        bluetooth_layout = QVBoxLayout()
        bluetooth_actions = QHBoxLayout()

        bluetooth_layout.setContentsMargins(
            16, 16, 16, 16
        )

        bluetooth_layout.setSpacing(
            10
        )

        bluetooth_layout.setAlignment(
            Qt.AlignmentFlag.AlignTop
        )

        bluetooth_actions.setSpacing(
            8
        )

        bluetooth_title = QLabel(
            "Bluetooth"
        )

        bluetooth_title.setStyleSheet(
            "font-size: 16px; font-weight: 600;"
        )

        bluetooth_hint = QLabel(
            "Connect manually or find paired MeshChat devices."
        )

        bluetooth_hint.setWordWrap(
            True
        )

        bluetooth_hint.setStyleSheet(
            "color: #b8b8b8;"
        )

        self.bluetooth_status_label.setWordWrap(
            True
        )

        bluetooth_actions.addWidget(
            self.bluetooth_button
        )

        bluetooth_actions.addWidget(
            self.bluetooth_scan_button
        )

        bluetooth_actions.addStretch()

        bluetooth_layout.addWidget(
            bluetooth_title
        )

        bluetooth_layout.addWidget(
            self.bluetooth_status_label
        )

        bluetooth_layout.addWidget(
            bluetooth_hint
        )

        bluetooth_layout.addLayout(
            bluetooth_actions
        )

        bluetooth_layout.addStretch()

        self.bluetooth_tab.setLayout(
            bluetooth_layout
        )

        self.settings_tab = QWidget()
        settings_layout = QVBoxLayout()
        settings_form = QFormLayout()

        settings_form.addRow(
            "Name:",
            self.settings_name_input
        )

        avatar_row = QHBoxLayout()

        avatar_row.addWidget(
            self.settings_avatar_label
        )

        avatar_row.addWidget(
            self.settings_avatar_button
        )

        avatar_row.addStretch()

        settings_form.addRow(
            "Avatar:",
            avatar_row
        )

        settings_form.addRow(
            "About:",
            self.settings_about_input
        )

        settings_form.addRow(
            "@username:",
            self.settings_public_username_input
        )

        settings_form.addRow(
            "Photo:",
            self.settings_compress_images_checkbox
        )

        settings_form.addRow(
            "Node ID:",
            self.settings_node_label
        )

        settings_form.addRow(
            "TCP port:",
            self.settings_port_label
        )

        settings_form.addRow(
            "Bluetooth:",
            self.settings_bluetooth_label
        )

        settings_form.addRow(
            "Server:",
            self.settings_server_input
        )

        settings_form.addRow(
            "Invite token:",
            self.settings_server_token_input
        )

        settings_form.addRow(
            "Login:",
            self.settings_server_login_input
        )

        settings_form.addRow(
            "Password:",
            self.settings_server_password_input
        )

        settings_form.addRow(
            "Status:",
            self.settings_server_status_label
        )

        settings_form.addRow(
            "Database:",
            self.settings_database_label
        )

        settings_form.labelForField(
            self.settings_server_login_input
        ).setText(
            "Login:"
        )

        settings_form.labelForField(
            self.settings_server_status_label
        ).setText(
            "Status:"
        )

        settings_layout.addLayout(
            settings_form
        )

        settings_layout.addWidget(
            self.settings_save_button
        )

        settings_layout.addWidget(
            self.settings_server_test_button
        )

        settings_layout.addWidget(
            self.settings_logout_button
        )

        self.settings_tab.setLayout(
            settings_layout
        )

        self.tabs.addTab(
            self.chats_tab,
            "Chats"
        )

        self.tabs.addTab(
            self.bluetooth_tab,
            "Bluetooth"
        )

        self.tabs.addTab(
            self.settings_tab,
            "Settings"
        )

        header_layout = QHBoxLayout()

        header_layout.addWidget(
            self.logo_label
        )

        header_layout.addWidget(
            self.header_avatar_label
        )

        header_layout.addWidget(
            self.me_label
        )

        header_layout.addStretch()

        layout.addLayout(
            header_layout
        )

        layout.addWidget(
            self.tabs
        )

        self.setLayout(
            layout
        )

        self.users_list.itemSelectionChanged.connect(
            self.user_selected
        )

        self.chat_button.clicked.connect(
            self.start_chat
        )

        self.create_group_button.clicked.connect(
            self.create_group_dialog
        )

        self.archive_button.clicked.connect(
            self.toggle_archive
        )

        self.username_search_button.clicked.connect(
            self.lookup_username
        )

        self.username_search_input.returnPressed.connect(
            self.lookup_username
        )

        self.rename_button.clicked.connect(
            self.change_name
        )

        self.settings_avatar_button.clicked.connect(
            self.choose_profile_avatar
        )

        self.settings_save_button.clicked.connect(
            self.save_settings
        )

        self.settings_server_test_button.clicked.connect(
            self.test_server_connection
        )

        self.settings_logout_button.clicked.connect(
            self.logout_server_account
        )

        self.bluetooth_button.clicked.connect(
            self.open_bluetooth_chat_dialog
        )

        self.bluetooth_scan_button.clicked.connect(
            self.scan_bluetooth_contacts
        )

        self.bluetooth_scan_done.connect(
            self.show_bluetooth_scan_result
        )

        self.pending_message_sent.connect(
            self.mark_pending_message_sent
        )

        self.server_users_signal.connect(
            self.update_server_users
        )

        self.server_status_signal.connect(
            self.update_server_status
        )

        self.server_test_done_signal.connect(
            self.finish_server_connection_test
        )

        self.incoming_request.connect(
            self.show_chat_request
        )

        self.timer = QTimer()

        self.timer.timeout.connect(
            self.refresh_users
        )

        self.timer.start(
            1000
        )

        self.pending_requests = {}

        self.chats_list.itemDoubleClicked.connect(
            self.open_saved_chat
        )

        self.chats_list.setContextMenuPolicy(
            Qt.ContextMenuPolicy.CustomContextMenu
        )

        self.chats_list.customContextMenuRequested.connect(
            self.show_chat_context_menu
        )

        self.packet_cache_timer = QTimer()

        self.packet_cache_timer.timeout.connect(
            self.packet_cache.cleanup
        )

        self.packet_cache_timer.start(
            60000
        )

        self.pending_retry_timer = QTimer()

        self.pending_retry_timer.timeout.connect(
            self.retry_pending_messages
        )

        self.pending_retry_timer.start(
            5000
        )

        self.update_bluetooth_status()
        self.update_profile_avatar_labels()

        self.start_server_transport()


    def update_profile_avatar_labels(self):

        self.header_avatar_label.setPixmap(
            round_pixmap(
                self.profile_avatar_path,
                46,
                self.username,
                self.node_id
            )
        )

        self.settings_avatar_label.setPixmap(
            round_pixmap(
                self.profile_avatar_path,
                64,
                self.username,
                self.node_id
            )
        )


    def choose_profile_avatar(self):

        path, _ = QFileDialog.getOpenFileName(
            self,
            "Choose avatar",
            "",
            "Images (*.png *.jpg *.jpeg *.webp *.bmp)"
        )

        if not path:
            return

        self.profile_avatar_path = path
        self.profile_avatar_data = self.encode_avatar_file(
            path
        )
        self.update_profile_avatar_labels()


    def encode_avatar_file(
        self,
        path
    ):

        pixmap = QPixmap(
            path
        )

        if pixmap.isNull():
            return ""

        pixmap = pixmap.scaled(
            256,
            256,
            Qt.AspectRatioMode.KeepAspectRatioByExpanding,
            Qt.TransformationMode.SmoothTransformation
        )

        data = QByteArray()
        buffer = QBuffer(
            data
        )

        buffer.open(
            QIODevice.OpenModeFlag.WriteOnly
        )

        pixmap.save(
            buffer,
            "PNG"
        )

        return base64.b64encode(
            bytes(data)
        ).decode(
            "ascii"
        )


    def save_profile_avatar_data(
        self,
        node_id,
        avatar_data
    ):

        if not avatar_data:
            return ""

        try:

            raw = base64.b64decode(
                avatar_data
            )

        except Exception:

            return ""

        profile_dir = get_database_dir() / "avatars"

        profile_dir.mkdir(
            parents=True,
            exist_ok=True
        )

        avatar_path = profile_dir / f"{node_id}.png"

        avatar_path.write_bytes(
            raw
        )

        return str(
            avatar_path
        )


    def apply_profile_data(
        self,
        profile
    ):

        if not profile:
            return

        node_id = profile.get(
            "node_id"
        )

        if not node_id:
            return

        display_name = profile.get(
            "display_name"
        ) or node_id[:8]

        about = profile.get(
            "about"
        ) or ""

        avatar_data = profile.get(
            "avatar_data"
        ) or ""

        public_username = (
            profile.get(
                "public_username"
            )
            or ""
        ).strip().lower().lstrip("@")

        avatar_path = self.save_profile_avatar_data(
            node_id,
            avatar_data
        )

        self.db.update_user(
            node_id,
            display_name,
            "SERVER" if node_id != self.node_id else "LOCAL",
            0 if node_id != self.node_id else self.port
        )

        self.db.update_user_profile(
            node_id,
            avatar_path or None,
            about,
            public_username or None,
            profile.get("encryption_public_key") or None
        )

        if node_id == self.node_id:

            if display_name:

                self.username = display_name
                self.settings_name_input.setText(
                    display_name
                )
                self.me_label.setText(
                    f"You: {display_name}\nID: {self.node_id[:8]}"
                )
                self.setWindowTitle(
                    f"MeshChat - {display_name}"
                )
                self.db.set_setting(
                    "username",
                    display_name
                )

            if avatar_path:
                self.profile_avatar_path = avatar_path

            if avatar_data:
                self.profile_avatar_data = avatar_data

            self.profile_about = about
            self.settings_about_input.setText(
                about
            )

            if public_username:

                self.public_username = public_username
                self.settings_public_username_input.setText(
                    public_username
                )

            self.db.set_setting(
                "profile_avatar_path",
                self.profile_avatar_path
            )

            self.db.set_setting(
                "profile_avatar_data",
                self.profile_avatar_data
            )

            self.db.set_setting(
                "profile_about",
                self.profile_about
            )

            self.db.set_setting(
                "public_username",
                self.public_username
            )

            self.update_profile_avatar_labels()

        chat = self.chat_windows.get(
            node_id
        )

        if chat and hasattr(
            chat,
            "update_peer_header"
        ):

            chat.update_peer_header()


    def build_profile_packet(self):

        if (
            self.profile_avatar_path
            and not self.profile_avatar_data
        ):

            self.profile_avatar_data = self.encode_avatar_file(
                self.profile_avatar_path
            )

            self.db.set_setting(
                "profile_avatar_data",
                self.profile_avatar_data
            )

        return {
            "type": "profile_update",
            "source_node": self.node_id,
            "login": self.server_login,
            "display_name": self.username,
            "public_username": self.public_username,
            "about": self.profile_about,
            "avatar_data": self.profile_avatar_data,
            "encryption_public_key": self.encryption_public_key
        }

    def encrypt_direct_message(
        self,
        peer_node_id,
        text
    ):

        public_key = self.db.get_user_encryption_key(
            peer_node_id
        )

        return self.encryption.encrypt_text(
            public_key,
            text
        )

    def decrypt_direct_message(
        self,
        text
    ):

        return self.encryption.decrypt_text(
            text
        )

    def encrypt_direct_file(
        self,
        peer_node_id,
        filename,
        data
    ):

        public_key = self.db.get_user_encryption_key(
            peer_node_id
        )

        if not public_key:
            return filename, data

        return (
            self.encryption.encrypt_text(
                public_key,
                filename
            ),
            self.encryption.encrypt_bytes(
                public_key,
                data
            )
        )

    def decrypt_direct_file(
        self,
        filename,
        data_hex
    ):

        try:
            data = self.encryption.decrypt_bytes(
                bytes.fromhex(
                    data_hex
                )
            )
            filename = self.encryption.decrypt_text(
                filename
            )
            return filename, data.hex()
        except (ValueError, TypeError):
            return filename, data_hex

    def create_group_encryption_key(
        self,
        group_id
    ):

        key_id = (
            f"{int(time.time() * 1000):013d}-"
            f"{generate_message_id()}"
        )
        group_key = self.encryption.generate_group_key()
        own_envelope = self.encryption.wrap_group_key(
            self.encryption_public_key,
            group_key
        )

        self.db.save_group_encryption_key(
            group_id,
            key_id,
            own_envelope,
            True
        )

        return key_id, group_key

    def get_group_encryption_key(
        self,
        group_id,
        key_id=None,
        create=False
    ):

        row = self.db.get_group_encryption_key(
            group_id,
            key_id
        )

        if row:

            try:
                return (
                    row[0],
                    self.encryption.unwrap_group_key(
                        row[1]
                    )
                )
            except ValueError:
                pass

        if create and key_id is None:
            return self.create_group_encryption_key(
                group_id
            )

        return "", None

    def build_group_key_envelope(
        self,
        group_id,
        member_node,
        key_id=None
    ):

        resolved_key_id, group_key = self.get_group_encryption_key(
            group_id,
            key_id,
            create=True
        )

        public_key = (
            self.encryption_public_key
            if member_node == self.node_id
            else self.db.get_user_encryption_key(
                member_node
            )
        )

        if not group_key or not public_key:
            return resolved_key_id, ""

        return (
            resolved_key_id,
            self.encryption.wrap_group_key(
                public_key,
                group_key
            )
        )

    def accept_group_key_envelope(
        self,
        group_id,
        key_id,
        envelope,
        active=True
    ):

        if not group_id or not key_id or not envelope:
            return False

        try:
            group_key = self.encryption.unwrap_group_key(
                envelope
            )
        except ValueError:
            return False

        own_envelope = self.encryption.wrap_group_key(
            self.encryption_public_key,
            group_key
        )

        current = self.db.get_group_encryption_key(
            group_id
        )

        make_active = (
            active
            and (
                not current
                or key_id >= current[0]
            )
        )

        self.db.save_group_encryption_key(
            group_id,
            key_id,
            own_envelope,
            make_active
        )

        return True

    def encrypt_group_text(
        self,
        group_id,
        text
    ):

        key_id, group_key = self.get_group_encryption_key(
            group_id,
            create=True
        )

        return (
            key_id,
            self.encryption.encrypt_group_text(
                group_key,
                text
            )
        )

    def decrypt_group_text(
        self,
        group_id,
        key_id,
        text
    ):

        if not key_id:
            return text

        _, group_key = self.get_group_encryption_key(
            group_id,
            key_id
        )

        if not group_key:
            return "[Encrypted message: group key unavailable]"

        try:
            return self.encryption.decrypt_group_text(
                group_key,
                text
            )
        except Exception:
            return "[Encrypted message: decrypt failed]"

    def encrypt_group_file(self, group_id, filename, data):
        key_id, group_key = self.get_group_encryption_key(
            group_id,
            create=True
        )
        return (
            key_id,
            self.encryption.encrypt_group_text(group_key, filename),
            self.encryption.encrypt_group_bytes(group_key, data)
        )

    def decrypt_group_file(
        self,
        group_id,
        key_id,
        filename,
        data_hex
    ):
        if not key_id:
            return filename, data_hex

        _, group_key = self.get_group_encryption_key(
            group_id,
            key_id
        )
        if not group_key:
            return filename, data_hex

        try:
            return (
                self.encryption.decrypt_group_text(group_key, filename),
                self.encryption.decrypt_group_bytes(
                    group_key,
                    bytes.fromhex(data_hex)
                ).hex()
            )
        except Exception:
            return filename, data_hex

    def group_members_missing_encryption_keys(
        self,
        group_id,
        members=None
    ):

        members = members or self.db.get_group_members(
            group_id
        )

        return [
            member
            for member in members
            if (
                member != self.node_id
                and not self.db.get_user_encryption_key(
                    member
                )
            )
        ]


    def save_settings(self):

        name = self.settings_name_input.text().strip()

        if not name:

            QMessageBox.warning(
                self,
                "Settings",
                "Enter a name."
            )

            return

        self.username = name

        self.me_label.setText(
            f"You: {name}\nID: {self.node_id[:8]}"
        )

        self.setWindowTitle(
            f"MeshChat - {name}"
        )

        self.db.set_setting(
            f"username_{self.port}",
            name
        )

        self.db.set_setting(
            "username",
            name
        )

        self.profile_about = self.settings_about_input.text().strip()
        self.public_username = (
            self.settings_public_username_input.text()
            .strip()
            .lower()
            .lstrip("@")
        )

        self.db.set_setting(
            "profile_avatar_path",
            self.profile_avatar_path
        )

        self.db.set_setting(
            "profile_avatar_data",
            self.profile_avatar_data
        )

        self.db.set_setting(
            "profile_about",
            self.profile_about
        )

        self.db.set_setting(
            "public_username",
            self.public_username
        )

        self.compress_images = (
            self.settings_compress_images_checkbox.isChecked()
        )

        self.db.set_setting(
            "compress_images",
            "1" if self.compress_images else "0"
        )

        self.db.update_user(
            self.node_id,
            name,
            "LOCAL",
            self.port
        )

        self.db.update_user_profile(
            self.node_id,
            self.profile_avatar_path,
            self.profile_about,
            self.public_username or None,
            self.encryption_public_key
        )

        self.update_profile_avatar_labels()

        if self.server_transport:

            self.send_server_packet(
                self.build_profile_packet()
            )

        new_server_url = normalize_server_url(
            self.settings_server_input.text()
        )

        self.settings_server_input.setText(
            new_server_url
        )

        self.db.set_setting(
            "server_url",
            new_server_url
        )

        new_server_token = self.settings_server_token_input.text().strip()

        self.db.set_setting(
            "server_token",
            new_server_token
        )

        new_server_login = self.settings_server_login_input.text().strip()

        self.db.set_setting(
            "server_login",
            new_server_login
        )

        new_server_password = self.settings_server_password_input.text()

        self.db.set_setting(
            "server_password",
            new_server_password
        )

        self.save_global_server_settings(
            new_server_url,
            new_server_token,
            new_server_login,
            new_server_password
        )

        if (
            new_server_url != self.server_url
            or new_server_token != self.server_token
            or new_server_login != self.server_login
            or new_server_password != self.server_password
        ):

            self.server_url = new_server_url
            self.server_token = new_server_token
            self.server_login = new_server_login
            self.server_password = new_server_password
            self.start_server_transport()

        QMessageBox.information(
            self,
            "Settings",
            "Settings saved."
        )
