from PyQt6.QtGui import QAction
from PyQt6.QtWidgets import QApplication, QMenu, QStyle, QSystemTrayIcon

from gui.app_icon import app_icon


class TrayMixin:
    def setup_notifications(self):

        if not QSystemTrayIcon.isSystemTrayAvailable():
            return

        icon = app_icon()

        if icon.isNull():

            icon = QApplication.style().standardIcon(
                QStyle.StandardPixmap.SP_MessageBoxInformation
            )

        self.tray_icon = QSystemTrayIcon(
            icon,
            self
        )

        self.tray_icon.setToolTip(
            "MeshChat"
        )

        tray_menu = QMenu(
            self
        )

        open_action = QAction(
            "Открыть",
            self
        )

        quit_action = QAction(
            "Выход",
            self
        )

        open_action.triggered.connect(
            self.restore_from_tray
        )

        quit_action.triggered.connect(
            self.quit_from_tray
        )

        tray_menu.addAction(
            open_action
        )

        tray_menu.addSeparator()

        tray_menu.addAction(
            quit_action
        )

        self.tray_icon.setContextMenu(
            tray_menu
        )

        self.tray_icon.activated.connect(
            self.tray_icon_activated
        )

        self.tray_icon.show()

    def tray_icon_activated(
        self,
        reason
    ):

        if reason == QSystemTrayIcon.ActivationReason.Trigger:

            self.restore_from_tray()

    def restore_from_tray(self):

        self.show()
        self.raise_()
        self.activateWindow()

    def quit_from_tray(self):

        self.force_quit = True

        QApplication.instance().quit()

    def closeEvent(
        self,
        event
    ):

        if self.force_quit or not self.tray_icon:

            event.accept()

            return

        event.ignore()
        self.hide()

        self.tray_icon.showMessage(
            "MeshChat",
            "Приложение продолжает работать в трее.",
            QSystemTrayIcon.MessageIcon.Information,
            3000
        )

    def notify(
        self,
        title,
        message
    ):

        if not self.tray_icon:
            return

        if not self.tray_icon.isVisible():
            self.tray_icon.show()

        self.tray_icon.showMessage(
            title,
            message,
            QSystemTrayIcon.MessageIcon.Information,
            5000
        )

    def should_notify_for_chat(
        self,
        peer_node_id
    ):

        chat = self.chat_windows.get(
            peer_node_id
        )

        if not chat:

            chat = self.group_windows.get(
                peer_node_id
            )

        if not chat:
            return True

        if not chat.isVisible():
            return True

        if chat.isMinimized():
            return True

        if not chat.isActiveWindow():
            return True

        return False
