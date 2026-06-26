from PyQt6.QtWidgets import QMessageBox

from network.server_transport import (
    ServerTransport,
    diagnose_server_connection_sync
)
from network.server_url import normalize_server_url
from network.message_id import generate_message_id
from storage.database import Database, get_database_dir

import threading


class ServerMixin:
    def start_server_transport(self):

        if self.server_transport:

            self.server_transport.stop()
            self.server_transport = None

        if not self.server_url:

            self.update_server_status(
                "Сервер не настроен"
            )

            return

        self.server_transport = ServerTransport(
            self.server_url,
            self.node_id,
            self.username,
            self.packet_signal.emit,
            self.server_users_signal.emit,
            self.server_status_signal.emit,
            self.server_token,
            self.server_login,
            self.server_password,
            self.public_username,
            self.profile_about,
            self.profile_avatar_data,
            self.encryption_public_key
        )

        self.server_transport.start()

    def update_server_users(
        self,
        users
    ):

        self.server_users = {}

        for user in users:

            node_id = user.get(
                "node_id"
            )

            username = user.get(
                "username"
            ) or node_id

            if (
                not node_id
                or node_id == self.node_id
            ):
                continue

            self.server_users[
                node_id
            ] = username

            self.db.update_user(
                node_id,
                username,
                "SERVER",
                0
            )

            self.apply_profile_data(
                {
                    "node_id": node_id,
                    "display_name": username,
                    "public_username": user.get("public_username") or "",
                    "about": user.get("about") or "",
                    "avatar_data": user.get("avatar_data") or "",
                    "encryption_public_key": user.get("encryption_public_key") or ""
                }
            )

        self.refresh_users()
        self.refresh_chats()

    def update_server_status(
        self,
        status
    ):

        self.settings_server_status_label.setText(
            status
        )

    def apply_server_sync(
        self,
        packet
    ):

        self.apply_profile_data(
            packet.get("profile")
        )

        for profile in packet.get(
            "profiles",
            []
        ):

            self.apply_profile_data(
                profile
            )

        for message in packet.get(
            "direct_messages",
            []
        ):

            sender_node = message.get(
                "sender_node"
            )

            receiver_node = message.get(
                "receiver_node"
            )

            text = message.get(
                "message"
            )

            text = self.decrypt_direct_message(
                text
            )

            message_id = message.get(
                "message_id"
            )

            if not sender_node or not receiver_node or not text:
                continue

            if sender_node != self.node_id:

                self.db.update_user(
                    sender_node,
                    message.get("sender_name") or sender_node[:8],
                    "SERVER",
                    0
                )

            self.db.save_message(
                sender_node,
                receiver_node,
                text,
                message_id,
                message.get("created_at")
            )

        for group in packet.get(
            "groups",
            []
        ):

            group_id = group.get(
                "group_id"
            )

            if not group_id:
                continue

            self.db.save_group(
                group_id,
                group.get("group_name") or group_id,
                group.get("members") or [],
                group.get("owner_node"),
                group.get("admins")
            )

            group_keys = group.get(
                "group_keys"
            ) or []

            for index, key_info in enumerate(
                group_keys
            ):

                self.accept_group_key_envelope(
                    group_id,
                    key_info.get("key_id"),
                    key_info.get("key_envelope"),
                    index == len(group_keys) - 1
                )

        for message in packet.get(
            "group_messages",
            []
        ):

            group_id = message.get(
                "group_id"
            )

            message_id = message.get(
                "message_id"
            )

            if not group_id or not message_id:
                continue

            members = message.get(
                "members"
            ) or []

            self.db.save_group(
                group_id,
                message.get("group_name") or group_id,
                members
            )

            self.db.save_group_message(
                group_id,
                message_id,
                message.get("sender_node"),
                message.get("sender_name") or "",
                self.decrypt_group_text(
                    group_id,
                    message.get("group_key_id"),
                    message.get("message") or ""
                ),
                message.get("created_at")
            )

        for reaction in packet.get(
            "reactions",
            []
        ):

            scope = reaction.get(
                "scope"
            )

            local_scope = (
                scope
                if scope and scope.startswith("group:")
                else "chat"
            )

            self.db.save_reaction(
                local_scope,
                reaction.get("message_id"),
                reaction.get("reactor_node"),
                reaction.get("reaction")
            )

        pin_scopes = {
            f"group:{group.get('group_id')}"
            for group in packet.get("groups", [])
            if group.get("group_id")
        }

        for message in packet.get(
            "direct_messages",
            []
        ):

            sender_node = message.get("sender_node")
            receiver_node = message.get("receiver_node")

            if sender_node and receiver_node:
                pin_scopes.add(
                    "chat:" + ":".join(
                        sorted(
                            (
                                sender_node,
                                receiver_node
                            )
                        )
                    )
                )

        for scope in pin_scopes:
            self.db.clear_pins(
                scope
            )

        for pin in packet.get(
            "pins",
            []
        ):

            scope = pin.get(
                "scope"
            ) or ""

            text = pin.get(
                "text"
            ) or ""

            if scope.startswith("group:"):

                text = self.decrypt_group_text(
                    scope[6:],
                    pin.get("group_key_id"),
                    text
                )

            else:

                text = self.decrypt_direct_message(
                    text
                )

            self.db.save_pin(
                scope,
                pin.get("message_id"),
                text,
                pin.get("pinner_node")
            )

        for chat in self.chat_windows.values():
            chat.refresh_pinned_message()

        for chat in self.group_windows.values():
            chat.refresh_pinned_message()

        for file_info in packet.get(
            "files",
            []
        ):

            sender_node = file_info.get(
                "sender_node"
            )

            filename = file_info.get(
                "filename"
            )

            data = file_info.get(
                "data"
            )

            if not file_info.get(
                "group_id"
            ):

                filename, data = self.decrypt_direct_file(
                    filename,
                    data
                )

            if not sender_node or not filename or not data:
                continue

            if file_info.get("group_id"):

                receiver_node = f"group:{file_info.get('group_id')}"

                filename, data = self.decrypt_group_file(
                    file_info.get("group_id"),
                    file_info.get("group_key_id"),
                    filename,
                    data
                )

            else:

                receiver_node = file_info.get(
                    "receiver_node"
                ) or self.node_id

            if sender_node != self.node_id:

                self.db.update_user(
                    sender_node,
                    file_info.get("sender_name") or sender_node[:8],
                    "SERVER",
                    0
                )

            self.db.save_file(
                sender_node,
                receiver_node,
                filename,
                data,
                file_info.get("file_id"),
                file_info.get("created_at")
            )

        self.refresh_chats()

    def apply_server_file_sync_chunk(
        self,
        packet
    ):

        file_id = packet.get(
            "file_id"
        )

        filename = packet.get(
            "filename"
        )

        chunk_index = packet.get(
            "chunk_index"
        )

        total_chunks = packet.get(
            "total_chunks"
        )

        data = packet.get(
            "data"
        )

        if (
            not file_id
            or not filename
            or chunk_index is None
            or not total_chunks
            or data is None
        ):
            return

        transfer = self.server_file_sync_chunks.setdefault(
            file_id,
            {
                "file_info": dict(
                    packet
                ),
                "total_chunks": total_chunks,
                "chunks": {}
            }
        )

        transfer["chunks"][
            chunk_index
        ] = data

        if len(
            transfer["chunks"]
        ) != transfer["total_chunks"]:
            return

        file_info = transfer[
            "file_info"
        ]

        sender_node = file_info.get(
            "sender_node"
        )

        if not sender_node:
            self.server_file_sync_chunks.pop(
                file_id,
                None
            )
            return

        if file_info.get(
            "group_id"
        ):
            receiver_node = (
                f"group:{file_info.get('group_id')}"
            )
        else:
            receiver_node = (
                file_info.get(
                    "receiver_node"
                )
                or self.node_id
            )

        full_data = "".join(
            transfer["chunks"][index]
            for index in range(
                transfer["total_chunks"]
            )
        )

        if file_info.get(
            "group_id"
        ):

            filename, full_data = self.decrypt_group_file(
                file_info.get("group_id"),
                file_info.get("group_key_id"),
                filename,
                full_data
            )

        else:

            filename, full_data = self.decrypt_direct_file(
                filename,
                full_data
            )

        self.db.save_file(
            sender_node,
            receiver_node,
            filename,
            full_data,
            file_id,
            file_info.get("created_at")
        )

        self.server_file_sync_chunks.pop(
            file_id,
            None
        )

        if packet.get(
            "file_number"
        ) == packet.get(
            "total_files"
        ):
            self.refresh_chats()

    def send_server_packet(
        self,
        packet
    ):

        if not self.server_transport:
            return False

        return self.server_transport.send_packet(
            packet
        )

    def lookup_username(self):

        username = self.username_search_input.text().strip().lstrip("@").lower()

        if not username:
            return

        if not self.server_transport:

            QMessageBox.warning(
                self,
                "MeshChat",
                "Сервер не подключен."
            )
            return

        ok = self.send_server_packet(
            {
                "type": "username_lookup",
                "source_node": self.node_id,
                "username": username
            }
        )

        if not ok:

            QMessageBox.warning(
                self,
                "MeshChat",
                "Не удалось отправить запрос на сервер."
            )

    def handle_username_lookup_result(
        self,
        packet
    ):

        if not packet.get("ok"):

            QMessageBox.information(
                self,
                "MeshChat",
                "Пользователь не найден."
            )
            return

        profile = packet.get("profile") or {}
        node_id = profile.get("node_id")

        if not node_id:
            return

        if self.db.is_contact_blocked(
            node_id
        ):

            QMessageBox.warning(
                self,
                "MeshChat",
                "Пользователь заблокирован."
            )

            return

        self.apply_profile_data(
            profile
        )

        name = (
            profile.get("display_name")
            or profile.get("public_username")
            or node_id[:8]
        )

        self.db.update_user(
            node_id,
            name,
            "SERVER",
            0
        )

        self.db.set_contact_status(
            node_id,
            "outgoing"
        )

        self.refresh_chats()

        ok = self.send_server_packet(
            {
                "packet_id": generate_message_id(),
                "type": "chat_request",
                "source_node": self.node_id,
                "destination_node": node_id,
                "ttl": 5,
                "from_name": self.username,
                "from_node_id": self.node_id,
                "sender_ip": "SERVER",
                "sender_port": 0,
                "sender_transport": "server"
            }
        )

        QMessageBox.information(
            self,
            "MeshChat",
            "Запрос в чат отправлен." if ok else "Не удалось отправить запрос."
        )

    def handle_profile_update_result(
        self,
        packet
    ):

        if packet.get("ok"):
            return

        reason = packet.get("reason") or "profile update failed"

        if reason == "username is already taken":

            QMessageBox.warning(
                self,
                "MeshChat",
                "Этот @username уже занят."
            )

            saved_username = self.db.get_setting(
                "public_username",
                self.server_login
            )

            self.public_username = saved_username
            self.settings_public_username_input.setText(
                saved_username
            )

            return

        QMessageBox.warning(
            self,
            "MeshChat",
            reason
        )

    def test_server_connection(self):

        server_url = normalize_server_url(
            self.settings_server_input.text()
        )

        if not server_url:

            self.update_server_status(
                "Укажите адрес сервера"
            )

            return

        server_token = self.settings_server_token_input.text().strip()
        server_login = self.settings_server_login_input.text().strip()
        server_password = self.settings_server_password_input.text()

        self.settings_server_test_button.setEnabled(
            False
        )

        self.update_server_status(
            "Проверка сервера..."
        )

        def worker():

            ok, message = diagnose_server_connection_sync(
                server_url,
                self.node_id,
                self.username,
                server_token,
                server_login,
                server_password,
                public_username=self.public_username
            )

            status = (
                message
                if ok
                else f"Ошибка проверки: {message}"
            )

            self.server_test_done_signal.emit(
                status
            )

        threading.Thread(
            target=worker,
            daemon=True
        ).start()

    def finish_server_connection_test(
        self,
        status
    ):

        self.update_server_status(
            status
        )

        self.settings_server_test_button.setEnabled(
            True
        )

    def save_global_server_settings(
        self,
        server_url,
        server_token,
        server_login,
        server_password
    ):

        global_db = Database(
            str(
                get_database_dir() / "messages.db"
            )
        )

        global_db.set_setting(
            "server_url",
            server_url
        )

        global_db.set_setting(
            "server_token",
            server_token
        )

        global_db.set_setting(
            "server_login",
            server_login
        )

        global_db.set_setting(
            "server_password",
            server_password
        )

    def logout_server_account(self):

        if self.server_transport:

            self.server_transport.stop()
            self.server_transport = None

        self.server_token = ""
        self.server_login = ""
        self.server_password = ""

        self.settings_server_token_input.clear()
        self.settings_server_login_input.clear()
        self.settings_server_password_input.clear()

        self.db.set_setting(
            "server_token",
            ""
        )

        self.db.set_setting(
            "server_login",
            ""
        )

        self.db.set_setting(
            "server_password",
            ""
        )

        self.save_global_server_settings(
            self.server_url,
            "",
            "",
            ""
        )

        self.update_server_status(
            "Вышли из аккаунта"
        )

        QMessageBox.information(
            self,
            "MeshChat",
            "Данные входа очищены."
        )
