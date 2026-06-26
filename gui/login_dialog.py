from PyQt6.QtWidgets import (
    QDialog,
    QVBoxLayout,
    QHBoxLayout,
    QFormLayout,
    QLabel,
    QLineEdit,
    QDialogButtonBox,
    QListWidget,
    QPushButton,
    QMessageBox
)

from network.server_url import normalize_server_url
from network.server_transport import diagnose_server_connection_sync
from storage.database import Database, get_account_database_path, list_account_profiles


class LoginDialog(QDialog):

    def __init__(
        self,
        server_url="",
        server_token="",
        login="",
        public_username="",
        parent=None
    ):

        super().__init__(
            parent
        )

        self.setWindowTitle(
            "MeshChat - вход"
        )

        self.setMinimumWidth(
            360
        )

        layout = QVBoxLayout(
            self
        )

        title = QLabel(
            "Вход на сервер"
        )

        title.setStyleSheet(
            "font-size:18px;font-weight:600;color:white;"
        )

        hint = QLabel(
            "Если логина еще нет, сервер создаст аккаунт при первом входе."
        )

        hint.setWordWrap(
            True
        )

        hint.setStyleSheet(
            "color:#b8c0cc;"
        )

        form = QFormLayout()

        self.server_input = QLineEdit(
            server_url
        )

        self.server_input.setPlaceholderText(
            "ws://31.44.7.167:8765"
        )

        self.token_input = QLineEdit(
            server_token
        )

        self.token_input.setEchoMode(
            QLineEdit.EchoMode.Password
        )

        self.token_input.setPlaceholderText(
            "invite token"
        )

        self.login_input = QLineEdit(
            login
        )

        self.login_input.setPlaceholderText(
            "login"
        )

        self.public_username_input = QLineEdit(
            public_username or login
        )

        self.public_username_input.setPlaceholderText(
            "username"
        )

        self.password_input = QLineEdit()

        self.password_input.setEchoMode(
            QLineEdit.EchoMode.Password
        )

        self.password_input.setPlaceholderText(
            "password"
        )

        form.addRow(
            "Сервер:",
            self.server_input
        )

        form.addRow(
            "Invite token:",
            self.token_input
        )

        form.addRow(
            "Логин:",
            self.login_input
        )

        form.addRow(
            "@username:",
            self.public_username_input
        )

        form.addRow(
            "Пароль:",
            self.password_input
        )

        self.buttons = QDialogButtonBox(
            QDialogButtonBox.StandardButton.Ok
            | QDialogButtonBox.StandardButton.Cancel
        )

        self.buttons.button(
            QDialogButtonBox.StandardButton.Ok
        ).setText(
            "Войти / зарегистрироваться"
        )

        self.buttons.button(
            QDialogButtonBox.StandardButton.Cancel
        ).setText(
            "Отмена"
        )

        self.buttons.accepted.connect(
            self.validate_and_accept
        )

        self.buttons.rejected.connect(
            self.reject
        )

        layout.addWidget(
            title
        )

        layout.addWidget(
            hint
        )

        layout.addLayout(
            form
        )

        layout.addWidget(
            self.buttons
        )

        self.setStyleSheet(
            """
            QDialog {
                background:#202124;
            }
            QLabel {
                color:white;
            }
            QLineEdit {
                background:#2b2d31;
                color:white;
                border:1px solid #3a3d44;
                border-radius:7px;
                padding:7px 9px;
            }
            QPushButton {
                background:#2f80ed;
                color:white;
                border:none;
                border-radius:7px;
                padding:7px 12px;
            }
            QPushButton:hover {
                background:#3d8cff;
            }
            """
        )

    def values(self):

        return {
            "server_url": normalize_server_url(
                self.server_input.text()
            ),
            "server_token": self.token_input.text().strip(),
            "login": self.login_input.text().strip(),
            "public_username": self.public_username_input.text().strip().lower().lstrip("@"),
            "password": self.password_input.text()
        }

    def validate_and_accept(self):

        values = self.values()

        if not (
            values["server_url"]
            and values["login"]
            and values["password"]
        ):

            QMessageBox.warning(
                self,
                "MeshChat",
                "Введите сервер, логин и пароль."
            )

            return

        ok_button = self.buttons.button(
            QDialogButtonBox.StandardButton.Ok
        )

        ok_button.setEnabled(
            False
        )

        ok_button.setText(
            "Проверка..."
        )

        ok, message = diagnose_server_connection_sync(
            values["server_url"],
            f"login-check-{values['login']}",
            values["login"],
            values["server_token"],
            values["login"],
            values["password"],
            public_username=values["public_username"]
        )

        ok_button.setEnabled(
            True
        )

        ok_button.setText(
            "Войти / зарегистрироваться"
        )

        if not ok:

            QMessageBox.warning(
                self,
                "MeshChat",
                message
            )

            return

        self.accept()


def ask_server_login(
    server_url="",
    server_token="",
    login="",
    public_username=""
):

    dialog = LoginDialog(
        server_url,
        server_token,
        login,
        public_username
    )

    if dialog.exec() == QDialog.DialogCode.Accepted:

        values = dialog.values()

        if (
            values["server_url"]
            and values["login"]
            and values["password"]
        ):
            return values

    return None


class AccountManagerDialog(QDialog):

    def __init__(
        self,
        server_url="",
        server_token="",
        parent=None
    ):

        super().__init__(
            parent
        )

        self.result_values = None
        self.server_url = server_url
        self.server_token = server_token

        self.setWindowTitle(
            "MeshChat - аккаунты"
        )

        self.setMinimumSize(
            420,
            320
        )

        layout = QVBoxLayout(
            self
        )

        title = QLabel(
            "Аккаунты"
        )

        title.setStyleSheet(
            "font-size:18px;font-weight:600;color:white;"
        )

        self.accounts_list = QListWidget()

        buttons = QHBoxLayout()

        self.login_button = QPushButton(
            "Войти"
        )

        self.add_button = QPushButton(
            "Добавить / регистрация"
        )

        self.delete_button = QPushButton(
            "Удалить локально"
        )

        buttons.addWidget(
            self.login_button
        )

        buttons.addWidget(
            self.add_button
        )

        buttons.addWidget(
            self.delete_button
        )

        layout.addWidget(
            title
        )

        layout.addWidget(
            self.accounts_list
        )

        layout.addLayout(
            buttons
        )

        self.login_button.clicked.connect(
            self.login_selected
        )

        self.add_button.clicked.connect(
            self.add_account
        )

        self.delete_button.clicked.connect(
            self.delete_selected
        )

        self.accounts_list.itemDoubleClicked.connect(
            lambda item: self.login_selected()
        )

        self.setStyleSheet(
            """
            QDialog {
                background:#202124;
            }
            QLabel {
                color:white;
            }
            QListWidget {
                background:#2b2d31;
                color:white;
                border:1px solid #3a3d44;
                border-radius:8px;
                padding:6px;
            }
            QPushButton {
                background:#2f80ed;
                color:white;
                border:none;
                border-radius:7px;
                padding:7px 10px;
            }
            QPushButton:hover {
                background:#3d8cff;
            }
            """
        )

        self.load_profiles()

    def load_profiles(self):

        self.accounts_list.clear()

        for profile in list_account_profiles():

            self.accounts_list.addItem(
                profile["login"]
            )

        if self.accounts_list.count():

            self.accounts_list.setCurrentRow(
                0
            )

    def login_selected(self):

        item = self.accounts_list.currentItem()

        if not item:

            self.add_account()
            return

        login = item.text()

        db = Database(
            get_account_database_path(
                login
            )
        )

        values = {
            "server_url": db.get_setting(
                "server_url",
                self.server_url
            ),
            "server_token": db.get_setting(
                "server_token",
                self.server_token
            ),
            "login": db.get_setting(
                "server_login",
                login
            ),
            "public_username": db.get_setting(
                "public_username",
                login
            ),
            "password": db.get_setting(
                "server_password",
                ""
            )
        }

        if not values["password"]:

            values = ask_server_login(
                values["server_url"],
                values["server_token"],
                values["login"],
                values.get("public_username", "")
            )

            if not values:
                return

        if not self.validate_values(
            values
        ):
            return

        self.result_values = values
        self.accept()

    def add_account(self):

        values = ask_server_login(
            self.server_url,
            self.server_token,
            ""
        )

        if not values:
            return

        self.result_values = values
        self.accept()

    def validate_values(
        self,
        values
    ):

        ok, message = diagnose_server_connection_sync(
            values["server_url"],
            f"login-check-{values['login']}",
            values["login"],
            values["server_token"],
            values["login"],
            values["password"],
            public_username=values.get("public_username", "")
        )

        if not ok:

            QMessageBox.warning(
                self,
                "MeshChat",
                message
            )

            return False

        return True

    def delete_selected(self):

        item = self.accounts_list.currentItem()

        if not item:
            return

        login = item.text()

        answer = QMessageBox.question(
            self,
            "MeshChat",
            f"Удалить локальный профиль {login}?"
        )

        if answer != QMessageBox.StandardButton.Yes:
            return

        db_path = get_account_database_path(
            login
        )

        import shutil
        from pathlib import Path

        account_dir = Path(
            db_path
        ).parent

        if account_dir.exists():

            shutil.rmtree(
                account_dir
            )

        self.load_profiles()


def ask_account_manager(
    server_url="",
    server_token=""
):

    dialog = AccountManagerDialog(
        server_url,
        server_token
    )

    if dialog.exec() == QDialog.DialogCode.Accepted:
        return dialog.result_values

    return None
