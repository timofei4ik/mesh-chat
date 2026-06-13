import socket
import threading
from PyQt6.QtCore import (
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
    QMessageBox,
    QSystemTrayIcon,
    QApplication,
    QStyle,
    QTabWidget
)

from gui.request_dialog import ChatRequestDialog
from gui.chat_window import ChatWindow
from storage.database import Database
from PyQt6.QtWidgets import QInputDialog
from network.packet_cache import PacketCache
from PyQt6.QtWidgets import QListWidgetItem
from network.router import forward_packet
from network.message_id import generate_message_id
from network.bluetooth_transport import send_bluetooth_packet
from network.bluetooth_discovery import (
    get_local_bluetooth_address,
    get_paired_bluetooth_devices
)


from network.client import (
    send_packet,
    send_chat_response
)



class MainWindow(QWidget):

    incoming_request = pyqtSignal(dict)
    incoming_response = pyqtSignal(dict)
    packet_signal = pyqtSignal(dict)

    file_received_signal = pyqtSignal(
        str,  #sender
        str,  #sender_node_id
        str,  #filename
        str   #data
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

    def __init__(
        self,
        username,
        discovery,
        node_id,
        bluetooth_channel=None
    ):

        self.chat_windows = {}
        self.file_chunks = {}
        self.pending_sent_files = {}
        self.pending_retry_in_progress = False

        self.port = discovery.tcp_port
        self.bluetooth_channel = bluetooth_channel
        self.bluetooth_address = get_local_bluetooth_address()

        super().__init__()

        self.username = username
        self.node_id = node_id
        self.discovery = discovery
        self.db = Database()
        self.packet_cache = PacketCache()

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

        self.incoming_response.connect(
            self.show_chat_response
        )

        self.resize(
            600,
            500
        )

        self.tray_icon = None
        self.setup_notifications()

        layout = QVBoxLayout()

        self.me_label = QLabel(
            f"Вы: {username}\nID: {node_id[:8]}"
        )

        self.users_label = QLabel(
            "Пользователи сети"
        )

        self.users_list = QListWidget()

        self.chats_label = QLabel(
            "Мои чаты"
        )

        self.chats_list = QListWidget()

        self.info_label = QLabel(
            "Выберите пользователя"
        )

        self.chat_button = QPushButton(
            "Начать чат"
        )

        self.rename_button = QPushButton(
            "Изменить имя"
        )

        self.bluetooth_button = QPushButton(
            "Bluetooth чат"
        )

        self.bluetooth_scan_button = QPushButton(
            "Найти Bluetooth"
        )

        self.bluetooth_status_label = QLabel(
            "Bluetooth не запущен"
        )

        self.settings_name_input = QLineEdit(
            username
        )

        self.settings_save_button = QPushButton(
            "Сохранить"
        )

        self.settings_node_label = QLabel(
            node_id
        )

        self.settings_port_label = QLabel(
            str(self.port)
        )

        self.settings_database_label = QLabel(
            "messages.db"
        )

        self.settings_bluetooth_label = QLabel(
            ""
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

        chats_layout.addWidget(
            self.chats_label
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
            "Подключайтесь вручную или найдите спаренные устройства MeshChat."
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
            "Имя:",
            self.settings_name_input
        )

        settings_form.addRow(
            "Node ID:",
            self.settings_node_label
        )

        settings_form.addRow(
            "TCP порт:",
            self.settings_port_label
        )

        settings_form.addRow(
            "Bluetooth:",
            self.settings_bluetooth_label
        )

        settings_form.addRow(
            "База:",
            self.settings_database_label
        )

        settings_layout.addLayout(
            settings_form
        )

        settings_layout.addWidget(
            self.settings_save_button
        )

        self.settings_tab.setLayout(
            settings_layout
        )

        self.tabs.addTab(
            self.network_tab,
            "Сеть"
        )

        self.tabs.addTab(
            self.chats_tab,
            "Чаты"
        )

        self.tabs.addTab(
            self.bluetooth_tab,
            "Bluetooth"
        )

        self.tabs.addTab(
            self.settings_tab,
            "Настройки"
        )

        layout.addWidget(
            self.me_label
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

        self.rename_button.clicked.connect(
            self.change_name
        )

        self.settings_save_button.clicked.connect(
            self.save_settings
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

    def setup_notifications(self):

        if not QSystemTrayIcon.isSystemTrayAvailable():
            return

        icon = QApplication.style().standardIcon(
            QStyle.StandardPixmap.SP_MessageBoxInformation
        )

        self.tray_icon = QSystemTrayIcon(
            icon,
            self
        )

        self.tray_icon.setToolTip(
            "MeshChat"
        )

        self.tray_icon.show()

    def notify(
        self,
        title,
        message
    ):

        if not self.tray_icon:
            return

        if not self.tray_icon.isVisible():
            self.tray_icon.show()

        self.tray_icon.showMessage(
            title,
            message,
            QSystemTrayIcon.MessageIcon.Information,
            5000
        )

    def set_bluetooth_channel(
        self,
        channel
    ):

        self.bluetooth_channel = channel
        self.update_bluetooth_status()

        print(
            "MeshChat Bluetooth channel:",
            channel
        )

    def update_bluetooth_status(self):

        if self.bluetooth_channel is None:

            status = "Bluetooth сервер не запущен"

        else:

            address = self.bluetooth_address or "не найден"

            status = (
                f"MAC: {address} | "
                f"channel: {self.bluetooth_channel}"
            )

        self.bluetooth_status_label.setText(
            status
        )

        self.settings_bluetooth_label.setText(
            status
        )

    def save_settings(self):

        name = self.settings_name_input.text().strip()

        if not name:

            QMessageBox.warning(
                self,
                "Настройки",
                "Введите имя."
            )

            return

        self.username = name

        self.me_label.setText(
            f"Вы: {name}\nID: {self.node_id[:8]}"
        )

        self.setWindowTitle(
            f"MeshChat - {name}"
        )

        self.db.set_setting(
            f"username_{self.port}",
            name
        )

        QMessageBox.information(
            self,
            "Настройки",
            "Настройки сохранены."
        )

    def scan_bluetooth_contacts(self):

        if self.bluetooth_channel is None:

            QMessageBox.warning(
                self,
                "Bluetooth",
                "Запустите приложение с --bluetooth-channel 0."
            )

            return

        if not self.bluetooth_address:

            QMessageBox.warning(
                self,
                "Bluetooth",
                "Не удалось определить Bluetooth MAC этого компьютера."
            )

            return

        self.bluetooth_scan_button.setEnabled(
            False
        )

        threading.Thread(
            target=self.run_bluetooth_scan,
            daemon=True
        ).start()

    def run_bluetooth_scan(self):

        devices = get_paired_bluetooth_devices()
        attempts = 0

        print(
            "Bluetooth paired devices:",
            devices
        )

        for device in devices:

            address = device["address"]

            if address == self.bluetooth_address:
                continue

            packet = {

                "packet_id":
                generate_message_id(),

                "type":
                "bluetooth_hello",

                "source_node":
                self.node_id,

                "sender":
                self.username,

                "source_bluetooth_address":
                self.bluetooth_address,

                "source_bluetooth_channel":
                self.bluetooth_channel or 0
            }

            for channel in range(
                1,
                31
            ):

                if send_bluetooth_packet(
                    address,
                    channel,
                    packet
                ):

                    attempts += 1

        self.bluetooth_scan_done.emit(
            attempts
        )

    def show_bluetooth_scan_result(
        self,
        attempts
    ):

        self.bluetooth_scan_button.setEnabled(
            True
        )

        QMessageBox.information(
            self,
            "Bluetooth",
            f"Отправлено запросов обнаружения: {attempts}"
        )

    def handle_bluetooth_hello(
        self,
        packet
    ):

        peer_node_id = packet.get(
            "source_node"
        )

        peer_name = packet.get(
            "sender"
        ) or "Bluetooth"

        peer_address = (
            packet.get("remote_bluetooth_address")
            or packet.get("source_bluetooth_address")
        )

        peer_channel = packet.get(
            "source_bluetooth_channel",
            0
        )

        if not peer_node_id or not peer_address:
            return

        self.save_bluetooth_contact(
            peer_node_id,
            peer_name,
            peer_address,
            peer_channel
        )

        if self.bluetooth_address:

            response = {

                "packet_id":
                generate_message_id(),

                "type":
                "bluetooth_hello_response",

                "source_node":
                self.node_id,

                "destination_node":
                peer_node_id,

                "sender":
                self.username,

                "source_bluetooth_address":
                self.bluetooth_address,

                "source_bluetooth_channel":
                self.bluetooth_channel or 0
            }

            send_bluetooth_packet(
                peer_address,
                peer_channel,
                response
            )

        self.notify(
            "Bluetooth",
            f"Найден {peer_name}"
        )

        self.refresh_chats()

    def handle_bluetooth_hello_response(
        self,
        packet
    ):

        peer_node_id = packet.get(
            "source_node"
        )

        peer_name = packet.get(
            "sender"
        ) or "Bluetooth"

        peer_address = (
            packet.get("remote_bluetooth_address")
            or packet.get("source_bluetooth_address")
        )

        peer_channel = packet.get(
            "source_bluetooth_channel",
            0
        )

        if not peer_node_id or not peer_address:
            return

        self.save_bluetooth_contact(
            peer_node_id,
            peer_name,
            peer_address,
            peer_channel
        )

        self.notify(
            "Bluetooth",
            f"Добавлен {peer_name}"
        )

        self.refresh_chats()

    def save_bluetooth_contact(
        self,
        peer_node_id,
        peer_name,
        bluetooth_address,
        bluetooth_channel
    ):

        self.db.update_user(
            peer_node_id,
            peer_name,
            f"BT:{bluetooth_address}",
            bluetooth_channel
        )

    def retry_pending_messages(self):

        if self.pending_retry_in_progress:
            return

        self.pending_retry_in_progress = True

        threading.Thread(
            target=self.run_pending_retry,
            daemon=True
        ).start()

    def run_pending_retry(self):

        try:

            pending_messages = self.db.get_pending_messages(
                self.node_id
            )

            for (
                message_id,
                receiver_node,
                message,
                attempts
            ) in pending_messages:

                packet = {

                    "packet_id":
                    message_id,

                    "type":
                    "chat_message",

                    "source_node":
                    self.node_id,

                    "destination_node":
                    receiver_node,

                    "ttl":
                    5,

                    "sender":
                    self.username,

                    "message":
                    message
                }

                sent = self.send_pending_packet(
                    receiver_node,
                    packet
                )

                if sent:

                    self.db.remove_pending_message(
                        message_id
                    )

                    self.pending_message_sent.emit(
                        message_id
                    )

                else:

                    self.db.mark_pending_attempt(
                        message_id
                    )

        finally:

            self.pending_retry_in_progress = False

    def send_pending_packet(
        self,
        receiver_node,
        packet
    ):

        info = self.db.get_user_info(
            receiver_node
        )

        if info:

            _, ip, port = info

            if (
                isinstance(
                    ip,
                    str
                )
                and ip.startswith("BT:")
            ):

                return send_bluetooth_packet(
                    ip[3:],
                    port,
                    packet
                )

        peer = self.discovery.get_user_by_node_id(
            receiver_node
        )

        if not peer:
            return False

        ip, port = peer

        return send_packet(
            ip,
            port,
            packet
        )

    def mark_pending_message_sent(
        self,
        message_id
    ):

        for chat in self.chat_windows.values():

            chat.mark_message_sent(
                message_id
            )

    def refresh_users(self):

        users = self.discovery.get_users()

        current = None

        if self.selected_user:
            current = self.selected_user[0]

        self.users_list.clear()

        for node_id, name, ip, port in users:

            self.users_list.addItem(
                f"{name} [{node_id[:8]}]"
            )

        self.refresh_chats()

    def user_selected(self):

        row = self.users_list.currentRow()

        users = self.discovery.get_users()

        if row < 0:
            return

        if row >= len(users):
            return

        self.selected_user = users[row]

        node_id, name, ip, port = self.selected_user

        self.info_label.setText(
            f"""
            Имя: {name}

            Node ID:
            {node_id[:8]}

            IP:
            {ip}

            Порт:
            {port}
            """
    )

        self.chat_button.setEnabled(
            True
        )

    def start_chat(self):

        if not self.selected_user:
            return

        peer_node_id, name, ip, port = self.selected_user

        sender_ip = socket.gethostbyname(
            socket.gethostname()
        )

        packet = {

            "packet_id": generate_message_id(),

            "type": "chat_request",

            "source_node": self.node_id,

            "destination_node": peer_node_id,

            "ttl": 5,

            "from_name": self.username,

            "from_node_id": self.node_id,

            "sender_ip": sender_ip,

            "sender_port": self.discovery.tcp_port
        }

        send_packet(
            ip,
            port,
            packet
        )

        QMessageBox.information(
            self,
            "MeshChat",
            f"Запрос отправлен пользователю {name}"
        )

    def handle_packet(self, packet):

        if not isinstance(packet, dict):
            return

        source_node = packet.get(
            "source_node"
        )

        if source_node == self.node_id:
            return

        packet_id = packet.get("packet_id")

        if packet_id:
            if self.packet_cache.exists(packet_id):
                return
            self.packet_cache.add(packet_id)

        packet_type = packet.get("type")

        destination_node = packet.get(
            "destination_node"
        )

        if destination_node:

            if destination_node != self.node_id:

                
                forward_packet(
                    self.discovery,
                    self.node_id,
                    packet
                )

                return

        if packet_type == "chat_request":

            self.incoming_request.emit(packet)

        elif packet_type == "bluetooth_hello":

            self.handle_bluetooth_hello(
                packet
            )

        elif packet_type == "bluetooth_hello_response":

            self.handle_bluetooth_hello_response(
                packet
            )

        elif packet_type == "chat_response":

            self.incoming_response.emit(packet)

        elif packet_type == "chat_message":

            sender_node_id = packet.get("source_node")
            sender = packet.get("sender")
            message = packet.get("message")
            sender_ip = packet.get("sender_ip")
            sender_port = packet.get("sender_port")

            ack_packet = {

                "packet_id":
                generate_message_id(),

                "type":
                "message_received",

                "source_node":
                self.node_id,

                "destination_node":
                sender_node_id,

                "ttl":
                5,

                "message_id":
                packet.get("packet_id")
            }

            self.send_packet_to_contact(
                sender_node_id,
                ack_packet
            )


            if not sender_node_id or not message:
                return

            if sender and sender_ip:

                self.db.update_user(
                    sender_node_id,
                    sender,
                    sender_ip or "",
                    sender_port or 0
                )

            self.notify(
                f"Новое сообщение от {sender}",
                message
            )

            if sender_node_id in self.chat_windows:


                self.chat_windows[sender_node_id].receive_message(
                    sender,
                    sender_node_id,
                    message,
                    packet.get("packet_id")
                )

            else:

                self.db.save_message(
                    sender_node_id,
                    self.node_id,
                    message,
                    packet.get("packet_id")
                )

                self.db.add_unread(
                    sender_node_id,
                    self.node_id
                )

        elif packet_type == "file_chunk":

            sender = packet.get(
                "sender"
            )

            sender_node_id = packet.get(
                "source_node"
            )

            file_id = packet.get(
                "file_id"
            )

            filename = packet.get(
                "filename"
            )

            chunk_index = packet.get(
                "chunk_index"
            )

            total_chunks = packet.get(
                "total_chunks"
            )

            data = packet.get(
                "data"
            )

            if file_id not in self.file_chunks:

                self.file_chunks[
                    file_id
                ] = {

                    "sender": sender,

                    "sender_node_id": sender_node_id,

                    "filename": filename,

                    "total_chunks": total_chunks,

                    "chunks": {}
                }

            self.file_chunks[
                file_id
            ][
                "chunks"
            ][
                chunk_index
            ] = data

            file_info = self.file_chunks[
                file_id
            ]

            if len(
                file_info["chunks"]
            ) == file_info["total_chunks"]:
                
                print(
            "FILE COMPLETE:",
            filename
        )
                        
                ack_packet = {

                    "packet_id":
                    generate_message_id(),

                    "type":
                    "file_complete",

                    "source_node":
                    self.node_id,

                    "destination_node":
                    sender_node_id,

                    "file_id":
                        file_id
                }

                self.send_packet_to_contact(
                    sender_node_id,
                    ack_packet
                )

                full_data = "".join(

                    file_info[
                        "chunks"
                    ][i]

                    for i in range(
                        file_info[
                            "total_chunks"
                        ]
                    )
                )

                self.db.save_file(
                    sender_node_id,
                    self.node_id,
                    filename,
                    full_data
                )

                self.notify(
                    f"Файл от {sender}",
                    filename
                )

                if sender_node_id in self.chat_windows:

                    self.file_received_signal.emit(
                        sender,
                        sender_node_id,
                        filename,
                        full_data
                    )

                del self.file_chunks[
                    file_id
                ]

        elif packet_type == "file_complete":

            file_id = packet.get(
                "file_id"
            )

            if file_id in self.pending_sent_files:

                filename = self.pending_sent_files[
                    file_id
                ]

                print(
                    "FILE DELIVERED:",
                    filename
                )

                del self.pending_sent_files[
                    file_id
                ]

        elif packet_type == "typing":

            sender = packet.get(
                "sender"
            )

            sender_node_id = packet.get(
                "source_node"
            )

            self.typing_signal.emit(
                sender,
                sender_node_id
            )

        elif packet_type == "message_received":

            message_id = packet.get(
                "message_id"
            )

            if message_id:

                self.db.remove_pending_message(
                    message_id
                )

            for chat in self.chat_windows.values():

                chat.mark_message_delivered(
                    message_id
                )
    
    def show_chat_request(
            self,
            packet
    ):
        
        username = packet.get(
            "from_name"
        )

        peer_node_id = packet.get(
            "from_node_id"
        )

        sender_ip = packet.get(
            "sender_ip"
        )

        sender_port = packet.get(
            "sender_port"
        )

        self.notify(
            "Новый запрос",
            f"{username} хочет начать чат"
        )

        accepted = ChatRequestDialog.show(
            self,
            username
        )


        if accepted:

            self.open_chat(
                username,
                peer_node_id,
                sender_ip,
                sender_port
            )

        send_chat_response(
            sender_ip,
            sender_port,
            accepted,
            self.node_id,
            peer_node_id
        )

    def open_chat(
        self,
        peer_name,
        peer_node_id,
        peer_ip,
        peer_port,
        transport=None,
        bluetooth_address=None,
        bluetooth_channel=None
    ):
        
        if transport is None:

            transport = "tcp"

            if isinstance(
                peer_ip,
                str
            ) and peer_ip.startswith("BT:"):

                transport = "bluetooth"
                bluetooth_address = peer_ip[3:]
                bluetooth_channel = peer_port

        if peer_node_id in self.chat_windows:

            self.chat_windows[
                peer_node_id
            ].show()

            return

        chat = ChatWindow(
            self.username,
            self.node_id,
            peer_name,
            peer_node_id,
            peer_ip,
            peer_port,
            self.register_pending_file,
            transport,
            bluetooth_address,
            bluetooth_channel
        )

        chat.show()

        self.chat_windows[
            peer_node_id
        ] = chat

    def show_chat_response(
            self,
            packet
    ):
        
        accepted = packet.get(
            "accepted"
        )

        if accepted:

            if not self.selected_user:
                return

            peer_node_id, name, ip, port = self.selected_user

            self.open_chat(
                name,
                peer_node_id,
                ip,
                port
            )

        else:

            QMessageBox.information(
                self,
                "MeshChat",
                "Запрос отклонён"
            )

    def open_bluetooth_chat_dialog(self):

        peer_name, ok = QInputDialog.getText(
            self,
            "Bluetooth чат",
            "Имя контакта:"
        )

        if not ok:
            return

        peer_name = peer_name.strip()

        if not peer_name:
            return

        peer_node_id, ok = QInputDialog.getText(
            self,
            "Bluetooth чат",
            "Node ID второго компьютера:"
        )

        if not ok:
            return

        peer_node_id = peer_node_id.strip()

        if not peer_node_id:
            return

        if peer_node_id == self.node_id:

            QMessageBox.warning(
                self,
                "Bluetooth чат",
                "Это ваш Node ID. Введите Node ID второго компьютера."
            )

            return

        bluetooth_address, ok = QInputDialog.getText(
            self,
            "Bluetooth чат",
            "Bluetooth MAC второго компьютера:"
        )

        if not ok:
            return

        bluetooth_address = bluetooth_address.strip()

        if not bluetooth_address:
            return

        bluetooth_channel, ok = QInputDialog.getInt(
            self,
            "Bluetooth чат",
            "Bluetooth channel второго компьютера:",
            0,
            0,
            30
        )

        if not ok:
            return

        peer_ip = f"BT:{bluetooth_address}"

        self.save_bluetooth_contact(
            peer_node_id,
            peer_name,
            bluetooth_address,
            bluetooth_channel
        )

        self.open_chat(
            peer_name,
            peer_node_id,
            peer_ip,
            bluetooth_channel,
            "bluetooth",
            bluetooth_address,
            bluetooth_channel
        )

    def refresh_chats(self):


        contacts = self.db.get_contacts(
            self.node_id
        )

        contacts = list(
            dict.fromkeys(
                contacts
                + self.db.get_bluetooth_contacts()
            )
        )

        self.chats_list.clear()

        for contact in contacts:

            display_name = self.db.get_user_name(
                contact
            )

            unread = self.db.get_unread(
                contact,
                self.node_id
            )

            online = self.discovery.get_user_by_node_id(
                contact
            )

            prefix = "○"

            if online:
                prefix = "●"

            info = self.db.get_user_info(
                contact
            )

            if (
                info
                and isinstance(
                    info[1],
                    str
                )
                and info[1].startswith("BT:")
            ):

                prefix = "BT"

            title = f"{prefix} {display_name}"

            if unread > 0:

                title += f" ({unread})"

            item = QListWidgetItem(
                title
            )

            item.setData(
                100,
                contact
            )

            self.chats_list.addItem(
                item
            )

    def open_saved_chat(
    self,
    item
):

        peer_node_id = item.data(
            100
        )

        peer = self.discovery.get_user_by_node_id(
            peer_node_id
        )

        if peer:

            ip, port = peer

        else:

            info = self.db.get_user_info(
                peer_node_id
            )

            if info:

                _, ip, port = info

            else:

                ip = "127.0.0.1"
                port = 0

        peer_name = self.db.get_user_name(
            peer_node_id
        )

        self.open_chat(
            peer_name,
            peer_node_id,
            ip,
            port
        )

    def change_name(self):

        name, ok = QInputDialog.getText(
            self,
            "Изменение имени",
            "Введите новое имя:"
        )

        if not ok:
            return

        name = name.strip()

        if not name:
            return

        self.settings_name_input.setText(
            name
        )

        self.save_settings()

    def route_packet(
        self,
        packet
    ):

        ttl = packet.get(
            "ttl",
            0
        )

        if ttl <= 0:
            return False

        packet["ttl"] = ttl - 1

        return True

    def send_packet_to_contact(
        self,
        peer_node_id,
        packet
    ):

        info = self.db.get_user_info(
            peer_node_id
        )

        if info:

            _, ip, port = info

            if (
                isinstance(
                    ip,
                    str
                )
                and ip.startswith("BT:")
            ):

                return send_bluetooth_packet(
                    ip[3:],
                    port,
                    packet
                )

        forward_packet(
            self.discovery,
            self.node_id,
            packet
        )

        return True

    def register_pending_file(
        self,
        file_id,
        filename
    ):

        self.pending_sent_files[
            file_id
        ] = filename


    def show_file_message(
        self,
        sender,
        sender_node_id,
        filename,
        data
    ):

        if sender_node_id in self.chat_windows:

            self.chat_windows[
                sender_node_id
            ].receive_file(
                sender,
                sender_node_id,
                filename,
                data
            )

    def show_message(
        self,
        sender,
        sender_node_id,
        message
    ):

        if sender_node_id in self.chat_windows:

            self.chat_windows[
                sender_node_id
            ].receive_message(
                sender,
                sender_node_id,
                message
            )

    def show_typing(
        self,
        sender,
        sender_node_id
    ):

        if sender_node_id in self.chat_windows:

            self.chat_windows[
                sender_node_id
            ].show_typing(
                sender
            )
