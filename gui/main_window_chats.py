import os
import socket
import tempfile

from PyQt6.QtWidgets import QInputDialog, QListWidgetItem, QMenu, QMessageBox

from gui.chat_window import ChatWindow
from gui.avatar import avatar_icon
from gui.profile_dialog import ProfileDialog
from gui.request_dialog import ChatRequestDialog
from network.client import send_chat_response, send_packet
from network.message_id import generate_message_id


class MainChatsMixin:
    def toggle_archive(self):

        self.showing_archive = not self.showing_archive
        self.archive_button.setText(
            "Назад к чатам"
            if self.showing_archive
            else "Архив"
        )
        self.chats_label.setText(
            "Архив"
            if self.showing_archive
            else "Мои чаты"
        )
        self.refresh_chats()

    def add_chat_list_item(
        self,
        item,
        scope,
        last_activity=""
    ):

        archived = self.db.is_chat_archived(
            scope
        )

        if archived != self.showing_archive:
            return

        pinned = self.db.is_chat_pinned(
            scope
        )

        if pinned:
            item.setText(
                "📌 " + item.text()
            )

        if self.db.is_chat_muted(
            scope
        ):
            item.setText(
                "🔕 " + item.text()
            )

        self._chat_list_entries.append(
            (
                pinned,
                last_activity or "",
                item
            )
        )

    def toggle_chat_pin(
        self,
        scope
    ):

        self.db.set_chat_pinned(
            scope,
            not self.db.is_chat_pinned(
                scope
            )
        )
        self.refresh_chats()

    def toggle_chat_archive(
        self,
        scope
    ):

        self.db.set_chat_archived(
            scope,
            not self.db.is_chat_archived(
                scope
            )
        )
        self.refresh_chats()

    def toggle_chat_mute(
        self,
        scope
    ):

        self.db.set_chat_muted(
            scope,
            not self.db.is_chat_muted(
                scope
            )
        )
        self.refresh_chats()

    def should_notify_for_chat(
        self,
        chat_id,
        is_group=False
    ):

        scope = (
            f"group:{chat_id}"
            if is_group
            else f"chat:{chat_id}"
        )

        return not self.db.is_chat_muted(
            scope
        )

    def refresh_users(self):

        users = list(
            self.discovery.get_users()
        )

        server_users = [
            (
                node_id,
                name,
                "SERVER",
                0
            )
            for node_id, name in self.server_users.items()
            if not self.discovery.get_user_by_node_id(
                node_id
            )
        ]

        self.visible_users = users + server_users

        current = None

        if self.selected_user:
            current = self.selected_user[0]

        self.users_list.clear()

        for node_id, name, ip, port in self.visible_users:

            label = (
                "SERVER"
                if ip == "SERVER"
                else f"{ip}:{port}"
            )

            item = QListWidgetItem(
                f"{name} [{node_id[:8]}] - {label}"
            )

            profile = self.db.get_user_profile(
                node_id
            )

            avatar_path = profile[3] if profile else ""

            item.setIcon(
                avatar_icon(
                    avatar_path,
                    name,
                    node_id
                )
            )

            self.users_list.addItem(
                item
            )

        self.refresh_chats()

    def user_selected(self):

        row = self.users_list.currentRow()

        if row < 0:
            return

        if row >= len(self.visible_users):
            return

        self.selected_user = self.visible_users[row]

        node_id, name, ip, port = self.selected_user

        self.info_label.setText(
            f"""
            Имя: {name}

            Node ID:
            {node_id[:8]}

            IP:
            {ip}

            Порт:
            {port}
            """
    )

        self.chat_button.setEnabled(
            True
        )

    def start_chat(self):

        if not self.selected_user:
            return

        peer_node_id, name, ip, port = self.selected_user

        if self.db.is_contact_blocked(
            peer_node_id
        ):

            QMessageBox.warning(
                self,
                "MeshChat",
                "Пользователь заблокирован. Сначала разблокируйте его."
            )

            return

        if ip == "SERVER":

            self.db.update_user(
                peer_node_id,
                name,
                "SERVER",
                0
            )

            self.db.set_contact_status(
                peer_node_id,
                "friend"
            )

            self.open_chat(
                name,
                peer_node_id,
                "SERVER",
                0,
                "server"
            )

            return

        sender_ip = socket.gethostbyname(
            socket.gethostname()
        )

        self.db.set_contact_status(
            peer_node_id,
            "outgoing"
        )

        packet = {

            "packet_id": generate_message_id(),

            "type": "chat_request",

            "source_node": self.node_id,

            "destination_node": peer_node_id,

            "ttl": 5,

            "from_name": self.username,

            "from_node_id": self.node_id,

            "sender_ip": sender_ip,

            "sender_port": self.discovery.tcp_port
        }

        send_packet(
            ip,
            port,
            packet
        )

        QMessageBox.information(
            self,
            "MeshChat",
            f"Запрос отправлен пользователю {name}"
        )

    def show_chat_request(
            self,
            packet
    ):

        username = packet.get(
            "from_name"
        )

        peer_node_id = packet.get(
            "from_node_id"
        )

        if self.db.is_contact_blocked(
            peer_node_id
        ):
            return

        sender_ip = packet.get(
            "sender_ip"
        )

        sender_port = packet.get(
            "sender_port"
        )

        server_request = (
            packet.get("sender_transport") == "server"
            or sender_ip == "SERVER"
        )

        self.notify(
            "Новый запрос",
            f"{username} хочет начать чат"
        )

        accepted = ChatRequestDialog.show(
            self,
            username
        )


        if accepted:

            self.db.set_contact_status(
                peer_node_id,
                "friend"
            )

            self.open_chat(
                username,
                peer_node_id,
                "SERVER" if server_request else sender_ip,
                0 if server_request else sender_port,
                "server" if server_request else None
            )

        else:

            self.db.set_contact_status(
                peer_node_id,
                "incoming"
            )

        if server_request:

            self.send_server_packet(
                {
                    "packet_id": generate_message_id(),
                    "type": "chat_response",
                    "source_node": self.node_id,
                    "destination_node": peer_node_id,
                    "ttl": 5,
                    "accepted": accepted,
                    "from_name": self.username,
                    "from_node_id": self.node_id,
                    "sender_ip": "SERVER",
                    "sender_port": 0,
                    "sender_transport": "server"
                }
            )

        else:

            send_chat_response(
                sender_ip,
                sender_port,
                accepted,
                self.node_id,
                peer_node_id
            )

    def open_chat(
        self,
        peer_name,
        peer_node_id,
        peer_ip,
        peer_port,
        transport=None,
        bluetooth_address=None,
        bluetooth_channel=None
    ):

        if transport is None:

            transport = "tcp"

            if isinstance(
                peer_ip,
                str
            ) and peer_ip.startswith("BT:"):

                transport = "bluetooth"
                bluetooth_address = peer_ip[3:]
                bluetooth_channel = peer_port

            elif peer_ip == "SERVER":

                transport = "server"

        if peer_node_id in self.chat_windows:

            self.chat_windows[
                peer_node_id
            ].show()

            return

        chat = ChatWindow(
            self.username,
            self.node_id,
            peer_name,
            peer_node_id,
            peer_ip,
            peer_port,
            self.register_pending_file,
            transport,
            bluetooth_address,
            bluetooth_channel,
            self.send_server_packet,
            self.compress_images,
            self.forward_content,
            self.encrypt_direct_message,
            self.encrypt_direct_file,
            self.refresh_chats
        )

        chat.show()

        self.chat_windows[
            peer_node_id
        ] = chat

    def forward_content(
        self,
        content_type,
        content,
        filename="",
        parent=None
    ):

        targets = []

        for node_id in self.db.get_contacts(
            self.node_id
        ):

            if (
                not node_id
                or node_id == self.node_id
                or self.db.is_contact_blocked(
                    node_id
                )
            ):
                continue

            name = (
                self.db.get_user_name(
                    node_id
                )
                or node_id[:8]
            )

            targets.append(
                (
                    f"Личный чат: {name} ({node_id[:8]})",
                    "chat",
                    node_id
                )
            )

        for group_id, group_name in self.db.get_groups():

            targets.append(
                (
                    f"Группа: {group_name}",
                    "group",
                    group_id
                )
            )

        if not targets:

            QMessageBox.information(
                parent or self,
                "Переслать",
                "Нет доступных чатов."
            )

            return

        labels = [
            target[0]
            for target in targets
        ]

        selected, ok = QInputDialog.getItem(
            parent or self,
            "Переслать",
            "Выберите чат:",
            labels,
            0,
            False
        )

        if not ok:
            return

        _, target_type, target_id = targets[
            labels.index(
                selected
            )
        ]

        if target_type == "chat":

            self.open_chat_by_node_id(
                target_id
            )

            target_window = self.chat_windows.get(
                target_id
            )

        else:

            self.open_group_chat(
                target_id
            )

            target_window = self.group_windows.get(
                target_id
            )

        if not target_window:
            return

        if content_type == "message":

            target_window.input.setText(
                content
            )

            target_window.send_message()

            return

        if content_type != "file" or not content or not filename:
            return

        try:

            folder = os.path.join(
                tempfile.gettempdir(),
                "meshchat_forward"
            )

            os.makedirs(
                folder,
                exist_ok=True
            )

            path = os.path.join(
                folder,
                os.path.basename(
                    filename
                )
            )

            with open(
                path,
                "wb"
            ) as file:

                file.write(
                    bytes.fromhex(
                        content
                    )
                )

            target_window.send_file_path(
                path
            )

        except (OSError, ValueError) as error:

            QMessageBox.warning(
                parent or self,
                "Переслать",
                f"Не удалось переслать файл: {error}"
            )

    def show_chat_response(
            self,
            packet
    ):

        accepted = packet.get(
            "accepted"
        )

        if accepted:

            peer_node_id = packet.get(
                "source_node"
            ) or packet.get(
                "from_node_id"
            )

            if peer_node_id:

                self.db.set_contact_status(
                    peer_node_id,
                    "friend"
                )

            if not self.selected_user:

                name = packet.get(
                    "from_name"
                ) or self.db.get_user_name(
                    peer_node_id
                )

                if peer_node_id:

                    self.db.update_user(
                        peer_node_id,
                        name,
                        "SERVER",
                        0
                    )

                    self.open_chat(
                        name,
                        peer_node_id,
                        "SERVER",
                        0,
                        "server"
                    )

                return

            peer_node_id, name, ip, port = self.selected_user

            self.open_chat(
                name,
                peer_node_id,
                ip,
                port
            )

        else:

            peer_node_id = packet.get(
                "source_node"
            ) or packet.get(
                "from_node_id"
            )

            if peer_node_id:

                self.db.clear_contact_status(
                    peer_node_id
                )

            QMessageBox.information(
                self,
                "MeshChat",
                "Запрос отклонён"
            )

    def refresh_chats(self):


        contacts = self.db.get_contacts(
            self.node_id
        )

        contacts = list(
            dict.fromkeys(
                contacts
                + self.db.get_bluetooth_contacts()
            )
        )

        self.chats_list.clear()
        self._chat_list_entries = []

        for group_id, group_name in self.db.get_groups():

            last_activity = self.db.get_group_last_activity(
                group_id
            )

            item = QListWidgetItem(
                f"[GROUP] {group_name}"
            )

            draft = self.db.get_draft(
                f"group:{group_id}"
            )

            if draft:
                preview = " ".join(
                    draft.split()
                )[:60]
                item.setText(
                    f"[GROUP] {group_name}\nЧерновик: {preview}"
                )
            elif last_activity:
                item_type, content, _ = last_activity
                preview = " ".join(
                    (content or "").split()
                )[:60]
                if item_type == "file":
                    preview = f"Файл: {preview}"
                item.setText(
                    f"[GROUP] {group_name}\n{preview}"
                )

            item.setIcon(
                avatar_icon(
                    "",
                    group_name,
                    group_id
                )
            )

            item.setData(
                100,
                f"group:{group_id}"
            )

            self.add_chat_list_item(
                item,
                f"group:{group_id}",
                last_activity[2] if last_activity else ""
            )

        for contact in contacts:

            last_activity = self.db.get_chat_last_activity(
                self.node_id,
                contact
            )

            display_name = self.db.get_user_name(
                contact
            )

            unread = self.db.get_unread(
                contact,
                self.node_id
            )

            online = self.discovery.get_user_by_node_id(
                contact
            )

            transport_label = "LAN"
            status_label = "offline"

            if online:
                status_label = "online"

            info = self.db.get_user_info(
                contact
            )

            if (
                info
                and isinstance(
                    info[1],
                    str
                )
                and info[1].startswith("BT:")
            ):

                transport_label = "BT"
                status_label = "saved"

            elif (
                info
                and info[1] == "SERVER"
            ):

                transport_label = "SERVER"
                status_label = (
                    "online"
                    if contact in self.server_users
                    else "saved"
                )

            title = (
                f"[{transport_label}] "
                f"{display_name} "
                f"- {status_label}"
            )

            contact_status = self.db.get_contact_status(
                contact
            )

            if contact_status == "outgoing":
                title = f"[REQUEST] {display_name} - sent"
            elif contact_status == "incoming":
                title = f"[REQUEST] {display_name} - incoming"
            elif contact_status == "blocked":
                title = f"[BLOCKED] {display_name}"
            elif contact_status == "friend":
                title = f"[FRIEND] {title}"

            if unread > 0:

                title += f" ({unread})"

            draft = self.db.get_draft(
                f"chat:{contact}"
            )

            if draft:
                preview = " ".join(
                    draft.split()
                )[:60]
                title += f"\nЧерновик: {preview}"
            elif last_activity:
                item_type, content, _ = last_activity
                preview = " ".join(
                    (content or "").split()
                )[:60]
                if item_type == "file":
                    preview = f"Файл: {preview}"
                title += f"\n{preview}"

            item = QListWidgetItem(
                title
            )

            profile = self.db.get_user_profile(
                contact
            )

            avatar_path = profile[3] if profile else ""

            item.setIcon(
                avatar_icon(
                    avatar_path,
                    display_name,
                    contact
                )
            )

            item.setData(
                100,
                contact
            )

            self.add_chat_list_item(
                item,
                f"chat:{contact}",
                last_activity[2] if last_activity else ""
            )

        self._chat_list_entries.sort(
            key=lambda entry: (
                entry[0],
                entry[1]
            ),
            reverse=True
        )

        for _, _, item in self._chat_list_entries:
            self.chats_list.addItem(
                item
            )

    def open_saved_chat(
        self,
        item
    ):

        peer_node_id = item.data(
            100
        )

        if (
            isinstance(
                peer_node_id,
                str
            )
            and peer_node_id.startswith("group:")
        ):

            self.open_group_chat(
                peer_node_id[6:]
            )

            return

        self.open_chat_by_node_id(
            peer_node_id
        )

    def open_chat_by_node_id(
        self,
        peer_node_id
    ):

        peer = self.discovery.get_user_by_node_id(
            peer_node_id
        )

        if peer:

            ip, port = peer

        else:

            info = self.db.get_user_info(
                peer_node_id
            )

            if info:

                _, ip, port = info

            else:

                ip = "127.0.0.1"
                port = 0

        peer_name = self.db.get_user_name(
            peer_node_id
        )

        self.open_chat(
            peer_name,
            peer_node_id,
            ip,
            port
        )

    def show_chat_context_menu(
        self,
        position
    ):

        item = self.chats_list.itemAt(
            position
        )

        if not item:
            return

        peer_node_id = item.data(
            100
        )

        if (
            isinstance(
                peer_node_id,
                str
            )
            and peer_node_id.startswith("group:")
        ):

            group_id = peer_node_id[6:]

            menu = QMenu(
                self
            )

            open_action = menu.addAction(
                "Открыть"
            )

            info_action = menu.addAction(
                "Информация"
            )

            manage_action = menu.addAction(
                "Настроить"
            )

            menu.addSeparator()

            scope = f"group:{group_id}"

            pin_action = menu.addAction(
                "Открепить"
                if self.db.is_chat_pinned(scope)
                else "Закрепить"
            )

            archive_action = menu.addAction(
                "Вернуть из архива"
                if self.db.is_chat_archived(scope)
                else "Архивировать"
            )

            mute_action = menu.addAction(
                "Включить уведомления"
                if self.db.is_chat_muted(scope)
                else "Отключить уведомления"
            )

            menu.addSeparator()

            delete_action = menu.addAction(
                "Удалить группу"
            )

            action = menu.exec(
                self.chats_list.mapToGlobal(
                    position
                )
            )

            if action == open_action:

                self.open_group_chat(
                    group_id
                )

            elif action == info_action:

                self.show_group_info(
                    group_id
                )

            elif action == manage_action:

                self.manage_group_dialog(
                    group_id
                )

            elif action == pin_action:

                self.toggle_chat_pin(
                    scope
                )

            elif action == archive_action:

                self.toggle_chat_archive(
                    scope
                )

            elif action == mute_action:

                self.toggle_chat_mute(
                    scope
                )

            elif action == delete_action:

                self.delete_group(
                    group_id
                )

            return

        menu = QMenu(
            self
        )

        contact_status = self.db.get_contact_status(
            peer_node_id
        )

        accept_action = None
        unblock_action = None

        if contact_status == "incoming":
            accept_action = menu.addAction(
                "Accept request"
            )

        if contact_status == "blocked":
            unblock_action = menu.addAction(
                "Unblock"
            )

        block_action = menu.addAction(
            "Block"
        )

        open_action = menu.addAction(
            "Открыть"
        )

        info_action = menu.addAction(
            "Информация"
        )

        menu.addSeparator()

        scope = f"chat:{peer_node_id}"

        pin_action = menu.addAction(
            "Открепить"
            if self.db.is_chat_pinned(scope)
            else "Закрепить"
        )

        archive_action = menu.addAction(
            "Вернуть из архива"
            if self.db.is_chat_archived(scope)
            else "Архивировать"
        )

        mute_action = menu.addAction(
            "Включить уведомления"
            if self.db.is_chat_muted(scope)
            else "Отключить уведомления"
        )

        menu.addSeparator()

        clear_action = menu.addAction(
            "Очистить историю"
        )

        delete_action = menu.addAction(
            "Удалить чат"
        )

        action = menu.exec(
            self.chats_list.mapToGlobal(
                position
            )
        )

        if action == open_action:

            self.open_chat_by_node_id(
                peer_node_id
            )

        elif action == info_action:

            self.show_contact_info(
                peer_node_id
            )

        elif action == pin_action:

            self.toggle_chat_pin(
                scope
            )

        elif action == archive_action:

            self.toggle_chat_archive(
                scope
            )

        elif action == mute_action:

            self.toggle_chat_mute(
                scope
            )

        elif action == clear_action:

            self.clear_saved_chat(
                peer_node_id
            )

        elif action == accept_action:

            self.db.set_contact_status(
                peer_node_id,
                "friend"
            )

            self.refresh_chats()

        elif action == unblock_action:

            self.db.set_contact_status(
                peer_node_id,
                "friend"
            )

            self.refresh_chats()

        elif action == delete_action:

            self.delete_saved_chat(
                peer_node_id
            )

        elif action == block_action:

            self.block_contact(
                peer_node_id
            )

    def close_chat_window(
        self,
        peer_node_id
    ):

        if peer_node_id not in self.chat_windows:
            return

        chat = self.chat_windows.pop(
            peer_node_id
        )

        chat.close()

    def show_contact_info(
        self,
        peer_node_id
    ):

        peer_name = self.db.get_user_name(
            peer_node_id
        )

        info = self.db.get_user_info(
            peer_node_id
        )

        profile = self.db.get_user_profile(
            peer_node_id
        )

        avatar_path = profile[3] if profile and profile[3] else ""
        public_username = profile[4] if profile and len(profile) > 4 and profile[4] else ""
        about = profile[5] if profile and len(profile) > 5 and profile[5] else "-"

        online = self.discovery.get_user_by_node_id(
            peer_node_id
        )

        transport = "LAN"
        address = "-"
        port_label = "-"

        if info:

            _, ip, port = info

            if (
                isinstance(
                    ip,
                    str
                )
                and ip.startswith("BT:")
            ):

                transport = "Bluetooth"
                address = ip[3:]
                port_label = f"channel {port}"

            elif ip == "SERVER":

                transport = "Server"
                address = self.server_url or "SERVER"
                port_label = "-"

            else:

                address = ip
                port_label = f"port {port}"

        if online:

            ip, port = online

            if transport == "LAN":

                address = ip
                port_label = f"port {port}"

        unread = self.db.get_unread(
            peer_node_id,
            self.node_id
        )

        pending = self.db.get_pending_count(
            self.node_id,
            peer_node_id
        )

        status = (
            "online"
            if online
            else "offline"
        )

        ProfileDialog.show_profile(
            self,
            peer_name,
            peer_node_id,
            avatar_path,
            about,
            public_username,
            transport,
            address,
            port_label,
            status,
            unread,
            pending
        )

    def clear_saved_chat(
        self,
        peer_node_id
    ):

        peer_name = self.db.get_user_name(
            peer_node_id
        )

        answer = QMessageBox.question(
            self,
            "Очистить историю",
            f"Очистить историю с {peer_name}?"
        )

        if answer != QMessageBox.StandardButton.Yes:
            return

        self.close_chat_window(
            peer_node_id
        )

        self.db.clear_chat(
            self.node_id,
            peer_node_id
        )

        self.refresh_chats()

    def delete_saved_chat(
        self,
        peer_node_id
    ):

        peer_name = self.db.get_user_name(
            peer_node_id
        )

        answer = QMessageBox.question(
            self,
            "Удалить чат",
            f"Удалить чат с {peer_name}?"
        )

        if answer != QMessageBox.StandardButton.Yes:
            return

        self.close_chat_window(
            peer_node_id
        )

        self.db.clear_chat(
            self.node_id,
            peer_node_id
        )

        self.db.delete_contact(
            peer_node_id
        )

        self.refresh_chats()

    def block_contact(
        self,
        peer_node_id
    ):

        peer_name = self.db.get_user_name(
            peer_node_id
        )

        answer = QMessageBox.question(
            self,
            "MeshChat",
            f"Block {peer_name}?"
        )

        if answer != QMessageBox.StandardButton.Yes:
            return

        self.close_chat_window(
            peer_node_id
        )

        self.db.set_contact_status(
            peer_node_id,
            "blocked"
        )

        self.refresh_chats()

    def change_name(self):

        name, ok = QInputDialog.getText(
            self,
            "Изменение имени",
            "Введите новое имя:"
        )

        if not ok:
            return

        name = name.strip()

        if not name:
            return

        self.settings_name_input.setText(
            name
        )

        self.save_settings()

    def show_file_message(
        self,
        sender,
        sender_node_id,
        filename,
        data,
        file_id
    ):

        if sender_node_id in self.chat_windows:

            self.chat_windows[
                sender_node_id
            ].receive_file(
                sender,
                sender_node_id,
                filename,
                data,
                file_id
            )

    def show_message(
        self,
        sender,
        sender_node_id,
        message
    ):

        if sender_node_id in self.chat_windows:

            self.chat_windows[
                sender_node_id
            ].receive_message(
                sender,
                sender_node_id,
                message
            )

    def show_typing(
        self,
        sender,
        sender_node_id
    ):

        if sender_node_id in self.chat_windows:

            self.chat_windows[
                sender_node_id
            ].show_typing(
                sender
            )
