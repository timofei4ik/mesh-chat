from PyQt6.QtWidgets import (
    QWidget,
    QVBoxLayout,
    QLineEdit,
    QPushButton,
    QHBoxLayout
)

from PyQt6.QtWidgets import (
    QListWidget,
    QListWidgetItem,
    QWidget,
    QLabel,
    QMenu,
    QSizePolicy,
)

from PyQt6.QtCore import QTimer

from PyQt6.QtCore import Qt
from PyQt6.QtCore import QUrl
from PyQt6.QtGui import QPixmap
from PyQt6.QtGui import QDesktopServices
from PyQt6.QtGui import QFontMetrics
from network.client import send_packet
from network.bluetooth_transport import send_bluetooth_packet
from storage.database import Database
from network.message_id import generate_message_id
from network.protocol import chat_message_packet
from gui.app_icon import app_icon
from gui.avatar import round_pixmap
from gui.chat_window_reactions import ChatReactionMixin
from gui.chat_window_bubbles import ChatBubbleMixin
from gui.chat_window_files import ChatFileMixin
from gui.profile_dialog import ProfileDialog
from gui.voice_recorder import VoiceRecorderMixin
from PyQt6.QtWidgets import QFileDialog
from datetime import datetime
import os
import threading
import time
import uuid
import tempfile


class ChatWindow(ChatReactionMixin, ChatBubbleMixin, ChatFileMixin, VoiceRecorderMixin, QWidget):

    def __init__(
        self,
        my_name,
        my_node_id,
        peer_name,
        peer_node_id,
        peer_ip,
        peer_port,
        file_sent_callback=None,
        transport="tcp",
        bluetooth_address=None,
        bluetooth_channel=None,
        server_send_callback=None,
        compress_images=True,
        forward_callback=None,
        encrypt_message_callback=None,
        encrypt_file_callback=None,
        draft_changed_callback=None
    ):


        super().__init__()

        self.my_name = my_name
        self.my_node_id = my_node_id
        self.peer_name = peer_name
        self.peer_node_id = peer_node_id
        self.peer_ip = peer_ip
        self.peer_port = peer_port
        self.file_sent_callback = file_sent_callback
        self.transport = transport
        self.bluetooth_address = bluetooth_address
        self.bluetooth_channel = bluetooth_channel
        self.server_send_callback = server_send_callback
        self.compress_images = compress_images
        self.forward_callback = forward_callback
        self.encrypt_message_callback = encrypt_message_callback
        self.encrypt_file_callback = encrypt_file_callback
        self.draft_changed_callback = draft_changed_callback

        self.db = Database()

        self.pending_files = {}
        self.file_chunks = {}
        self.message_status_labels = {}
        self.file_status_labels = {}
        self.message_items = {}
        self.reply_to_text = None
        self.reply_preview_label = None
        self.pinned_message_id = None
        self.last_typing_sent = 0
        self.typing_send_in_progress = False
        self.setup_voice_recorder()

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
            f"{my_name} - {peer_name}"
        )

        self.setWindowIcon(
            app_icon()
        )

        self.resize(
            600,
            500
        )

        layout = QVBoxLayout()

        layout.setContentsMargins(
            10, 10, 10, 10
        )

        layout.setSpacing(
            8
        )

        header_layout = QHBoxLayout()
        header_layout.setSpacing(
            10
        )

        self.peer_avatar_label = QLabel()
        self.peer_avatar_label.setFixedSize(
            42,
            42
        )
        self.peer_avatar_label.setCursor(
            Qt.CursorShape.PointingHandCursor
        )

        header_text_layout = QVBoxLayout()
        header_text_layout.setSpacing(
            1
        )

        self.peer_title_label = QLabel(
            peer_name
        )
        self.peer_title_label.setCursor(
            Qt.CursorShape.PointingHandCursor
        )
        self.peer_title_label.setStyleSheet(
            """
            color:white;
            font-size:15px;
            font-weight:700;
            """
        )

        self.peer_subtitle_label = QLabel(
            self.get_peer_transport_label()
        )
        self.peer_subtitle_label.setCursor(
            Qt.CursorShape.PointingHandCursor
        )
        self.peer_subtitle_label.setStyleSheet(
            """
            color:#aeb4bf;
            font-size:11px;
            """
        )

        header_text_layout.addWidget(
            self.peer_title_label
        )
        header_text_layout.addWidget(
            self.peer_subtitle_label
        )

        header_layout.addWidget(
            self.peer_avatar_label
        )
        header_layout.addLayout(
            header_text_layout
        )
        header_layout.addStretch()

        self.pinned_label = QLabel("")
        self.pinned_label.hide()
        self.pinned_label.setCursor(
            Qt.CursorShape.PointingHandCursor
        )
        self.pinned_label.setStyleSheet(
            """
            QLabel {
                background:#2b2d31;
                color:#e3e7ef;
                border-left:3px solid #2f80ed;
                padding:7px 9px;
                border-radius:6px;
                font-size:12px;
            }
            """
        )
        self.pinned_label.mousePressEvent = (
            lambda event: self.jump_to_pinned_message()
        )

        search_layout = QHBoxLayout()

        self.search_input = QLineEdit()

        self.search_input.setPlaceholderText(
            "РџРѕРёСЃРє"
        )

        self.search_clear_button = QPushButton(
            "РћС‡РёСЃС‚РёС‚СЊ"
        )

        self.search_input.setStyleSheet(
            """
            QLineEdit {
                background:#2b2d31;
                color:white;
                border:1px solid #3a3d44;
                border-radius:8px;
                padding:5px 9px;
            }
            """
        )

        self.search_clear_button.setStyleSheet(
            """
            QPushButton {
                background:#343740;
                color:white;
                border:none;
                border-radius:8px;
                padding:6px 10px;
            }
            QPushButton:hover {
                background:#424651;
            }
            """
        )

        search_layout.addWidget(
            self.search_input
        )

        search_layout.addWidget(
            self.search_clear_button
        )

        self.chat_log = QListWidget()

        self.typing_label = QLabel("")
        self.typing_label.hide()


        self.typing_timer.timeout.connect(
            self.typing_label.hide
        )

        self.chat_log.itemDoubleClicked.connect(
            self.file_item_clicked
        )

        self.chat_log.setContextMenuPolicy(
            Qt.ContextMenuPolicy.CustomContextMenu
        )

        self.chat_log.customContextMenuRequested.connect(
            self.show_message_context_menu
        )

        self.chat_log.setStyleSheet(
            """
            QListWidget {
                background:#202124;
                border:none;
                border-radius:8px;
                padding:8px;
            }

            QListWidget::item {
                margin:4px 0;
            }
            QListWidget::item:selected {
                background:transparent;
                border:none;
            }
            QListWidget::item:focus {
                outline:none;
            }
            """
        )

        self.input = QLineEdit()

        self.input.setPlaceholderText(
            "РЎРѕРѕР±С‰РµРЅРёРµ"
        )

        self.input.setMinimumHeight(
            34
        )

        self.input.setStyleSheet(
            """
            QLineEdit {
                background:#2b2d31;
                color:white;
                border:1px solid #3a3d44;
                border-radius:8px;
                padding:6px 10px;
            }
            """
        )

        self.reply_preview_label = QLabel("")

        self.reply_preview_label.hide()

        self.reply_preview_label.setStyleSheet(
            """
            QLabel {
                background:#2b2d31;
                color:#d7dde8;
                border-left:3px solid #2f80ed;
                padding:6px 8px;
                border-radius:6px;
                font-size:12px;
            }
            """
        )

        self.reply_preview_label.mousePressEvent = (
            lambda event: self.clear_reply()
        )

        input_layout = QHBoxLayout()

        input_layout.setSpacing(
            6
        )

        self.send_button = QPushButton(
            "вћ¤"
        )

        self.send_button.setFixedSize(
            34,
            34
        )

        self.send_button.setToolTip(
            "РћС‚РїСЂР°РІРёС‚СЊ"
        )

        self.send_button.setStyleSheet(
            """
            QPushButton {
                background:#2f80ed;
                color:white;
                border:none;
                border-radius:17px;
                font-size:15px;
            }
            QPushButton:hover {
                background:#3d8cff;
            }
            """
        )

        self.file_button = QPushButton(
            "рџ“Ћ"
        )

        self.file_button.setFixedSize(
            34,
            34
        )

        self.file_button.setToolTip(
            "Р¤Р°Р№Р»"
        )

        self.file_button.setStyleSheet(
            """
            QPushButton {
                background:#343740;
                color:white;
                border:none;
                border-radius:17px;
                font-size:15px;
            }
            QPushButton:hover {
                background:#424651;
            }
            """
        )

        self.voice_button = QPushButton(
            "рџЋ™"
        )

        self.voice_button.setFixedSize(
            34,
            34
        )

        self.voice_button.setToolTip(
            "Р“РѕР»РѕСЃРѕРІРѕРµ СЃРѕРѕР±С‰РµРЅРёРµ"
        )

        self.voice_button.setStyleSheet(
            """
            QPushButton {
                background:#343740;
                color:white;
                border:none;
                border-radius:17px;
                font-size:15px;
            }
            QPushButton:hover {
                background:#424651;
            }
            """
        )

        input_layout.addWidget(
            self.input
        )

        input_layout.addWidget(
            self.file_button
        )

        input_layout.addWidget(
            self.voice_button
        )

        input_layout.addWidget(
            self.send_button
        )

        layout.addLayout(
            header_layout
        )

        layout.addWidget(
            self.pinned_label
        )

        layout.addLayout(
            search_layout
        )

        layout.addWidget(
            self.chat_log
        )

        layout.addWidget(
            self.typing_label
        )

        layout.addWidget(
            self.reply_preview_label
        )

        layout.addLayout(
            input_layout
        )

        self.input.textEdited.connect(
            self.send_typing
        )

        self.draft_timer = QTimer(
            self
        )
        self.draft_timer.setSingleShot(
            True
        )
        self.draft_timer.setInterval(
            300
        )
        self.draft_timer.timeout.connect(
            self.save_draft
        )
        self.input.textChanged.connect(
            self.draft_timer.start
        )

        self.file_button.clicked.connect(
            self.send_file
        )

        self.voice_button.clicked.connect(
            self.toggle_voice_recording
        )

        self.search_input.textChanged.connect(
            self.apply_search_filter
        )

        self.search_clear_button.clicked.connect(
            self.clear_search
        )

        self.peer_avatar_label.mousePressEvent = (
            lambda event: self.show_peer_profile()
        )
        self.peer_title_label.mousePressEvent = (
            lambda event: self.show_peer_profile()
        )
        self.peer_subtitle_label.mousePressEvent = (
            lambda event: self.show_peer_profile()
        )

        self.setLayout(
            layout
        )

        self.send_button.clicked.connect(
            self.send_message
        )

        self.input.returnPressed.connect(
            self.send_message
        )

        self.load_history()
        self.refresh_pinned_message()
        self.input.setText(
            self.db.get_draft(
                f"chat:{self.peer_node_id}"
            )
        )

    def save_draft(self):

        self.db.set_draft(
            f"chat:{self.peer_node_id}",
            self.input.text()
        )

        if self.draft_changed_callback:
            self.draft_changed_callback()

    def pin_scope(self):
        return "chat:" + ":".join(
            sorted(
                (
                    self.my_node_id,
                    self.peer_node_id
                )
            )
        )

    def refresh_pinned_message(self):
        pins = self.db.get_pins(
            self.pin_scope()
        )

        if not pins:
            self.pinned_message_id = None
            self.pinned_label.hide()
            return

        message_id, text, _, _ = pins[0]
        item = self.message_items.get(
            message_id
        )
        if item:
            text = item.data(
                Qt.ItemDataRole.UserRole + 3
            ) or text

        preview = " ".join(
            (text or "").split()
        )
        if len(preview) > 100:
            preview = preview[:100] + "..."

        self.pinned_message_id = message_id
        self.pinned_label.setText(
            f"Р—Р°РєСЂРµРїР»РµРЅРѕ: {preview}"
        )
        self.pinned_label.show()

    def jump_to_pinned_message(self):
        item = self.message_items.get(
            self.pinned_message_id
        )

        if item:
            self.chat_log.scrollToItem(
                item
            )
            self.chat_log.setCurrentItem(
                item
            )
        self.update_peer_header()

    def get_peer_transport_label(self):

        encrypted = bool(
            self.db.get_user_encryption_key(
                self.peer_node_id
            )
        )

        if self.transport == "server":
            transport = "Server"

        elif self.transport == "bluetooth":
            transport = "Bluetooth"

        elif self.peer_port:
            transport = f"{self.peer_ip}:{self.peer_port}"

        else:
            transport = "offline"

        if encrypted:
            return f"{transport} | Р·Р°С€РёС„СЂРѕРІР°РЅРѕ"

        return transport

    def update_peer_header(self):

        profile = self.db.get_user_profile(
            self.peer_node_id
        )

        avatar_path = profile[3] if profile and profile[3] else ""

        name = self.db.get_user_name(
            self.peer_node_id
        ) or self.peer_name

        self.peer_name = name
        self.peer_title_label.setText(
            name
        )

        self.peer_avatar_label.setPixmap(
            round_pixmap(
                avatar_path,
                42,
                name,
                self.peer_node_id
            )
        )

        self.peer_subtitle_label.setText(
            self.get_peer_transport_label()
        )

    def show_peer_profile(self):

        profile = self.db.get_user_profile(
            self.peer_node_id
        )

        avatar_path = profile[3] if profile and profile[3] else ""
        public_username = profile[4] if profile and len(profile) > 4 and profile[4] else ""
        about = profile[5] if profile and len(profile) > 5 and profile[5] else "-"
        name = self.db.get_user_name(
            self.peer_node_id
        ) or self.peer_name

        transport = self.get_peer_transport_label()
        address = self.peer_ip or "-"
        port_label = (
            f"port {self.peer_port}"
            if self.peer_port
            else "-"
        )

        if self.transport == "bluetooth":
            address = self.bluetooth_address or self.peer_ip
            port_label = f"channel {self.bluetooth_channel}"

        elif self.transport == "server":
            address = "SERVER"
            port_label = "-"

        ProfileDialog.show_profile(
            self,
            name,
            self.peer_node_id,
            avatar_path,
            about,
            public_username,
            transport,
            address,
            port_label,
            "online" if self.peer_port or self.transport == "server" else "offline",
            self.db.get_unread(
                self.peer_node_id,
                self.my_node_id
            ),
            self.db.get_pending_count(
                self.my_node_id,
                self.peer_node_id
            )
        )

    def set_item_search_text(
        self,
        item,
        text
    ):

        item.setData(
            Qt.ItemDataRole.UserRole + 1,
            text.lower()
        )

    def set_message_item_data(
        self,
        item,
        text,
        mine,
        message_id=None
    ):

        item.setData(
            Qt.ItemDataRole.UserRole + 2,
            "message"
        )

        item.setData(
            Qt.ItemDataRole.UserRole + 3,
            text
        )

        item.setData(
            Qt.ItemDataRole.UserRole + 4,
            mine
        )

        item.setData(
            Qt.ItemDataRole.UserRole + 5,
            message_id or ""
        )

    def set_file_item_data(
        self,
        item,
        filename,
        mine,
        file_id=None
    ):

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

    def apply_search_filter(self):

        query = self.search_input.text().strip().lower()

        for index in range(
            self.chat_log.count()
        ):

            item = self.chat_log.item(
                index
            )

            if not query:

                item.setHidden(
                    False
                )

                continue

            search_text = item.data(
                Qt.ItemDataRole.UserRole + 1
            ) or ""

            item.setHidden(
                query not in search_text
            )

    def clear_search(self):

        self.search_input.clear()

    def set_reply_to(
        self,
        text
    ):

        text = text.strip().replace(
            "\n",
            " "
        )

        if len(text) > 120:

            text = text[:120] + "..."

        self.reply_to_text = text

        self.reply_preview_label.setText(
            f"РћС‚РІРµС‚: {text}    Г—"
        )

        self.reply_preview_label.show()

        self.input.setFocus()

    def clear_reply(self):

        self.reply_to_text = None
        self.reply_preview_label.hide()


    def resize_item_to_widget(
        self,
        item,
        widget,
        extra_height=12
    ):

        viewport_width = self.chat_log.viewport().width()

        if viewport_width > 0:
            widget.setMinimumWidth(
                viewport_width
            )
            widget.resize(
                viewport_width,
                widget.height()
            )

        widget.updateGeometry()
        widget.adjustSize()

        hint = widget.sizeHint()

        if viewport_width > 0:
            hint.setWidth(
                viewport_width
            )

        hint.setHeight(
            hint.height() + extra_height
        )

        item.setSizeHint(
            hint
        )

    def refresh_message_item_layouts(self):

        for row in range(
            self.chat_log.count()
        ):
            item = self.chat_log.item(
                row
            )
            widget = self.chat_log.itemWidget(
                item
            )

            if widget:
                self.resize_item_to_widget(
                    item,
                    widget
                )

    def resizeEvent(
        self,
        event
    ):

        super().resizeEvent(
            event
        )
        QTimer.singleShot(
            0,
            self.refresh_message_item_layouts
        )


    def send_peer_packet(
        self,
        packet
    ):

        if self.transport == "bluetooth":

            if (
                not self.bluetooth_address
                or self.bluetooth_channel is None
            ):

                return False

            return send_bluetooth_packet(
                self.bluetooth_address,
                self.bluetooth_channel,
                packet
            )

        if self.transport == "server":

            if not self.server_send_callback:
                return False

            return self.server_send_callback(
                packet
            )

        return send_packet(
            self.peer_ip,
            self.peer_port,
            packet
        )

    def send_message(self):

        text = self.input.text().strip()

        if not text:
            return

        if self.reply_to_text:

            reply_text = self.reply_to_text.strip().replace(
                "\n",
                " "
            )

            if len(reply_text) > 80:

                reply_text = reply_text[:80] + "..."

            text = f"> {reply_text}\n{text}"

            self.clear_reply()

        message_id = generate_message_id()

        wire_text = (
            self.encrypt_message_callback(
                self.peer_node_id,
                text
            )
            if self.encrypt_message_callback
            else text
        )

        packet = chat_message_packet(
            self.my_node_id,
            self.peer_node_id,
            self.my_name,
            wire_text,
            message_id
        )

        if (
            self.transport not in (
                "bluetooth",
                "server"
            )
            and self.peer_port == 0
        ):

            self.add_my_message(
                text,
                message_id=message_id,
                status="!"
            )

            self.save_pending_message(
                message_id,
                text
            )

            self.input.clear()

            return

        self.add_my_message(
            text,
            message_id=message_id,
            status=""
        )

        sent = self.send_peer_packet(
            packet
        )

        if not sent:

            self.mark_message_failed(
                message_id
            )

            self.save_pending_message(
                message_id,
                text
            )

            return

        self.mark_message_sent(
            message_id
        )

        self.db.save_message(
            self.my_node_id,
            self.peer_node_id,
            text,
            message_id
        )

        self.input.clear()

    def save_pending_message(
        self,
        message_id,
        text
    ):

        self.db.save_message(
            self.my_node_id,
            self.peer_node_id,
            text,
            message_id
        )

        self.db.add_pending_message(
            message_id,
            self.my_node_id,
            self.peer_node_id,
            text
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

        pending_message_ids = self.db.get_pending_message_ids(
            self.my_node_id,
            self.peer_node_id
        )

        for (
            item_type,
            message_id,
            sender,
            receiver,
            content,
            timestamp
        ) in history:

            if item_type == "message":

                if sender == self.my_node_id:

                    self.add_my_message(
                        content,
                        timestamp[11:16],
                        message_id=message_id,
                        status=(
                            "!"
                            if message_id in pending_message_ids
                            else "вњ“"
                        )
                    )

                else:

                    self.add_peer_message(
                        self.peer_name,
                        content,
                        timestamp[11:16],
                        message_id
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


    def add_my_message(
        self,
        text,
        timestamp=None,
        message_id=None,
        status="sent"
    ):

        if str(text).startswith("[РЎРёСЃС‚РµРјР°]"):

            self.add_system_message(
                str(text).replace(
                    "[РЎРёСЃС‚РµРјР°]",
                    "",
                    1
                ).strip()
            )

            return

        if timestamp is None:

            timestamp = datetime.now().strftime(
                "%H:%M"
            )

        item = QListWidgetItem()

        self.set_item_search_text(
            item,
            text
        )

        self.set_message_item_data(
            item,
            text,
            True,
            message_id
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
            4
        )

        reply_text, body_text = self.split_reply_text(
            text
        )

        if reply_text:

            reply_label = self.make_reply_label(
                reply_text
            )

            bubble_layout.addWidget(
                reply_label
            )

        else:

            reply_label = None

        text_label = self.make_message_label(
            body_text
        )

        text_label.setObjectName(
            "message_text_label"
        )

        time_label = self.make_time_label(
            timestamp
        )

        time_text = self.format_message_status(
            timestamp,
            status
        )

        bubble_layout.addWidget(
            text_label
        )

        time_label.setText(
            time_text
        )

        bubble_layout.addWidget(
            time_label
        )

        bubble_width = self.calculate_bubble_width(
            body_text,
            time_text,
            reply_text=reply_text
        )

        self.apply_bubble_width(
            bubble,
            bubble_width,
            [
                reply_label,
                text_label,
                time_label
            ]
        )

        self.configure_bubble(
            bubble,
            True
        )

        outer_layout.addStretch()

        outer_layout.addWidget(
            self.wrap_message_bubble(
                bubble,
                True
            )
        )

        self.add_widget_item(
            item,
            widget
        )

        if message_id:

            self.message_status_labels[
                message_id
            ] = {

                "label": time_label,

                "timestamp": timestamp
            }

            self.message_items[
                message_id
            ] = item

            self.load_reactions_for_item(
                item,
                message_id
            )

        self.chat_log.scrollToBottom()

        self.apply_search_filter()

    def add_system_message(
        self,
        text
    ):

        item = QListWidgetItem()
        self.set_item_search_text(
            item,
            text
        )

        widget = QWidget()
        layout = QHBoxLayout(
            widget
        )
        layout.setContentsMargins(
            6,
            6,
            6,
            6
        )
        layout.addStretch()

        label = QLabel(
            text
        )
        label.setWordWrap(
            True
        )
        label.setAlignment(
            Qt.AlignmentFlag.AlignCenter
        )
        label.setStyleSheet(
            """
            QLabel {
                color:#d0d4dc;
                background:#30333a;
                border-radius:10px;
                padding:5px 10px;
                font-size:11px;
            }
            """
        )
        label.setMaximumWidth(
            360
        )

        layout.addWidget(
            label
        )
        layout.addStretch()

        self.add_widget_item(
            item,
            widget
        )
        self.chat_log.scrollToBottom()

    def format_message_status(
        self,
        timestamp,
        status
    ):

        if status:

            return f"{timestamp} {status}"

        return timestamp

    def set_message_status(
        self,
        message_id,
        status
    ):

        message_status = self.message_status_labels.get(
            message_id
        )

        if not message_status:
            return

        message_status["label"].setText(
            self.format_message_status(
                message_status["timestamp"],
                status
            )
        )

    def mark_message_sent(
        self,
        message_id
    ):

        self.set_message_status(
            message_id,
            "вњ“"
        )

    def mark_message_delivered(
        self,
        message_id
    ):

        self.set_message_status(
            message_id,
            "вњ“вњ“"
        )

    def mark_message_failed(
        self,
        message_id
    ):

        self.set_message_status(
            message_id,
            "!"
        )

    def add_peer_message(
        self,
        sender,
        text,
        timestamp=None,
        message_id=None
    ):

        if timestamp is None:

            timestamp = datetime.now().strftime(
                "%H:%M"
            )

        item = QListWidgetItem()

        self.set_item_search_text(
            item,
            f"{sender} {text}"
        )

        self.set_message_item_data(
            item,
            text,
            False,
            message_id
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
            4
        )

        sender_label = self.make_message_label(
            sender,
            "#9ecbff"
        )

        sender_label.setStyleSheet(
            """
            color:#9ecbff;
            font-size:12px;
            font-weight:600;
            """
        )

        reply_text, body_text = self.split_reply_text(
            text
        )

        if reply_text:

            reply_label = self.make_reply_label(
                reply_text
            )

            bubble_layout.addWidget(
                reply_label
            )

        else:

            reply_label = None

        text_label = self.make_message_label(
            body_text
        )

        text_label.setObjectName(
            "message_text_label"
        )

        time_label = self.make_time_label(
            timestamp,
            "#b7bcc5"
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

        bubble_width = self.calculate_bubble_width(
            body_text,
            timestamp,
            sender_text=sender,
            reply_text=reply_text
        )

        self.apply_bubble_width(
            bubble,
            bubble_width,
            [
                sender_label,
                reply_label,
                text_label,
                time_label
            ]
        )

        self.configure_bubble(
            bubble,
            False
        )

        outer_layout.addWidget(
            self.wrap_message_bubble(
                bubble,
                False
            )
        )

        outer_layout.addStretch()

        self.add_widget_item(
            item,
            widget
        )

        self.chat_log.scrollToBottom()

        self.apply_search_filter()

        if message_id:

            self.message_items[
                message_id
            ] = item

            self.load_reactions_for_item(
                item,
                message_id
            )


    def receive_message(
        self,
        sender_name,
        sender_node_id,
        text,
        message_id=None
    ):

        self.db.save_message(
            sender_node_id,
            self.my_node_id,
            text,
            message_id
        )

        self.add_peer_message(
            sender_name,
            text,
            datetime.now().strftime("%H:%M"),
            message_id
        )

    def apply_message_edit(
        self,
        message_id,
        text,
        send=False
    ):

        item = self.message_items.get(
            message_id
        )

        if not item:
            return

        self.db.update_message(
            message_id,
            text
        )

        item.setData(
            Qt.ItemDataRole.UserRole + 3,
            text
        )

        mine = item.data(
            Qt.ItemDataRole.UserRole + 4
        )

        search_text = (
            text
            if mine
            else f"{self.peer_name} {text}"
        )

        self.set_item_search_text(
            item,
            search_text
        )

        widget = self.chat_log.itemWidget(
            item
        )

        if widget:

            label = widget.findChild(
                QLabel,
                "message_text_label"
            )

            if label:

                _, body_text = self.split_reply_text(
                    text
                )

                label.setText(
                    body_text
                )

            self.resize_item_to_widget(
                item,
                widget
            )

        self.refresh_pinned_message()

        if send:

            wire_text = (
                self.encrypt_message_callback(
                    self.peer_node_id,
                    text
                )
                if self.encrypt_message_callback
                else text
            )

            packet = {
                "packet_id": generate_message_id(),
                "type": "message_edit",
                "source_node": self.my_node_id,
                "destination_node": self.peer_node_id,
                "ttl": 5,
                "message_id": message_id,
                "message": wire_text
            }

            threading.Thread(
                target=self.send_peer_packet,
                args=(packet,),
                daemon=True
            ).start()

    def apply_message_delete(
        self,
        message_id,
        send=False
    ):

        item = self.message_items.get(
            message_id
        )

        self.db.delete_message(
            message_id
        )

        self.message_items.pop(
            message_id,
            None
        )

        self.message_status_labels.pop(
            message_id,
            None
        )

        if item:

            row = self.chat_log.row(
                item
            )

            if row >= 0:

                self.chat_log.takeItem(
                    row
                )

        self.refresh_pinned_message()

        if send:

            packet = {
                "packet_id": generate_message_id(),
                "type": "message_delete",
                "source_node": self.my_node_id,
                "destination_node": self.peer_node_id,
                "ttl": 5,
                "message_id": message_id
            }

            threading.Thread(
                target=self.send_peer_packet,
                args=(packet,),
                daemon=True
            ).start()


    def send_typing(self):

        now = time.time()

        if now - self.last_typing_sent < 1.5:
            return

        if self.typing_send_in_progress:
            return

        self.last_typing_sent = now
        self.typing_send_in_progress = True

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

        threading.Thread(
            target=self.send_typing_packet,
            args=(packet,),
            daemon=True
        ).start()

    def send_typing_packet(
        self,
        packet
    ):

        try:

            self.send_peer_packet(
                packet
            )

        finally:

            self.typing_send_in_progress = False

    def closeEvent(
        self,
        event
    ):

        self.typing_send_in_progress = False
        self.save_draft()

        super().closeEvent(
            event
        )

    def show_typing(
        self,
        sender
    ):

        self.typing_label.setText(
            f"{sender} РїРµС‡Р°С‚Р°РµС‚..."
        )

        self.typing_label.show()

        self.typing_timer.start(
            2000
        )
