from PyQt6.QtWidgets import (
    QWidget,
    QVBoxLayout,
    QTextBrowser,
    QLineEdit,
    QPushButton,
    QFileDialog
)

from PyQt6.QtWidgets import (
    QListWidget,
    QListWidgetItem,
    QWidget,
    QLabel,
    QHBoxLayout
)

from PyQt6.QtCore import QTimer

from PyQt6.QtCore import Qt
from network.client import send_packet
from storage.database import Database
from network.message_id import generate_message_id
from PyQt6.QtWidgets import QFileDialog
from datetime import datetime
import base64
import os
import uuid


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
        self.file_chunks = {}
        self.message_status_labels = {}

        self.my_node_id = my_node_id

        self.peer_node_id = peer_node_id

        self.db.clear_unread(
            peer_node_id,
            my_node_id
        )

        self.typing_timer = QTimer()

        self.typing_timer.setSingleShot(
            True
        )


        self.setWindowTitle(
            f"{my_name} ↔ {peer_name}"
        )

        self.resize(
            600,
            500
        )

        layout = QVBoxLayout()

        self.chat_log = QListWidget()

        self.typing_label = QLabel("")
        self.typing_label.hide()

        
        self.typing_timer.timeout.connect(
            self.typing_label.hide
        )

        self.chat_log.itemDoubleClicked.connect(
            self.file_item_clicked
        )

        self.chat_log.setStyleSheet(
            """
            QListWidget {
                background:#1e1f22;
                border:none;
            }
            """
        )

        self.input = QLineEdit()

        self.send_button = QPushButton(
            "Отправить"
        )

        layout.addWidget(
            self.chat_log
        )

        layout.addWidget(
            self.typing_label
        )

        layout.addWidget(
            self.input
        )

        self.input.textEdited.connect(
            self.send_typing
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
        
        message_id = generate_message_id()

        self.add_my_message(
            text,
            message_id=message_id
        )

        self.db.save_message(
            self.my_node_id,
            self.peer_node_id,
            text
        )

        packet = {

            "packet_id": message_id,

            "type": "chat_message",

            "source_node": self.my_node_id,

            "destination_node": self.peer_node_id,

            "ttl": 5,

            "sender": self.my_name,

            "message": text
        }

        if self.peer_port == 0:

            self.add_my_message(
                "[Система] Пользователь офлайн"
            )

            return

        send_packet(
            self.peer_ip,
            self.peer_port,
            packet
        )

        self.input.clear()

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

        self.add_file_message(
            filename,
            False
        )

    def load_history(self):

        self.chat_log.clear()

        files = self.db.get_files(
            self.my_node_id,
            self.peer_node_id
        )

        for filename, data, sender_node in files:

            self.pending_files[
                filename
            ] = data

        history = self.db.get_chat_history(
            self.my_node_id,
            self.peer_node_id
        )

        for item_type, sender, receiver, content, timestamp in history:

            if item_type == "message":

                if sender == self.my_node_id:

                    self.add_my_message(
                        content,
                        timestamp[11:16]
                    )

                else:

                    self.add_peer_message(
                        self.peer_name,
                        content,
                        timestamp[11:16]
                    )

            elif item_type == "file":

                if sender == self.my_node_id:

                    self.add_file_message(
                        content,
                        True
                    )

                else:

                    self.add_file_message(
                        content,
                        False
                    )

    def send_file(self):

        file_path, _ = QFileDialog.getOpenFileName(
            self,
            "Выберите файл"
        )

        if not file_path:
            return

        try:

            CHUNK_SIZE = 64 * 1024

            file_id = str(
                uuid.uuid4()
            )
            
            filename = os.path.basename(
                file_path
            )

            with open(
                file_path,
                "rb"
            ) as f:

                file_bytes = f.read()

            total_chunks = (
                len(file_bytes)
                + CHUNK_SIZE
                - 1
            ) // CHUNK_SIZE

            for index in range(
                total_chunks
            ):
                
                if index % 10 == 0:

                    print(
                        f"{index+1}/{total_chunks}"
                    )

                start = (
                    index
                    * CHUNK_SIZE
                )

                end = start + CHUNK_SIZE

                chunk = file_bytes[
                    start:end
                ]

                chunk_data = chunk.hex()

                packet = {

                    "packet_id":
                    generate_message_id(),

                    "type":
                    "file_chunk",

                    "source_node":
                    self.my_node_id,

                    "destination_node":
                    self.peer_node_id,

                    "ttl":
                    5,

                    "sender":
                    self.my_name,

                    "file_id":
                    file_id,

                    "filename":
                    filename,

                    "chunk_index":
                    index,

                    "total_chunks":
                    total_chunks,

                    "data":
                    chunk_data
                }

                send_packet(
                    self.peer_ip,
                    self.peer_port,
                    packet
                )

            self.add_file_message(
                filename,
                True
            )

        except Exception as e:

            print("Error!")

    def file_clicked(
        self,
        item
    ):

        filename = item.data(
            100
        )

        if not filename:
            return

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
                bytes.fromhex(data)
            )

    def add_my_message(
        self,
        text,
        timestamp=None,
        message_id=None
    ):

        if timestamp is None:

            timestamp = datetime.now().strftime(
                "%H:%M"
            )

        item = QListWidgetItem()

        widget = QWidget()

        outer_layout = QHBoxLayout(widget)

        bubble = QWidget()

        bubble_layout = QVBoxLayout(bubble)

        bubble_layout.setContentsMargins(
            8, 8, 8, 4
        )

        bubble_layout.setSpacing(
            2
        )

        text_label = QLabel(text)

        text_label.setWordWrap(True)

        text_label.setStyleSheet(
            """
            color:white;
            """
        )

        time_label = QLabel(timestamp)

        time_label.setAlignment(
            Qt.AlignmentFlag.AlignRight
        )

        time_label.setStyleSheet(
            """
            color:#d0d0d0;
            font-size:10px;
            """
        )

        bubble_layout.addWidget(
            text_label
        )

        time_label.setText(
            f"{timestamp} ✓"
        )

        bubble_layout.addWidget(
            time_label
        )

        bubble.setStyleSheet(
            """
            background:#2d7d46;
            border-radius:10px;
            """
        )

        outer_layout.addStretch()

        outer_layout.addWidget(
            bubble
        )

        item.setSizeHint(
            widget.sizeHint()
        )

        self.chat_log.addItem(item)

        self.chat_log.setItemWidget(
            item,
            widget
        )

        if message_id:

            self.message_status_labels[
                message_id
            ] = time_label

        self.chat_log.scrollToBottom()

    def add_peer_message(
        self,
        sender,
        text,
        timestamp=None
    ):

        if timestamp is None:

            timestamp = datetime.now().strftime(
                "%H:%M"
            )

        item = QListWidgetItem()

        widget = QWidget()

        outer_layout = QHBoxLayout(widget)

        bubble = QWidget()

        bubble_layout = QVBoxLayout(bubble)

        bubble_layout.setContentsMargins(
            8, 8, 8, 4
        )

        bubble_layout.setSpacing(
            2
        )

        sender_label = QLabel(sender)

        sender_label.setStyleSheet(
            """
            color:#9ecbff;
            font-weight:bold;
            """
        )

        text_label = QLabel(text)

        text_label.setWordWrap(True)

        text_label.setStyleSheet(
            """
            color:white;
            """
        )

        time_label = QLabel(timestamp)

        time_label.setAlignment(
            Qt.AlignmentFlag.AlignRight
        )

        time_label.setStyleSheet(
            """
            color:#b0b0b0;
            font-size:10px;
            """
        )

        bubble_layout.addWidget(
            sender_label
        )

        bubble_layout.addWidget(
            text_label
        )

        bubble_layout.addWidget(
            time_label
        )

        bubble.setStyleSheet(
            """
            background:#3a3a3a;
            border-radius:10px;
            """
        )

        outer_layout.addWidget(
            bubble
        )

        outer_layout.addStretch()

        item.setSizeHint(
            widget.sizeHint()
        )

        self.chat_log.addItem(item)

        self.chat_log.setItemWidget(
            item,
            widget
        )

        self.chat_log.scrollToBottom()


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

        self.add_peer_message(
            sender_name,
            text,
            datetime.now().strftime("%H:%M")
        )

    def add_file_message(
        self,
        filename,
        mine
    ):

        item = QListWidgetItem()

        item.setData(
            Qt.ItemDataRole.UserRole,
            filename
        )

        widget = QWidget()

        layout = QHBoxLayout(widget)

        label = QLabel(
            f"📎 {filename}"
        )

        label.setWordWrap(True)

        if mine:

            label.setStyleSheet(
                """
                background:#2e7d32;
                color:white;
                padding:8px;
                border-radius:10px;
                """
            )

            layout.addStretch()
            layout.addWidget(label)

        else:

            label.setStyleSheet(
                """
                background:#3a3a3a;
                color:white;
                padding:8px;
                border-radius:10px;
                """
            )

            layout.addWidget(label)
            layout.addStretch()

        item.setSizeHint(
            widget.sizeHint()
        )

        self.chat_log.addItem(item)

        self.chat_log.setItemWidget(
            item,
            widget
        )

        self.chat_log.scrollToBottom()

    def file_item_clicked(
        self,
        item
    ):

        filename = item.data(
            Qt.ItemDataRole.UserRole
        )

        if not filename:
            return

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
                bytes.fromhex(data)
            )

    def send_typing(self):

        packet = {

            "packet_id":
            generate_message_id(),

            "type":
            "typing",

            "source_node":
            self.my_node_id,

            "destination_node":
            self.peer_node_id,

            "sender":
            self.my_name
        }

        send_packet(
            self.peer_ip,
            self.peer_port,
            packet
        )

    def show_typing(
        self,
        sender
    ):

        self.typing_label.setText(
            f"{sender} печатает..."
        )

        self.typing_label.show()

        self.typing_timer.start(
            2000
        )