from PyQt6.QtWidgets import (
    QWidget,
    QVBoxLayout,
    QTextEdit,
    QLineEdit,
    QPushButton
)

from network.client import send_packet
from storage.database import Database
from network.message_id import generate_message_id


class ChatWindow(QWidget):

    def __init__(
        self,
        my_name,
        my_node_id,
        peer_name,
        peer_node_id,
        peer_ip,
        peer_port
    ):

        super().__init__()

        self.my_name = my_name
        self.my_node_id = my_node_id
        self.peer_name = peer_name
        self.peer_node_id = peer_node_id
        self.peer_ip = peer_ip
        self.peer_port = peer_port


        self.db = Database()

        self.my_node_id = my_node_id

        self.peer_node_id = peer_node_id

        self.db.clear_unread(
            peer_name,
            my_name
        )

        self.setWindowTitle(
            f"{my_name} ↔ {peer_name}"
        )

        self.resize(
            600,
            500
        )

        layout = QVBoxLayout()

        self.chat_log = QTextEdit()
        self.chat_log.setReadOnly(True)

        self.input = QLineEdit()

        self.send_button = QPushButton(
            "Отправить"
        )

        layout.addWidget(
            self.chat_log
        )

        layout.addWidget(
            self.input
        )

        layout.addWidget(
            self.send_button
        )

        self.setLayout(
            layout
        )

        self.send_button.clicked.connect(
            self.send_message
        )

        self.load_history()

    def send_message(self):

        text = self.input.text().strip()

        if not text:
            return

        self.chat_log.append(
            f"{self.my_name}: {text}"
        )

        self.db.save_message(
            self.my_node_id,
            self.peer_node_id,
            text
        )

        packet = {

            "packet_id": generate_message_id(),

            "type": "chat_message",

            "source_node": self.my_node_id,

            "destination_node": self.peer_node_id,

            "ttl": 5,

            "sender": self.my_name,

            "message": text
        }

        if self.peer_port == 0:

            self.chat_log.append(
                "[Система] Пользователь офлайн"
            )

            return

        send_packet(
            self.peer_ip,
            self.peer_port,
            packet
        )

        self.input.clear()

    def receive_message(self, sender, text):

        self.db.save_message(
            sender,
            self.my_node_id,
            text
        )

        self.chat_log.append(
            f"{sender}: {text}"
        )

    def load_history(self):

        messages = self.db.get_messages(
            self.my_node_id,
            self.peer_node_id
        )

        for sender, receiver, text, timestamp in messages:

            self.chat_log.append(
                f"[{timestamp}] {sender}: {text}"
            )