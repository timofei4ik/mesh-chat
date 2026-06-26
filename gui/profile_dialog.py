from PyQt6.QtCore import Qt
from PyQt6.QtWidgets import (
    QDialog,
    QDialogButtonBox,
    QFormLayout,
    QLabel,
    QVBoxLayout,
)

from gui.avatar import round_pixmap


class ProfileDialog(QDialog):

    @staticmethod
    def show_profile(
        parent,
        name,
        node_id,
        avatar_path="",
        about="-",
        public_username="",
        transport="-",
        address="-",
        port_label="-",
        status="-",
        unread=0,
        pending=0
    ):

        dialog = ProfileDialog(
            parent
        )

        dialog.setWindowTitle(
            "Профиль"
        )

        layout = QVBoxLayout(
            dialog
        )
        layout.setContentsMargins(
            20,
            20,
            20,
            16
        )
        layout.setSpacing(
            12
        )

        avatar = QLabel()
        avatar.setAlignment(
            Qt.AlignmentFlag.AlignCenter
        )
        avatar.setPixmap(
            round_pixmap(
                avatar_path,
                132,
                name,
                node_id
            )
        )

        title = QLabel(
            name
        )
        title.setAlignment(
            Qt.AlignmentFlag.AlignCenter
        )
        title.setStyleSheet(
            "font-size:18px;font-weight:700;color:white;"
        )

        about_label = QLabel(
            about or "-"
        )
        about_label.setWordWrap(
            True
        )
        about_label.setAlignment(
            Qt.AlignmentFlag.AlignCenter
        )
        about_label.setStyleSheet(
            "color:#cfd3da;font-size:13px;"
        )

        username_text = (
            f"@{public_username}"
            if public_username
            else ""
        )

        username_label = QLabel(
            username_text
        )
        username_label.setAlignment(
            Qt.AlignmentFlag.AlignCenter
        )
        username_label.setStyleSheet(
            "color:#8fb8ff;font-size:13px;"
        )

        form = QFormLayout()
        form.setLabelAlignment(
            Qt.AlignmentFlag.AlignRight
        )
        form.addRow(
            "Node ID:",
            QLabel(node_id)
        )
        form.addRow(
            "Тип:",
            QLabel(transport)
        )
        form.addRow(
            "Адрес:",
            QLabel(address)
        )
        form.addRow(
            "Порт/channel:",
            QLabel(port_label)
        )
        form.addRow(
            "Статус:",
            QLabel(status)
        )
        form.addRow(
            "Непрочитанные:",
            QLabel(str(unread))
        )
        form.addRow(
            "Ожидают отправки:",
            QLabel(str(pending))
        )

        buttons = QDialogButtonBox(
            QDialogButtonBox.StandardButton.Ok
        )
        buttons.accepted.connect(
            dialog.accept
        )

        dialog.setStyleSheet(
            """
            QDialog {
                background:#202124;
                color:white;
            }
            QLabel {
                color:white;
            }
            QDialogButtonBox QPushButton {
                background:#2f80ed;
                color:white;
                border:none;
                border-radius:7px;
                padding:7px 16px;
            }
            """
        )

        layout.addWidget(
            avatar
        )
        layout.addWidget(
            title
        )
        if username_text:
            layout.addWidget(
                username_label
            )
        layout.addWidget(
            about_label
        )
        layout.addLayout(
            form
        )
        layout.addWidget(
            buttons
        )

        dialog.resize(
            390,
            430
        )
        dialog.exec()
