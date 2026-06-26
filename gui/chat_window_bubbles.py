from PyQt6.QtCore import Qt, QTimer
from PyQt6.QtGui import QFontMetrics
from PyQt6.QtWidgets import QHBoxLayout, QLabel, QSizePolicy, QVBoxLayout, QWidget


class ChatBubbleMixin:
    def configure_bubble(
        self,
        bubble,
        mine
    ):

        bubble.setMaximumWidth(
            420
        )

        bubble.setSizePolicy(
            QSizePolicy.Policy.Maximum,
            QSizePolicy.Policy.Preferred
        )

        bubble.setMinimumWidth(
            0
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

    def calculate_bubble_width(
        self,
        body_text,
        time_text,
        sender_text="",
        reply_text=None,
        min_width=112,
        max_width=420
    ):

        metrics = QFontMetrics(
            self.font()
        )

        candidates = [
            time_text,
            sender_text,
            reply_text or ""
        ]

        candidates.extend(
            str(
                body_text or ""
            ).splitlines()
        )

        max_text_width = max(
            [
                metrics.horizontalAdvance(
                    text
                )
                for text in candidates
                if text
            ]
            or [
                min_width
            ]
        )

        width = max(
            min_width,
            max_text_width + 32
        )

        return min(
            width,
            max_width
        )

    def apply_bubble_width(
        self,
        bubble,
        width,
        labels
    ):

        bubble.setFixedWidth(
            width
        )

        label_width = max(
            40,
            width - 24
        )

        for label in labels:

            if label:

                label.setMaximumWidth(
                    label_width
                )

    def wrap_message_bubble(
        self,
        bubble,
        mine=False
    ):

        stack = QWidget()

        stack.setObjectName(
            "message_stack"
        )

        stack.setMaximumWidth(
            430
        )

        stack.setSizePolicy(
            QSizePolicy.Policy.Maximum,
            QSizePolicy.Policy.Preferred
        )

        stack_layout = QVBoxLayout(
            stack
        )

        stack_layout.setContentsMargins(
            0, 0, 0, 0
        )

        stack_layout.setSpacing(
            0
        )

        stack_layout.addWidget(
            bubble
        )

        reaction_row = QWidget()

        reaction_row.setObjectName(
            "reaction_row"
        )

        reaction_layout = QHBoxLayout(
            reaction_row
        )

        reaction_layout.setContentsMargins(
            0, 0, 0, 0
        )

        reaction_layout.setSpacing(
            0
        )

        if mine:

            reaction_layout.addStretch()

        reaction_row.hide()

        stack_layout.addWidget(
            reaction_row
        )

        return stack

    def make_message_label(
        self,
        text,
        color="white"
    ):

        label = QLabel(
            text
        )

        label.setWordWrap(
            True
        )

        label.setTextInteractionFlags(
            Qt.TextInteractionFlag.TextSelectableByMouse
        )

        label.setStyleSheet(
            f"""
            color:{color};
            font-size:13px;
            padding-bottom:2px;
            """
        )

        return label

    def make_time_label(
        self,
        text,
        color="#cfd3da"
    ):

        label = QLabel(
            text
        )

        label.setAlignment(
            Qt.AlignmentFlag.AlignRight
        )

        label.setMinimumHeight(
            14
        )

        label.setStyleSheet(
            f"""
            color:{color};
            font-size:10px;
            """
        )

        return label

    def split_reply_text(
        self,
        text
    ):

        if not text.startswith("> "):

            return None, text

        parts = text.split(
            "\n",
            1
        )

        reply = parts[0][2:].strip()

        body = (
            parts[1]
            if len(parts) > 1
            else ""
        )

        return reply, body

    def make_reply_label(
        self,
        text
    ):

        label = QLabel(
            text
        )

        label.setWordWrap(
            True
        )

        label.setStyleSheet(
            """
            color:#d9e8ff;
            background:#263140;
            border-left:3px solid #74a7ff;
            border-radius:5px;
            padding:5px 7px;
            font-size:12px;
            """
        )

        return label

    def add_widget_item(
        self,
        item,
        widget
    ):
        self.chat_log.addItem(
            item
        )

        self.chat_log.setItemWidget(
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

    def schedule_item_resize(
        self,
        item,
        widget
    ):

        def resize_later():

            if not item or not widget:
                return

            widget.updateGeometry()
            widget.adjustSize()
            self.resize_item_to_widget(
                item,
                widget
            )

        QTimer.singleShot(
            0,
            resize_later
        )

        QTimer.singleShot(
            80,
            resize_later
        )
