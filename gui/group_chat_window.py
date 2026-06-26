from datetime import datetime
import os
import tempfile
import time
import uuid

from PyQt6.QtWidgets import (
    QWidget,
    QVBoxLayout,
    QHBoxLayout,
    QListWidget,
    QListWidgetItem,
    QLineEdit,
    QPushButton,
    QLabel,
    QMenu,
    QSizePolicy,
    QFileDialog
)

from PyQt6.QtCore import Qt, QTimer
from PyQt6.QtGui import QFontMetrics, QPixmap

from storage.database import Database
from gui.app_icon import app_icon
from gui.group_chat_window_reactions import GroupReactionMixin
from gui.group_chat_window_bubbles import GroupBubbleMixin
from gui.group_chat_window_files import GroupFileMixin
from gui.voice_recorder import VoiceRecorderMixin


class GroupChatWindow(GroupReactionMixin, GroupBubbleMixin, GroupFileMixin, VoiceRecorderMixin, QWidget):

    def __init__(
        self,
        main_window,
        group_id,
        group_name
    ):

        super().__init__()

        self.main_window = main_window
        self.group_id = group_id
        self.group_name = group_name
        self.db = Database()
        self.message_items = {}
        self.reply_to_text = None
        self.pinned_message_id = None
        self.pending_files = {}
        self.file_status_labels = {}
        self.last_typing_sent = 0
        self.typing_timer = QTimer(
            self
        )
        self.typing_timer.setSingleShot(
            True
        )
        self.setup_voice_recorder()

        self.setWindowTitle(
            f"Группа - {group_name}"
        )

        self.setWindowIcon(
            app_icon()
        )

        self.resize(
            620,
            520
        )

        layout = QVBoxLayout()

        header_layout = QHBoxLayout()

        self.title_label = QLabel(
            group_name
        )

        self.title_label.setStyleSheet(
            """
            color:white;
            font-size:16px;
            font-weight:600;
            """
        )

        self.members_button = QPushButton(
            "Участники"
        )

        self.members_button.setStyleSheet(
            """
            QPushButton {
                background:#30333a;
                color:white;
                border:1px solid #444851;
                border-radius:6px;
                padding:6px 10px;
            }
            QPushButton:hover {
                background:#3a3e47;
            }
            """
        )

        header_layout.addWidget(
            self.title_label
        )

        header_layout.addStretch()

        header_layout.addWidget(
            self.members_button
        )

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

        self.messages = QListWidget()

        self.messages.setContextMenuPolicy(
            Qt.ContextMenuPolicy.CustomContextMenu
        )

        self.messages.customContextMenuRequested.connect(
            self.show_message_context_menu
        )

        self.messages.itemDoubleClicked.connect(
            self.file_item_clicked
        )

        self.messages.setStyleSheet(
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

        self.typing_label = QLabel("")
        self.typing_label.hide()
        self.typing_label.setStyleSheet(
            """
            color:#aeb4bf;
            font-size:11px;
            padding-left:6px;
            """
        )
        self.typing_timer.timeout.connect(
            self.typing_label.hide
        )

        input_layout = QHBoxLayout()

        self.input = QLineEdit()

        self.input.setPlaceholderText(
            "Сообщение в группу"
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

        self.send_button = QPushButton(
            "➤"
        )

        self.send_button.setFixedSize(
            34,
            34
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
            "📎"
        )

        self.file_button.setFixedSize(
            34,
            34
        )

        self.file_button.setToolTip(
            "Файл"
        )

        self.file_button.setStyleSheet(
            """
            QPushButton {
                background:#30333a;
                color:white;
                border:none;
                border-radius:17px;
                font-size:15px;
            }
            QPushButton:hover {
                background:#3a3e47;
            }
            """
        )

        self.voice_button = QPushButton(
            "🎙"
        )

        self.voice_button.setFixedSize(
            34,
            34
        )

        self.voice_button.setToolTip(
            "Голосовое сообщение"
        )

        self.voice_button.setStyleSheet(
            """
            QPushButton {
                background:#30333a;
                color:white;
                border:none;
                border-radius:17px;
                font-size:15px;
            }
            QPushButton:hover {
                background:#3a3e47;
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

        layout.addWidget(
            self.messages
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

        self.setLayout(
            layout
        )

        self.send_button.clicked.connect(
            self.send_message
        )

        self.file_button.clicked.connect(
            self.send_file
        )

        self.voice_button.clicked.connect(
            self.toggle_voice_recording
        )

        self.input.returnPressed.connect(
            self.send_message
        )

        self.input.textEdited.connect(
            self.send_group_typing
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

        self.members_button.clicked.connect(
            self.open_members
        )

        self.load_history()
        self.refresh_pinned_message()
        self.input.setText(
            self.db.get_draft(
                f"group:{self.group_id}"
            )
        )

    def save_draft(self):

        self.db.set_draft(
            f"group:{self.group_id}",
            self.input.text()
        )

        self.main_window.refresh_chats()

    def closeEvent(
        self,
        event
    ):

        self.save_draft()
        super().closeEvent(
            event
        )

    def pin_scope(self):
        return f"group:{self.group_id}"

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
        suffix = (
            f" (+{len(pins) - 1})"
            if len(pins) > 1
            else ""
        )
        self.pinned_label.setText(
            f"Закреплено{suffix}: {preview}"
        )
        self.pinned_label.show()

    def jump_to_pinned_message(self):
        item = self.message_items.get(
            self.pinned_message_id
        )

        if item:
            self.messages.scrollToItem(
                item
            )
            self.messages.setCurrentItem(
                item
            )

    def set_group_name(
        self,
        group_name
    ):

        self.group_name = group_name

        self.setWindowTitle(
            f"Группа - {group_name}"
        )

        self.title_label.setText(
            group_name
        )

    def open_members(self):

        self.main_window.show_group_members_dialog(
            self.group_id
        )

    def send_group_typing(self):

        now = time.time()

        if now - self.last_typing_sent < 1.5:
            return

        self.last_typing_sent = now
        self.main_window.send_group_typing(
            self.group_id
        )

    def show_group_typing(
        self,
        sender_name
    ):

        self.typing_label.setText(
            f"{sender_name} печатает..."
        )
        self.typing_label.show()
        self.typing_timer.start(
            2000
        )

    def load_history(self):

        self.messages.clear()
        self.pending_files.clear()

        for (
            message_id,
            sender_node,
            sender_name,
            message,
            timestamp
        ) in self.db.get_group_history(
            self.group_id
        ):

            self.add_message(
                sender_name,
                message,
                sender_node == self.main_window.node_id,
                timestamp[11:16],
                message_id
            )

        group_peer = f"group:{self.group_id}"

        for filename, data, sender_node in self.db.get_files(
            self.main_window.node_id,
            group_peer
        ):

            self.pending_files[
                filename
            ] = data

            sender_name = (
                self.db.get_user_name(
                    sender_node
                )
                or sender_node[:8]
            )

            self.add_file_message(
                filename,
                sender_node == self.main_window.node_id,
                sender_name=sender_name
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

        self.main_window.send_group_message(
            self.group_id,
            text
        )

        self.input.clear()

    def receive_message(
        self,
        sender_name,
        message,
        message_id=None
    ):

        self.add_message(
            sender_name,
            message,
            False,
            message_id=message_id
        )


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
            f"Ответ: {text}    x"
        )
        self.reply_preview_label.show()
        self.input.setFocus()

    def clear_reply(self):

        self.reply_to_text = None
        self.reply_preview_label.hide()


    def add_message(
        self,
        sender_name,
        text,
        mine,
        timestamp=None,
        message_id=None
    ):

        if sender_name == "Система":

            self.add_system_message(
                text
            )

            return

        if timestamp is None:

            timestamp = datetime.now().strftime(
                "%H:%M"
            )

        item = QListWidgetItem()

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

        widget = QWidget()
        outer_layout = QHBoxLayout(widget)
        outer_layout.setContentsMargins(
            6, 2, 6, 2
        )

        bubble = QWidget()

        bubble.setObjectName(
            "message_bubble"
        )

        bubble.setMaximumWidth(
            430
        )

        bubble.setSizePolicy(
            QSizePolicy.Policy.Maximum,
            QSizePolicy.Policy.Preferred
        )

        bubble_layout = QVBoxLayout(bubble)
        bubble_layout.setContentsMargins(
            12, 9, 12, 8
        )
        bubble_layout.setSpacing(
            4
        )

        sender_label = None

        if not mine:

            sender_label = QLabel(
                sender_name
            )

            sender_label.setStyleSheet(
                """
                color:#9ecbff;
                font-size:12px;
                font-weight:600;
                """
            )

            bubble_layout.addWidget(
                sender_label
            )

        reply_text, body_text = self.split_reply_text(
            text
        )

        reply_label = None

        if reply_text:

            reply_label = self.make_reply_label(
                reply_text
            )

            bubble_layout.addWidget(
                reply_label
            )

        text_label = QLabel(
            body_text
        )

        text_label.setObjectName(
            "message_text_label"
        )

        text_label.setWordWrap(
            True
        )

        text_label.setTextInteractionFlags(
            Qt.TextInteractionFlag.TextSelectableByMouse
        )

        text_label.setStyleSheet(
            """
            color:white;
            font-size:13px;
            padding-bottom:2px;
            """
        )

        time_label = QLabel(
            timestamp
        )

        time_label.setAlignment(
            Qt.AlignmentFlag.AlignRight
        )

        time_label.setStyleSheet(
            """
            color:#cfd3da;
            font-size:10px;
            """
        )

        bubble_layout.addWidget(
            text_label
        )

        bubble_layout.addWidget(
            time_label
        )

        width = self.calculate_bubble_width(
            body_text,
            timestamp,
            sender_text=sender_name
            if not mine
            else "",
            reply_text=reply_text
        )

        self.apply_bubble_width(
            bubble,
            width,
            [
                sender_label,
                reply_label,
                text_label,
                time_label
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

        self.resize_item_to_widget(
            item,
            widget
        )

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

        if message_id:

            self.message_items[
                message_id
            ] = item

            self.load_reactions_for_item(
                item,
                message_id
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

    def add_system_message(
        self,
        text
    ):

        item = QListWidgetItem()
        item.setData(
            Qt.ItemDataRole.UserRole + 2,
            "system"
        )
        item.setData(
            Qt.ItemDataRole.UserRole + 3,
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
        label.setMaximumWidth(
            360
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

        layout.addWidget(
            label
        )
        layout.addStretch()

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
        self.messages.scrollToBottom()

        self.messages.scrollToBottom()

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

        self.db.update_group_message(
            message_id,
            text
        )

        item.setData(
            Qt.ItemDataRole.UserRole + 3,
            text
        )

        widget = self.messages.itemWidget(
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

            self.main_window.send_group_edit(
                self.group_id,
                message_id,
                text
            )

    def apply_message_delete(
        self,
        message_id,
        send=False
    ):

        item = self.message_items.get(
            message_id
        )

        self.db.delete_group_message(
            message_id
        )

        self.message_items.pop(
            message_id,
            None
        )

        if item:

            row = self.messages.row(
                item
            )

            if row >= 0:

                self.messages.takeItem(
                    row
                )

        self.refresh_pinned_message()

        if send:

            self.main_window.send_group_delete_message(
                self.group_id,
                message_id
            )
