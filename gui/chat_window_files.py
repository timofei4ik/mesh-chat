from datetime import datetime
import hashlib
import os
import tempfile
import uuid

from PyQt6.QtCore import Qt, QTimer, QUrl
from PyQt6.QtGui import QDesktopServices, QPixmap
from PyQt6.QtWidgets import (
    QFileDialog,
    QHBoxLayout,
    QLabel,
    QListWidgetItem,
    QPushButton,
    QVBoxLayout,
    QWidget,
)

from gui.audio_message_widget import AudioMessageWidget
from gui.image_viewer import ImageViewerDialog
from gui.image_compression import prepare_image_for_send
from network.message_id import generate_message_id


class ChatFileMixin:
    def is_image_file(
        self,
        filename
    ):

        return filename.lower().endswith(
            (
                ".png",
                ".jpg",
                ".jpeg",
                ".gif",
                ".bmp",
                ".webp"
            )
        )

    def is_audio_file(
        self,
        filename
    ):

        return filename.lower().endswith(
            (
                ".mp3",
                ".wav",
                ".ogg",
                ".m4a",
                ".flac",
                ".aac"
            )
        )

    def get_file_data(
        self,
        filename
    ):

        return self.pending_files.get(
            filename
        )

    def write_temp_file(
        self,
        filename
    ):

        local_path = getattr(
            self,
            "local_file_paths",
            {}
        ).get(
            filename
        )

        if local_path and os.path.isfile(
            local_path
        ):
            return local_path

        data = self.get_file_data(
            filename
        )

        if not data:
            return None

        temp_dir = os.path.join(
            tempfile.gettempdir(),
            "meshchat_files"
        )

        os.makedirs(
            temp_dir,
            exist_ok=True
        )

        safe_name = os.path.basename(
            filename
        )

        digest = hashlib.sha1(
            data.encode(
                "ascii",
                errors="ignore"
            )
        ).hexdigest()[:12]

        path = os.path.join(
            temp_dir,
            f"{digest}_{safe_name}"
        )

        try:

            raw_data = bytes.fromhex(
                data
            )

            if (
                os.path.isfile(path)
                and os.path.getsize(path) == len(raw_data)
            ):
                return path

            temporary_path = path + ".tmp"

            with open(
                temporary_path,
                "wb"
            ) as f:

                f.write(
                    raw_data
                )

            os.replace(
                temporary_path,
                path
            )

        except (
            OSError,
            TypeError,
            ValueError
        ):

            return None

        return path

    def open_file(
        self,
        filename
    ):

        if self.is_image_file(
            filename
        ):

            data = self.get_file_data(
                filename
            )

            if data:

                ImageViewerDialog(
                    filename,
                    data,
                    self.write_temp_file,
                    self
                ).exec()

                return

        path = self.write_temp_file(
            filename
        )

        if not path:
            return

        QDesktopServices.openUrl(
            QUrl.fromLocalFile(
                path
            )
        )

    def receive_file(
        self,
        sender,
        sender_node_id,
        filename,
        data,
        file_id=None
    ):

        self.pending_files[
            filename
        ] = data

        if file_id in self.file_status_labels:

            self.update_file_status(
                file_id,
                "получено"
            )

        else:

            self.add_file_message(
                filename,
                False,
                file_id,
                "получено"
            )

    def send_file(self):

        file_paths, _ = QFileDialog.getOpenFileNames(
            self,
            "Выберите файл"
        )

        if not file_paths:
            return

        for file_path in file_paths:

            self.send_file_path(
                file_path
            )

    def send_file_path(
        self,
        file_path
    ):

        if (
            self.transport not in (
                "bluetooth",
                "server"
            )
            and self.peer_port == 0
        ):

            self.add_my_message(
                "[Система] Пользователь офлайн"
            )

            return

        try:

            CHUNK_SIZE = 64 * 1024

            file_id = str(
                uuid.uuid4()
            )

            filename, file_bytes = prepare_image_for_send(
                file_path,
                getattr(
                    self,
                    "compress_images",
                    True
                )
            )

            if self.is_audio_file(
                filename
            ):

                if not hasattr(
                    self,
                    "local_file_paths"
                ):
                    self.local_file_paths = {}

                self.local_file_paths[
                    filename
                ] = file_path

            file_data = file_bytes.hex()

            wire_filename = filename
            wire_file_bytes = file_bytes

            if self.encrypt_file_callback:

                wire_filename, wire_file_bytes = (
                    self.encrypt_file_callback(
                        self.peer_node_id,
                        filename,
                        file_bytes
                    )
                )

            self.pending_files[
                filename
            ] = file_data

            self.add_file_message(
                filename,
                True,
                file_id,
                "в очереди"
            )

            if self.file_sent_callback:

                self.file_sent_callback(
                    file_id,
                    filename
                )

            self.enqueue_file_send(
                {
                    "file_id": file_id,
                    "filename": filename,
                    "file_bytes": wire_file_bytes,
                    "file_data": file_data,
                    "wire_filename": wire_filename,
                    "chunk_size": CHUNK_SIZE,
                    "index": 0,
                    "total_chunks": max(
                        1,
                        (
                            len(wire_file_bytes)
                            + CHUNK_SIZE
                            - 1
                        )
                        // CHUNK_SIZE
                    )
                }
            )

            return

            total_chunks = (
                len(file_bytes)
                + CHUNK_SIZE
                - 1
            ) // CHUNK_SIZE

            if total_chunks == 0:

                total_chunks = 1

            self.add_file_message(
                filename,
                True,
                file_id,
                "0%"
            )

            if self.file_sent_callback:

                self.file_sent_callback(
                    file_id,
                    filename
                )

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

                sent = self.send_peer_packet(
                    packet
                )

                if not sent:

                    self.update_file_status(
                        file_id,
                        "ошибка"
                    )

                    return

                percent = int(
                    (
                        index + 1
                    )
                    * 100
                    / total_chunks
                )

                self.update_file_status(
                    file_id,
                    f"{percent}%"
                )

            self.db.save_file(
                self.my_node_id,
                self.peer_node_id,
                filename,
                file_data,
                file_id
            )

            self.update_file_status(
                file_id,
                "отправлено"
            )

        except Exception as e:

            if "file_id" in locals():

                self.update_file_status(
                    file_id,
                    "ошибка"
                )

            print(
                "File send error:",
                e
            )

    def ensure_file_queue(self):

        if not hasattr(
            self,
            "file_send_queue"
        ):

            self.file_send_queue = []
            self.file_send_active = None

    def enqueue_file_send(
        self,
        job
    ):

        self.ensure_file_queue()
        self.file_send_queue.append(
            job
        )

        if not self.file_send_active:

            self.process_next_file_send()

    def process_next_file_send(self):

        self.ensure_file_queue()

        if self.file_send_active:
            return

        if not self.file_send_queue:
            return

        self.file_send_active = self.file_send_queue.pop(
            0
        )

        self.update_file_status(
            self.file_send_active["file_id"],
            "отправка 0%"
        )

        QTimer.singleShot(
            0,
            self.send_next_file_chunk
        )

    def send_next_file_chunk(self):

        job = self.file_send_active

        if not job:
            return

        index = job["index"]
        total_chunks = job["total_chunks"]
        chunk_size = job["chunk_size"]
        start = index * chunk_size
        chunk = job["file_bytes"][
            start:start + chunk_size
        ]

        packet = {
            "packet_id": generate_message_id(),
            "type": "file_chunk",
            "source_node": self.my_node_id,
            "destination_node": self.peer_node_id,
            "ttl": 5,
            "sender": self.my_name,
            "file_id": job["file_id"],
            "filename": job.get(
                "wire_filename",
                job["filename"]
            ),
            "chunk_index": index,
            "total_chunks": total_chunks,
            "data": chunk.hex()
        }

        sent = self.send_peer_packet(
            packet
        )

        if not sent:

            self.update_file_status(
                job["file_id"],
                "ошибка"
            )

            self.file_send_active = None

            QTimer.singleShot(
                0,
                self.process_next_file_send
            )

            return

        job["index"] += 1

        percent = int(
            job["index"]
            * 100
            / total_chunks
        )

        self.update_file_status(
            job["file_id"],
            f"отправка {percent}%"
        )

        if job["index"] >= total_chunks:

            self.db.save_file(
                self.my_node_id,
                self.peer_node_id,
                job["filename"],
                job["file_data"],
                job["file_id"]
            )

            self.update_file_status(
                job["file_id"],
                "отправлено"
            )

            self.file_send_active = None

            QTimer.singleShot(
                0,
                self.process_next_file_send
            )

            return

        QTimer.singleShot(
            0,
            self.send_next_file_chunk
        )

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

        self.open_file(
            filename
        )

    def save_file_from_item(
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

    def add_file_message(
        self,
        filename,
        mine,
        file_id=None,
        status=None
    ):

        item = QListWidgetItem()

        self.set_file_item_data(
            item,
            filename,
            mine,
            file_id
        )

        self.set_item_search_text(
            item,
            filename
        )

        widget = QWidget()

        layout = QHBoxLayout(widget)

        layout.setContentsMargins(
            6, 2, 6, 2
        )

        bubble = QWidget()

        bubble.setObjectName(
            "message_bubble"
        )

        bubble_layout = QVBoxLayout(
            bubble
        )

        bubble_layout.setContentsMargins(
            12, 9, 12, 8
        )

        bubble_layout.setSpacing(
            6
        )

        preview = self.make_file_preview(
            filename
        )

        if preview:

            bubble_layout.addWidget(
                preview
            )

        name_label = None

        if not preview:

            name_label = self.make_message_label(
                self.format_file_name(
                    filename
                )
            )

            bubble_layout.addWidget(
                name_label
            )

        timestamp = datetime.now().strftime(
            "%H:%M"
        )

        label = self.make_message_label(
            self.format_file_footer(
                timestamp,
                status
            ),
            "#cfd3da"
        )

        label.setAlignment(
            Qt.AlignmentFlag.AlignRight
        )

        label.setStyleSheet(
            """
            color:#cfd3da;
            font-size:10px;
            padding-bottom:0;
            """
        )

        bubble_layout.addWidget(
            label
        )

        file_width = 300 if preview else self.calculate_bubble_width(
            filename,
            self.format_file_status(status),
            min_width=150
        )

        self.apply_bubble_width(
            bubble,
            file_width,
            [
                name_label,
                label
            ]
        )

        self.configure_bubble(
            bubble,
            mine
        )

        if mine:

            layout.addStretch()
            layout.addWidget(
                self.wrap_message_bubble(
                    bubble,
                    mine
                )
            )

        else:

            layout.addWidget(
                self.wrap_message_bubble(
                    bubble,
                    mine
                )
            )
            layout.addStretch()

        self.add_widget_item(
            item,
            widget
        )

        if file_id:

            self.file_status_labels[
                file_id
            ] = {

                "label": label,

                "filename": filename,

                "item": item,

                "timestamp": timestamp
            }

            self.message_items[
                file_id
            ] = item

            self.load_reactions_for_item(
                item,
                file_id
            )

        self.chat_log.scrollToBottom()

        self.apply_search_filter()

    def format_file_text(
        self,
        filename,
        status=None
    ):

        if status:

            return f"Файл: {filename} - {status}"

        return f"Файл: {filename}"

    def format_file_name(
        self,
        filename
    ):

        return f"Файл: {filename}"

    def format_file_status(
        self,
        status=None
    ):

        if not status:
            return ""

        normalized = str(
            status
        ).strip().lower()

        if "%" in normalized:
            return status

        if "ошиб" in normalized:
            return "! ошибка"

        if "получ" in normalized:
            return "✓ получено"

        if "достав" in normalized:
            return "✓✓ доставлено"

        if "отправ" in normalized:
            return "✓ отправлено"

        return status

    def format_file_footer(
        self,
        timestamp,
        status=None
    ):

        status_text = self.format_file_status(
            status
        )

        if status_text:
            return f"{timestamp} · {status_text}"

        return timestamp

    def make_file_preview(
        self,
        filename
    ):

        data = self.get_file_data(
            filename
        )

        if self.is_image_file(
            filename
        ) and data:

            pixmap = QPixmap()

            pixmap.loadFromData(
                bytes.fromhex(
                    data
                )
            )

            if not pixmap.isNull():

                label = QLabel()

                label.setObjectName(
                    "file_preview"
                )

                label.setFixedSize(
                    260,
                    180
                )

                label.setPixmap(
                    pixmap.scaled(
                        260,
                        180,
                        Qt.AspectRatioMode.KeepAspectRatio,
                        Qt.TransformationMode.SmoothTransformation
                    )
                )

                label.setAlignment(
                    Qt.AlignmentFlag.AlignCenter
                )

                label.setStyleSheet(
                    """
                    border-radius:6px;
                    background:#17191d;
                    """
                )

                return label

        if self.is_audio_file(
            filename
        ):

            return AudioMessageWidget(
                filename,
                self.write_temp_file
            )

        return None

    def update_file_status(
        self,
        file_id,
        status
    ):

        file_status = self.file_status_labels.get(
            file_id
        )

        if not file_status:
            return

        file_status["label"].setText(
            self.format_file_footer(
                file_status.get(
                    "timestamp",
                    datetime.now().strftime("%H:%M")
                ),
                status
            )
        )

        widget = self.chat_log.itemWidget(
            file_status["item"]
        )

        if widget and not widget.findChild(
            QWidget,
            "file_preview"
        ):

            preview = self.make_file_preview(
                file_status["filename"]
            )

            bubble = widget.findChild(
                QWidget,
                "message_bubble"
            )

            if preview and bubble and bubble.layout():

                bubble.layout().insertWidget(
                    0,
                    preview
                )

                self.resize_item_to_widget(
                    file_status["item"],
                    widget
                )

                self.schedule_item_resize(
                    file_status["item"],
                    widget
                )

        elif widget:

            self.schedule_item_resize(
                file_status["item"],
                widget
            )

        self.set_item_search_text(
            file_status["item"],
            self.format_file_text(
                file_status["filename"],
                status
            )
        )

        self.apply_search_filter()

    def update_incoming_file_progress(
        self,
        file_id,
        filename,
        percent
    ):

        if file_id not in self.file_status_labels:

            self.add_file_message(
                filename,
                False,
                file_id,
                f"получение {percent}%"
            )

            return

        self.update_file_status(
            file_id,
            f"получение {percent}%"
        )

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

        self.open_file(
            filename
        )
