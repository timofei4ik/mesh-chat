import hashlib
import os
import tempfile
import uuid
from datetime import datetime

from PyQt6.QtCore import Qt, QTimer
from PyQt6.QtGui import QPixmap
from PyQt6.QtWidgets import (
    QFileDialog,
    QHBoxLayout,
    QLabel,
    QListWidgetItem,
    QPushButton,
    QVBoxLayout,
    QWidget,
    QMessageBox,
)

from gui.audio_message_widget import AudioMessageWidget
from gui.image_viewer import ImageViewerDialog
from gui.image_compression import prepare_image_for_send
from network.message_id import generate_message_id


class GroupFileMixin:
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
                ".flac",
                ".m4a"
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

        folder = os.path.join(
            tempfile.gettempdir(),
            "meshchat_files"
        )

        os.makedirs(
            folder,
            exist_ok=True
        )

        digest = hashlib.sha1(
            data.encode(
                "ascii",
                errors="ignore"
            )
        ).hexdigest()[:12]

        path = os.path.join(
            folder,
            f"{digest}_{os.path.basename(filename)}"
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

            with open(temporary_path, "wb") as f:
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

        if path:
            os.startfile(
                path
            )

    def file_item_clicked(
        self,
        item
    ):

        if item.data(
            Qt.ItemDataRole.UserRole + 2
        ) != "file":
            return

        filename = item.data(
            Qt.ItemDataRole.UserRole
        )

        if filename:
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

        data = self.pending_files.get(
            filename
        )

        if not data:
            return

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
        ) as file:

            file.write(
                bytes.fromhex(
                    data
                )
            )

    def add_file_message(
        self,
        filename,
        mine,
        file_id=None,
        status=None,
        sender_name=""
    ):

        item = QListWidgetItem()

        item.setData(
            Qt.ItemDataRole.UserRole,
            filename
        )

        item.setData(
            Qt.ItemDataRole.UserRole + 2,
            "file"
        )

        item.setData(
            Qt.ItemDataRole.UserRole + 3,
            filename
        )

        item.setData(
            Qt.ItemDataRole.UserRole + 4,
            mine
        )

        item.setData(
            Qt.ItemDataRole.UserRole + 5,
            file_id or ""
        )

        widget = QWidget()
        outer_layout = QHBoxLayout(widget)
        outer_layout.setContentsMargins(
            6, 2, 6, 2
        )

        bubble = QWidget()
        bubble.setObjectName(
            "message_bubble"
        )

        bubble_layout = QVBoxLayout(bubble)
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

            name_label = QLabel(
                self.format_file_name(
                    filename
                )
            )
            name_label.setWordWrap(
                True
            )
            name_label.setStyleSheet(
                """
                color:white;
                font-size:13px;
                """
            )

            bubble_layout.addWidget(
                name_label
            )

        timestamp = datetime.now().strftime(
            "%H:%M"
        )

        label = QLabel(
            self.format_file_footer(
                timestamp,
                status
            )
        )
        label.setAlignment(
            Qt.AlignmentFlag.AlignRight
        )
        label.setStyleSheet(
            """
            color:#cfd3da;
            font-size:10px;
            """
        )

        bubble_layout.addWidget(
            label
        )

        width = 300 if preview else self.calculate_bubble_width(
            filename,
            "",
            sender_text=sender_name,
            min_width=150
        )

        self.apply_bubble_width(
            bubble,
            width,
            [
                name_label,
                label
            ]
        )

        color = (
            "#2f7d4a"
            if mine
            else "#30333a"
        )

        bubble.setStyleSheet(
            f"""
            QWidget {{
                background:{color};
                border-radius:8px;
            }}
            """
        )

        if mine:
            outer_layout.addStretch()
            outer_layout.addWidget(
                self.wrap_message_bubble(
                    bubble,
                    True
                )
            )
        else:
            outer_layout.addWidget(
                self.wrap_message_bubble(
                    bubble,
                    False
                )
            )
            outer_layout.addStretch()

        self.messages.addItem(
            item
        )
        self.messages.setItemWidget(
            item,
            widget
        )
        self.resize_item_to_widget(
            item,
            widget
        )

        self.schedule_item_resize(
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

        self.messages.scrollToBottom()

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

                scaled = pixmap.scaled(
                    260,
                    180,
                    Qt.AspectRatioMode.KeepAspectRatio,
                    Qt.TransformationMode.SmoothTransformation
                )

                label = QLabel()
                label.setObjectName(
                    "file_preview"
                )
                label.setFixedSize(
                    260,
                    180
                )
                label.setPixmap(
                    scaled
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

        widget = self.messages.itemWidget(
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

        if widget:

            self.resize_item_to_widget(
                file_status["item"],
                widget
            )

            self.schedule_item_resize(
                file_status["item"],
                widget
            )

    def update_incoming_file_progress(
        self,
        file_id,
        filename,
        percent,
        sender_name=""
    ):

        if file_id not in self.file_status_labels:

            self.add_file_message(
                filename,
                False,
                file_id,
                f"получение {percent}%",
                sender_name
            )

            return

        self.update_file_status(
            file_id,
            f"получение {percent}%"
        )

    def receive_file(
        self,
        sender_name,
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

            return

        self.add_file_message(
            filename,
            False,
            file_id,
            "получено",
            sender_name
        )

    def send_file(self):

        file_paths, _ = QFileDialog.getOpenFileNames(
            self,
            "Выбрать файл"
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

        if self.main_window.group_members_missing_encryption_keys(
            self.group_id
        ):

            QMessageBox.warning(
                self,
                "Шифрование группы",
                "Не у всех участников получены ключи шифрования."
            )

            return

        file_id = str(
            uuid.uuid4()
        )

        filename, file_bytes = prepare_image_for_send(
            file_path,
            getattr(
                self.main_window,
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

        (
            group_key_id,
            wire_filename,
            wire_file_bytes
        ) = self.main_window.encrypt_group_file(
            self.group_id,
            filename,
            file_bytes
        )

        _, sender_key_envelope = (
            self.main_window.build_group_key_envelope(
                self.group_id,
                self.main_window.node_id,
                group_key_id
            )
        )

        self.pending_files[
            filename
        ] = file_data

        self.add_file_message(
            filename,
            True,
            file_id,
            "отправка 0%"
        )

        self.main_window.register_pending_file(
            file_id,
            filename
        )

        self.db.save_file(
            self.main_window.node_id,
            f"group:{self.group_id}",
            filename,
            file_data,
            file_id
        )

        self.enqueue_group_file_send(
            {
                "group_id": self.group_id,
                "file_id": file_id,
                "filename": filename,
                "wire_filename": wire_filename,
                "file_bytes": wire_file_bytes,
                "group_key_id": group_key_id,
                "group_key_sender_envelope": sender_key_envelope,
                "chunk_size": 32 * 1024,
                "index": 0,
                "total_chunks": max(
                    1,
                    (
                        len(wire_file_bytes)
                        + 32 * 1024
                        - 1
                    )
                    // (32 * 1024)
                )
            }
        )

        return

        self.main_window.send_group_file(
            self.group_id,
            file_id,
            filename,
            file_bytes,
            self.update_file_status
        )

    def ensure_group_file_queue(self):

        if not hasattr(
            self,
            "group_file_send_queue"
        ):

            self.group_file_send_queue = []
            self.group_file_send_active = None

    def enqueue_group_file_send(
        self,
        job
    ):

        self.ensure_group_file_queue()
        self.group_file_send_queue.append(
            job
        )

        if not self.group_file_send_active:

            self.process_next_group_file_send()

    def process_next_group_file_send(self):

        self.ensure_group_file_queue()

        if self.group_file_send_active:
            return

        if not self.group_file_send_queue:
            return

        self.group_file_send_active = self.group_file_send_queue.pop(
            0
        )

        self.update_file_status(
            self.group_file_send_active["file_id"],
            "отправка 0%"
        )

        QTimer.singleShot(
            0,
            self.send_next_group_file_chunk
        )

    def send_next_group_file_chunk(self):

        job = self.group_file_send_active

        if not job:
            return

        members = self.db.get_group_members(
            job["group_id"]
        )

        if self.main_window.node_id not in members:
            members.append(
                self.main_window.node_id
            )

        recipients = [
            member
            for member in members
            if member != self.main_window.node_id
        ]

        if not recipients:

            self.update_file_status(
                job["file_id"],
                "нет участников"
            )
            self.group_file_send_active = None
            QTimer.singleShot(
                0,
                self.process_next_group_file_send
            )
            return

        index = job["index"]
        total_chunks = job["total_chunks"]
        chunk_size = job["chunk_size"]
        start = index * chunk_size
        chunk = job["file_bytes"][
            start:start + chunk_size
        ]
        chunk_data = chunk.hex()

        for member in recipients:

            _, key_envelope = (
                self.main_window.build_group_key_envelope(
                    job["group_id"],
                    member,
                    job["group_key_id"]
                )
            )

            packet = {
                "packet_id": generate_message_id(),
                "type": "file_chunk",
                "source_node": self.main_window.node_id,
                "destination_node": member,
                "ttl": 5,
                "sender": self.main_window.username,
                "group_id": job["group_id"],
                "group_key_id": job["group_key_id"],
                "group_key_envelope": key_envelope,
                "group_key_sender_envelope": job[
                    "group_key_sender_envelope"
                ],
                "file_id": job["file_id"],
                "filename": job["wire_filename"],
                "chunk_index": index,
                "total_chunks": total_chunks,
                "data": chunk_data
            }

            sent = self.main_window.send_pending_packet(
                member,
                packet
            )

            if not sent:

                self.db.add_pending_packet(
                    packet["packet_id"],
                    self.main_window.node_id,
                    member,
                    f"[group file] {job['filename']}",
                    packet
                )

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

            self.update_file_status(
                job["file_id"],
                "отправлено"
            )
            self.group_file_send_active = None
            QTimer.singleShot(
                0,
                self.process_next_group_file_send
            )
            return

        QTimer.singleShot(
            0,
            self.send_next_group_file_chunk
        )
