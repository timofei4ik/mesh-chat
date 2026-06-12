from PyQt6.QtWidgets import (
    QWidget,
    QVBoxLayout,
    QTextBrowser,
    QLineEdit,
    QPushButton,
    QFileDialog
)

from network.client import send_packet
from storage.database import Database
from network.message_id import generate_message_id
from PyQt6.QtWidgets import QFileDialog
import base64
import os


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

        self.pending_files = {}

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

        self.chat_log = QTextBrowser()

        self.chat_log.setOpenLinks(
            False
        )

        self.chat_log.anchorClicked.connect(
            self.file_clicked
        )

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

        self.file_button = QPushButton(
            "📎 Файл"
        )

        layout.addWidget(
            self.file_button
        )

        self.file_button.clicked.connect(
            self.send_file
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

    def receive_message(
        self,
        sender_name,
        sender_node_id,
        text
    ):

        self.db.save_message(
            sender_node_id,
            self.my_node_id,
            text
        )

        self.chat_log.append(
            f"{sender_name}: {text}"
        )

    def load_history(self):

        self.chat_log.clear()

        messages = self.db.get_messages(
            self.my_node_id,
            self.peer_node_id
        )

        for sender, receiver, text, timestamp in messages:

            self.chat_log.append(
                f"[{timestamp}] {sender}: {text}"
            )
            
        files = self.db.get_files(
            self.my_node_id,
            self.peer_node_id
        )

        for filename, data, sender_node in files:

            self.pending_files[
                filename
            ] = data

            self.chat_log.append(
                f'<a href="{filename}">📎 {filename}</a>'
            )

    def send_file(self):

        file_path, _ = QFileDialog.getOpenFileName(
            self,
            "Выберите файл"
        )

        if not file_path:
            return

        try:

            with open(
                file_path,
                "rb"
            ) as f:

                data = base64.b64encode(
                    f.read()
                ).decode()

            packet = {

                "packet_id": generate_message_id(),

                "type": "file_message",

                "source_node": self.my_node_id,

                "destination_node": self.peer_node_id,

                "ttl": 5,

                "sender": self.my_name,

                "filename": os.path.basename(
                    file_path
                ),

                "data": data
            }

            self.db.save_file(
                self.my_node_id,
                self.peer_node_id,
                os.path.basename(file_path),
                data
            )

            send_packet(
                self.peer_ip,
                self.peer_port,
                packet
            )

            self.chat_log.append(
                f"[Файл] Отправлен: {os.path.basename(file_path)}"
            )

        except Exception as e:

            self.chat_log.append(
                f"[Ошибка] {e}"
            )

    def receive_file(
        self,
        sender,
        sender_node_id,
        filename,
        data
    ):

        self.pending_files[
            filename
        ] = data

        self.db.save_file(
            sender_node_id,
            self.my_node_id,
            filename,
            data
        )

        self.chat_log.append(
            f'<a href="{filename}">📎 {sender} отправил файл: {filename}</a>'
        )

    def file_clicked(
    self,
    url
):

        import base64

        filename = url.toString()

        if filename not in self.pending_files:
            return

        data = self.pending_files[
            filename
        ]

        save_path, _ = QFileDialog.getSaveFileName(
            self,
            "Сохранить файл",
            filename
        )

        if not save_path:
            return

        with open(
            save_path,
            "wb"
        ) as f:

            f.write(
                base64.b64decode(
                    data
                )
            )