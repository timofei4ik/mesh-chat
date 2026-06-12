import socket
from PyQt6.QtCore import (
    QTimer,
    pyqtSignal
)

from PyQt6.QtWidgets import (
    QWidget,
    QVBoxLayout,
    QLabel,
    QListWidget,
    QPushButton,
    QMessageBox
)

from gui.request_dialog import ChatRequestDialog
from gui.chat_window import ChatWindow
from storage.database import Database
from PyQt6.QtWidgets import QInputDialog
from network.packet_cache import PacketCache
from PyQt6.QtWidgets import QListWidgetItem
from network.router import forward_packet
from network.routing_table import RoutingTable
from PyQt6.QtWidgets import QFileDialog
import base64


from network.client import (
    send_packet,
    send_chat_response
)



class MainWindow(QWidget):

    incoming_request = pyqtSignal(dict)
    incoming_response = pyqtSignal(dict)

    file_received_signal = pyqtSignal(
        str,  #sender
        str,  #sender_node_id
        str,  #filename
        str   #data
    )

    def __init__(
        self,
        username,
        discovery,
        node_id
    ):

        self.chat_windows = {}

        self.port = discovery.tcp_port
        self.routing_table = RoutingTable()

        super().__init__()

        self.username = username
        self.node_id = node_id
        self.discovery = discovery
        self.db = Database()
        self.packet_cache = PacketCache()

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

        self.chat_button.setEnabled(
            False
        )

        layout.addWidget(
            self.me_label
        )

        layout.addWidget(
            self.users_label
        )

        layout.addWidget(
            self.users_list
        )

        layout.addWidget(
            self.chats_label
        )

        layout.addWidget(
            self.chats_list
        )

        layout.addWidget(
            self.info_label
        )

        layout.addWidget(
            self.chat_button
        )

        layout.addWidget(
            self.rename_button
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

        self.route_timer = QTimer()

        self.route_timer.timeout.connect(
            self.print_routes
        )

        self.route_timer.start(
            5000
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

        from network.message_id import generate_message_id

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

        print(
            "CALL SEND:",
            repr(ip),
            repr(port)
        )

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

        print(
            "PACKET:",
            packet.get("type"),
            packet.get("source_node"),
            "->",
            packet.get("destination_node")
        )

        if not isinstance(packet, dict):
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

                print(
                    "FORWARDING:",
                    packet_type,
                    "->",
                    destination_node
                )

                print(
                    "FORWARDING PACKET"
                )
                
                forward_packet(
                    self.discovery,
                    self.node_id,
                    packet
                )

                return

        if packet_type == "chat_request":

            self.incoming_request.emit(packet)

        elif packet_type == "chat_response":

            self.incoming_response.emit(packet)

        elif packet_type == "chat_message":

            sender_node_id = packet.get("source_node")
            sender = packet.get("sender")
            message = packet.get("message")

            if not sender_node_id or not message:
                return

            if sender_node_id in self.chat_windows:

                self.chat_windows[sender_node_id].receive_message(
                    sender,
                    sender_node_id,
                    message
                )

            else:

                self.db.save_message(
                    sender_node_id,
                    self.node_id,
                    message
                )

                self.db.add_unread(
                    sender_node_id,
                    self.node_id
                )

        elif packet_type == "file_message":

            sender = packet.get(
                "sender"
            )

            sender_node_id = packet.get(
                "source_node"
            )

            filename = packet.get(
                "filename"
            )

            data = packet.get(
                "data"
            )

            self.db.save_file(
                sender_node_id,
                self.node_id,
                filename,
                data
            )

            if sender_node_id in self.chat_windows:

                self.show_file_message(
                    sender,
                    sender_node_id,
                    filename,
                    data
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
        peer_port
    ):

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
            peer_port
        )

        chat.show()

        self.chat_windows[
            peer_node_id
        ] = chat

    def show_chat_response(
            self,
            packet
    ):
        
        print(
            "SHOW CHAT RESPONSE:",
            packet
        )
        
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

    def refresh_chats(self):


        contacts = self.db.get_contacts(
            self.node_id
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

            prefix = "⚫"

            if online:
                prefix = "🟢"

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

        self.username = name

        self.me_label.setText(
            f"Вы: {name}"
        )

        self.db.set_setting(
            f"username_{self.port}",
            name
        )

        QMessageBox.information(
            self,
            "MeshChat",
            "Имя сохранено.\nПерезапустите приложение."
        )

    def route_packet(
    self,
    packet
):

        if not self.router.should_forward(
            packet
        ):
            return False

        if not self.router.decrease_ttl(
            packet
        ):
            return False

        print(
            "FORWARD:",
            packet
        )

        return True
    
    def print_routes(self):

        print(
            "ROUTES:"
        )

        for node_id, route in self.routing_table.get_all_routes().items():

            print(
                node_id,
                route
            )


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