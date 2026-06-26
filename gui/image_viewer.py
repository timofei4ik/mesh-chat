from PyQt6.QtCore import Qt, QUrl
from PyQt6.QtGui import QDesktopServices, QPixmap
from PyQt6.QtWidgets import (
    QDialog,
    QFileDialog,
    QHBoxLayout,
    QLabel,
    QPushButton,
    QScrollArea,
    QVBoxLayout,
    QWidget,
)


class ImageViewerDialog(QDialog):

    def __init__(
        self,
        filename,
        data_hex,
        write_temp_file,
        parent=None
    ):

        super().__init__(
            parent
        )

        self.filename = filename
        self.data_hex = data_hex
        self.write_temp_file = write_temp_file
        self.pixmap = QPixmap()
        self.pixmap.loadFromData(
            bytes.fromhex(
                data_hex
            )
        )

        self.setWindowTitle(
            filename
        )
        self.resize(
            900,
            680
        )

        layout = QVBoxLayout(
            self
        )
        layout.setContentsMargins(
            12,
            12,
            12,
            12
        )
        layout.setSpacing(
            10
        )

        self.image_label = QLabel()
        self.image_label.setAlignment(
            Qt.AlignmentFlag.AlignCenter
        )
        self.image_label.setStyleSheet(
            "background:#141518;"
        )

        scroll = QScrollArea()
        scroll.setWidgetResizable(
            True
        )
        scroll.setStyleSheet(
            "QScrollArea { border:none; background:#141518; }"
        )

        image_holder = QWidget()
        image_layout = QVBoxLayout(
            image_holder
        )
        image_layout.setContentsMargins(
            0,
            0,
            0,
            0
        )
        image_layout.addWidget(
            self.image_label
        )
        scroll.setWidget(
            image_holder
        )

        actions = QHBoxLayout()

        self.save_button = QPushButton(
            "Сохранить"
        )
        self.open_button = QPushButton(
            "Открыть снаружи"
        )
        self.close_button = QPushButton(
            "Закрыть"
        )

        for button in (
            self.save_button,
            self.open_button,
            self.close_button
        ):

            button.setStyleSheet(
                """
                QPushButton {
                    background:#30333a;
                    color:white;
                    border:1px solid #474b55;
                    border-radius:7px;
                    padding:7px 12px;
                }
                QPushButton:hover {
                    background:#3a3f49;
                }
                """
            )

        self.save_button.clicked.connect(
            self.save_image
        )
        self.open_button.clicked.connect(
            self.open_external
        )
        self.close_button.clicked.connect(
            self.accept
        )

        actions.addWidget(
            self.save_button
        )
        actions.addWidget(
            self.open_button
        )
        actions.addStretch()
        actions.addWidget(
            self.close_button
        )

        layout.addWidget(
            scroll,
            1
        )
        layout.addLayout(
            actions
        )

        self.setStyleSheet(
            """
            QDialog {
                background:#202124;
                color:white;
            }
            """
        )

        self.update_image()

    def resizeEvent(
        self,
        event
    ):

        super().resizeEvent(
            event
        )
        self.update_image()

    def update_image(self):

        if self.pixmap.isNull():
            return

        target_width = max(
            320,
            self.width() - 56
        )
        target_height = max(
            240,
            self.height() - 110
        )

        scaled = self.pixmap.scaled(
            target_width,
            target_height,
            Qt.AspectRatioMode.KeepAspectRatio,
            Qt.TransformationMode.SmoothTransformation
        )

        self.image_label.setPixmap(
            scaled
        )

    def save_image(self):

        save_path, _ = QFileDialog.getSaveFileName(
            self,
            "Сохранить изображение",
            self.filename,
            "Images (*.png *.jpg *.jpeg *.webp *.bmp);;All files (*.*)"
        )

        if not save_path:
            return

        with open(
            save_path,
            "wb"
        ) as file:

            file.write(
                bytes.fromhex(
                    self.data_hex
                )
            )

    def open_external(self):

        path = self.write_temp_file(
            self.filename
        )

        if not path:
            return

        QDesktopServices.openUrl(
            QUrl.fromLocalFile(
                path
            )
        )
