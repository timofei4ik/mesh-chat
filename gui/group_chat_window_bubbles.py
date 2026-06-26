from PyQt6.QtCore import QTimer
from PyQt6.QtGui import QFontMetrics
from PyQt6.QtWidgets import QHBoxLayout, QLabel, QSizePolicy, QVBoxLayout, QWidget


class GroupBubbleMixin:
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

        return (
            parts[0][2:].strip(),
            parts[1]
            if len(parts) > 1
            else ""
        )

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

        layout = QVBoxLayout(
            stack
        )

        layout.setContentsMargins(
            0, 0, 0, 0
        )

        layout.setSpacing(
            0
        )

        layout.addWidget(
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

        layout.addWidget(
            reaction_row
        )

        return stack

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

        return min(
            max(
                min_width,
                max_text_width + 32
            ),
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

    def resize_item_to_widget(
        self,
        item,
        widget,
        extra_height=12
    ):

        viewport_width = self.messages.viewport().width()

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
            self.messages.count()
        ):
            item = self.messages.item(
                row
            )
            widget = self.messages.itemWidget(
                item
            )

            if widget:
                self.resize_item_to_widget(
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
