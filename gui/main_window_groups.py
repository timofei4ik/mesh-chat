import uuid

from PyQt6.QtCore import Qt
from PyQt6.QtWidgets import (
    QDialog,
    QDialogButtonBox,
    QInputDialog,
    QLabel,
    QLineEdit,
    QListWidget,
    QListWidgetItem,
    QMessageBox,
    QVBoxLayout,
)

from gui.group_chat_window import GroupChatWindow
from gui.avatar import avatar_icon
from gui.profile_dialog import ProfileDialog
from network.message_id import generate_message_id
from network.protocol import (
    group_delete_packet,
    group_message_packet,
    group_update_packet,
)


class GroupsMixin:
    def get_group_name(
        self,
        group_id
    ):

        for saved_group_id, group_name in self.db.get_groups():

            if saved_group_id == group_id:
                return group_name

        return group_id[:8]

    def create_group_dialog(self):

        contacts = self.db.get_contacts(
            self.node_id
        )

        contacts = list(
            dict.fromkeys(
                contacts
                + self.db.get_bluetooth_contacts()
            )
        )

        if not contacts:

            QMessageBox.information(
                self,
                "Группа",
                "Сначала добавьте хотя бы один чат."
            )

            return

        group_name, ok = QInputDialog.getText(
            self,
            "Новая группа",
            "Название группы:"
        )

        if not ok:
            return

        group_name = group_name.strip()

        if not group_name:
            return

        dialog = QDialog(
            self
        )

        dialog.setWindowTitle(
            "Участники группы"
        )

        layout = QVBoxLayout(
            dialog
        )

        hint = QLabel(
            "Выберите участников:"
        )

        layout.addWidget(
            hint
        )

        members_list = QListWidget()

        for contact in contacts:

            item = QListWidgetItem(
                self.db.get_user_name(
                    contact
                )
            )

            item.setData(
                100,
                contact
            )

            item.setFlags(
                item.flags()
                | Qt.ItemFlag.ItemIsUserCheckable
            )

            item.setCheckState(
                Qt.CheckState.Unchecked
            )

            members_list.addItem(
                item
            )

        layout.addWidget(
            members_list
        )

        buttons = QDialogButtonBox(
            QDialogButtonBox.StandardButton.Ok
            | QDialogButtonBox.StandardButton.Cancel
        )

        buttons.accepted.connect(
            dialog.accept
        )

        buttons.rejected.connect(
            dialog.reject
        )

        layout.addWidget(
            buttons
        )

        if dialog.exec() != QDialog.DialogCode.Accepted:
            return

        members = [
            self.node_id
        ]

        for index in range(
            members_list.count()
        ):

            item = members_list.item(
                index
            )

            if item.checkState() == Qt.CheckState.Checked:

                members.append(
                    item.data(
                        100
                    )
                )

        members = list(
            dict.fromkeys(
                members
            )
        )

        if len(members) < 2:

            QMessageBox.information(
                self,
                "Группа",
                "Выберите хотя бы одного участника."
            )

            return

        group_id = str(
            uuid.uuid4()
        )

        self.db.save_group(
            group_id,
            group_name,
            members,
            self.node_id,
            []
        )

        self.create_group_encryption_key(
            group_id
        )

        self.refresh_chats()

        self.open_group_chat(
            group_id
        )

    def open_group_chat(
        self,
        group_id
    ):

        if group_id in self.group_windows:

            self.group_windows[
                group_id
            ].show()

            self.group_windows[
                group_id
            ].activateWindow()

            return

        group_name = self.get_group_name(
            group_id
        )

        window = GroupChatWindow(
            self,
            group_id,
            group_name
        )

        self.group_windows[
            group_id
        ] = window

        window.show()

    def show_group_info(
        self,
        group_id
    ):

        group_name = self.get_group_name(
            group_id
        )

        members = self.db.get_group_members(
            group_id
        )

        owner_node, admins = self.db.get_group_roles(
            group_id
        )

        member_lines = []

        for member in members:

            name = (
                self.username
                if member == self.node_id
                else self.db.get_user_name(
                    member
                )
            )

            role = ""

            if member == owner_node:
                role = " - владелец"
            elif member in admins:
                role = " - администратор"

            member_lines.append(
                f"{name} ({member[:8]}){role}"
            )

        QMessageBox.information(
            self,
            "Информация о группе",
            "\n".join(
                [
                    f"Название: {group_name}",
                    f"Group ID: {group_id}",
                    f"Участников: {len(members)}",
                    "",
                    *member_lines
                ]
            )
        )

    def show_group_members_dialog(
        self,
        group_id
    ):

        group_name = self.get_group_name(
            group_id
        )
        members = self.db.get_group_members(
            group_id
        )

        owner_node, admins = self.db.get_group_roles(
            group_id
        )

        dialog = QDialog(
            self
        )
        dialog.setWindowTitle(
            f"Участники - {group_name}"
        )

        layout = QVBoxLayout(
            dialog
        )
        layout.addWidget(
            QLabel(
                "Двойной клик по участнику откроет профиль."
            )
        )

        members_list = QListWidget()

        for member in members:

            name = (
                self.username
                if member == self.node_id
                else self.db.get_user_name(
                    member
                )
            )
            profile = self.db.get_user_profile(
                member
            )
            avatar_path = profile[3] if profile and profile[3] else ""

            role = ""

            if member == owner_node:
                role = " - владелец"
            elif member in admins:
                role = " - администратор"

            item = QListWidgetItem(
                f"{name} ({member[:8]}){role}"
            )
            item.setData(
                100,
                member
            )
            item.setIcon(
                avatar_icon(
                    avatar_path,
                    name,
                    member
                )
            )
            members_list.addItem(
                item
            )

        members_list.itemDoubleClicked.connect(
            lambda item: self.show_member_profile(
                item.data(
                    100
                )
            )
        )

        layout.addWidget(
            members_list
        )

        buttons = QDialogButtonBox(
            QDialogButtonBox.StandardButton.Close
        )
        manage_button = None

        if self.db.can_manage_group(
            group_id,
            self.node_id
        ):

            manage_button = buttons.addButton(
                "Настроить",
                QDialogButtonBox.ButtonRole.ActionRole
            )
        buttons.rejected.connect(
            dialog.reject
        )
        if manage_button:

            manage_button.clicked.connect(
                lambda: (
                    dialog.accept(),
                    self.manage_group_dialog(group_id)
                )
            )
        layout.addWidget(
            buttons
        )

        dialog.resize(
            420,
            480
        )
        dialog.exec()

    def show_member_profile(
        self,
        member_node_id
    ):

        name = (
            self.username
            if member_node_id == self.node_id
            else self.db.get_user_name(
                member_node_id
            )
        )
        profile = self.db.get_user_profile(
            member_node_id
        )
        avatar_path = profile[3] if profile and profile[3] else ""
        public_username = profile[4] if profile and len(profile) > 4 and profile[4] else ""
        about = profile[5] if profile and len(profile) > 5 and profile[5] else "-"
        info = self.db.get_user_info(
            member_node_id
        )

        transport = "Local" if member_node_id == self.node_id else "LAN"
        address = "-"
        port_label = "-"

        if info:

            _, ip, port = info

            if isinstance(ip, str) and ip.startswith("BT:"):
                transport = "Bluetooth"
                address = ip[3:]
                port_label = f"channel {port}"

            elif ip == "SERVER":
                transport = "Server"
                address = self.server_url or "SERVER"

            elif ip:
                address = ip
                port_label = f"port {port}"

        ProfileDialog.show_profile(
            self,
            name,
            member_node_id,
            avatar_path,
            about,
            public_username,
            transport,
            address,
            port_label,
            "online" if member_node_id in self.server_users else "saved",
            0,
            self.db.get_pending_count(
                self.node_id,
                member_node_id
            )
        )

    def manage_group_dialog(
        self,
        group_id
    ):

        group_name = self.get_group_name(
            group_id
        )

        current_members = self.db.get_group_members(
            group_id
        )

        owner_node, current_admins = self.db.get_group_roles(
            group_id
        )

        is_owner = self.node_id == owner_node

        if (
            not is_owner
            and self.node_id not in current_admins
        ):

            QMessageBox.warning(
                self,
                "Группа",
                "У вас нет прав для настройки этой группы."
            )

            return

        contacts = self.db.get_contacts(
            self.node_id
        )

        contacts = list(
            dict.fromkeys(
                current_members
                + contacts
                + self.db.get_bluetooth_contacts()
            )
        )

        if self.node_id not in contacts:

            contacts.insert(
                0,
                self.node_id
            )

        dialog = QDialog(
            self
        )

        dialog.setWindowTitle(
            "Настройка группы"
        )

        layout = QVBoxLayout(
            dialog
        )

        name_input = QLineEdit(
            group_name
        )

        layout.addWidget(
            QLabel(
                "Название группы:"
            )
        )

        layout.addWidget(
            name_input
        )

        layout.addWidget(
            QLabel(
                "Участники:"
            )
        )

        members_list = QListWidget()

        for contact in contacts:

            name = (
                self.username
                if contact == self.node_id
                else self.db.get_user_name(
                    contact
                )
            )

            item = QListWidgetItem(
                f"{name} ({contact[:8]})"
            )

            item.setData(
                100,
                contact
            )

            item.setFlags(
                item.flags()
                | Qt.ItemFlag.ItemIsUserCheckable
            )

            item.setCheckState(
                Qt.CheckState.Checked
                if contact in current_members
                else Qt.CheckState.Unchecked
            )

            protected_member = (
                contact == owner_node
                or (
                    not is_owner
                    and contact in current_admins
                )
                or contact == self.node_id
            )

            if protected_member:

                item.setFlags(
                    item.flags()
                    & ~Qt.ItemFlag.ItemIsEnabled
                )

                item.setCheckState(
                    Qt.CheckState.Checked
                )

            members_list.addItem(
                item
            )

        layout.addWidget(
            members_list
        )

        admins_list = QListWidget()

        if is_owner:

            layout.addWidget(
                QLabel(
                    "Администраторы:"
                )
            )

            for contact in current_members:

                if contact == owner_node:
                    continue

                name = (
                    self.username
                    if contact == self.node_id
                    else self.db.get_user_name(
                        contact
                    )
                )

                admin_item = QListWidgetItem(
                    f"{name} ({contact[:8]})"
                )

                admin_item.setData(
                    100,
                    contact
                )

                admin_item.setFlags(
                    admin_item.flags()
                    | Qt.ItemFlag.ItemIsUserCheckable
                )

                admin_item.setCheckState(
                    Qt.CheckState.Checked
                    if contact in current_admins
                    else Qt.CheckState.Unchecked
                )

                admins_list.addItem(
                    admin_item
                )

            layout.addWidget(
                admins_list
            )

        buttons = QDialogButtonBox(
            QDialogButtonBox.StandardButton.Save
            | QDialogButtonBox.StandardButton.Cancel
        )

        delete_button = None

        if is_owner:

            delete_button = buttons.addButton(
                "Удалить группу",
                QDialogButtonBox.ButtonRole.DestructiveRole
            )

        buttons.accepted.connect(
            dialog.accept
        )

        buttons.rejected.connect(
            dialog.reject
        )

        layout.addWidget(
            buttons
        )

        delete_requested = {
            "value": False
        }

        def request_delete():

            delete_requested[
                "value"
            ] = True

            dialog.accept()

        if delete_button:

            delete_button.clicked.connect(
                request_delete
            )

        if dialog.exec() != QDialog.DialogCode.Accepted:
            return

        if delete_requested[
            "value"
        ]:

            self.delete_group(
                group_id
            )

            return

        new_name = name_input.text().strip()

        if not new_name:
            return

        members = [
            owner_node
        ]

        for index in range(
            members_list.count()
        ):

            item = members_list.item(
                index
            )

            if item.checkState() == Qt.CheckState.Checked:

                members.append(
                    item.data(
                        100
                    )
                )

        members = list(
            dict.fromkeys(
                members
            )
        )

        if len(members) < 2:

            QMessageBox.information(
                self,
                "Группа",
                "В группе должен быть хотя бы один собеседник."
            )

            return

        missing_keys = self.group_members_missing_encryption_keys(
            group_id,
            members
        )

        if missing_keys:

            names = ", ".join(
                self.db.get_user_name(node_id)
                for node_id in missing_keys
            )

            QMessageBox.warning(
                self,
                "Шифрование группы",
                "Нет ключа шифрования у: "
                f"{names}. Пусть участники войдут через обновлённый клиент."
            )

            return

        if is_owner:

            admins = []

            for index in range(
                admins_list.count()
            ):

                item = admins_list.item(
                    index
                )

                admin_node = item.data(
                    100
                )

                if (
                    item.checkState() == Qt.CheckState.Checked
                    and admin_node in members
                ):

                    admins.append(
                        admin_node
                    )

        else:

            admins = [
                admin_node
                for admin_node in current_admins
                if admin_node in members
            ]

        self.db.rename_group(
            group_id,
            new_name
        )

        self.db.set_group_members(
            group_id,
            members
        )

        self.db.set_group_roles(
            group_id,
            owner_node,
            admins
        )

        if set(members) != set(current_members):

            self.create_group_encryption_key(
                group_id
            )

        if group_id in self.group_windows:

            self.group_windows[
                group_id
            ].set_group_name(
                new_name
            )

        self.refresh_chats()

        self.broadcast_group_update(
            group_id,
            new_name,
            members,
            list(
                dict.fromkeys(
                    current_members
                    + members
                )
            ),
            owner_node,
            admins
        )

    def delete_group(
        self,
        group_id
    ):

        owner_node, _ = self.db.get_group_roles(
            group_id
        )

        if self.node_id != owner_node:

            QMessageBox.warning(
                self,
                "Группа",
                "Удалить группу может только владелец."
            )

            return

        group_name = self.get_group_name(
            group_id
        )

        members = self.db.get_group_members(
            group_id
        )

        answer = QMessageBox.question(
            self,
            "Удалить группу",
            f"Удалить группу {group_name}?"
        )

        if answer != QMessageBox.StandardButton.Yes:
            return

        self.broadcast_group_delete(
            group_id,
            members
        )

        if group_id in self.group_windows:

            window = self.group_windows.pop(
                group_id
            )

            window.close()

        self.db.delete_group(
            group_id
        )

        self.refresh_chats()

    def send_group_message(
        self,
        group_id,
        text
    ):

        group_name = self.get_group_name(
            group_id
        )

        members = self.db.get_group_members(
            group_id
        )

        owner_node, admins = self.db.get_group_roles(
            group_id
        )

        missing_keys = self.group_members_missing_encryption_keys(
            group_id,
            members
        )

        if missing_keys:

            QMessageBox.warning(
                self,
                "Шифрование группы",
                "Не у всех участников получены ключи шифрования."
            )

            return

        if self.node_id not in members:

            members.append(
                self.node_id
            )

            self.db.save_group(
                group_id,
                group_name,
                members
            )

        message_id = generate_message_id()

        key_id, encrypted_text = self.encrypt_group_text(
            group_id,
            text
        )

        _, sender_key_envelope = self.build_group_key_envelope(
            group_id,
            self.node_id,
            key_id
        )

        self.db.save_group_message(
            group_id,
            message_id,
            self.node_id,
            self.username,
            text
        )

        if group_id in self.group_windows:

            self.group_windows[
                group_id
            ].add_message(
                self.username,
                text,
                True,
                message_id=message_id
            )

        for member in members:

            if member == self.node_id:
                continue

            packet = group_message_packet(
                self.node_id,
                member,
                self.username,
                group_id,
                group_name,
                members,
                text,
                message_id,
                owner_node,
                admins
            )

            _, key_envelope = self.build_group_key_envelope(
                group_id,
                member,
                key_id
            )

            packet.update(
                {
                    "message": encrypted_text,
                    "group_key_id": key_id,
                    "group_key_envelope": key_envelope,
                    "group_key_sender_envelope": sender_key_envelope
                }
            )

            sent = self.send_pending_packet(
                member,
                packet
            )

            if not sent:

                self.db.add_pending_packet(
                    packet["packet_id"],
                    self.node_id,
                    member,
                    f"[{group_name}] {text}",
                    packet
                )

    def send_group_typing(
        self,
        group_id
    ):

        group_name = self.get_group_name(
            group_id
        )

        members = self.db.get_group_members(
            group_id
        )

        for member in members:

            if member == self.node_id:
                continue

            packet = {
                "packet_id": generate_message_id(),
                "type": "group_typing",
                "source_node": self.node_id,
                "destination_node": member,
                "ttl": 5,
                "sender": self.username,
                "group_id": group_id,
                "group_name": group_name
            }

            self.send_pending_packet(
                member,
                packet
            )

    def send_group_file(
        self,
        group_id,
        file_id,
        filename,
        file_bytes,
        status_callback=None
    ):

        members = self.db.get_group_members(
            group_id
        )

        if self.node_id not in members:
            members.append(
                self.node_id
            )

        recipients = [
            member
            for member in members
            if member != self.node_id
        ]

        if not recipients:

            if status_callback:
                status_callback(
                    file_id,
                    "нет участников"
                )

            return

        chunk_size = 32 * 1024
        total_chunks = max(
            1,
            (
                len(file_bytes)
                + chunk_size
                - 1
            )
            // chunk_size
        )

        for index in range(
            total_chunks
        ):

            start = index * chunk_size
            chunk = file_bytes[
                start:start + chunk_size
            ]
            chunk_data = chunk.hex()

            for member in recipients:

                packet = {
                    "packet_id": generate_message_id(),
                    "type": "file_chunk",
                    "source_node": self.node_id,
                    "destination_node": member,
                    "ttl": 5,
                    "sender": self.username,
                    "group_id": group_id,
                    "file_id": file_id,
                    "filename": filename,
                    "chunk_index": index,
                    "total_chunks": total_chunks,
                    "data": chunk_data
                }

                sent = self.send_pending_packet(
                    member,
                    packet
                )

                if not sent:
                    self.db.add_pending_packet(
                        packet["packet_id"],
                        self.node_id,
                        member,
                        f"[group file] {filename}",
                        packet
                    )

            if status_callback:
                status_callback(
                    file_id,
                    f"отправка {int((index + 1) * 100 / total_chunks)}%"
                )

    def send_group_reaction(
        self,
        group_id,
        group_message_id,
        reaction
    ):

        members = self.db.get_group_members(
            group_id
        )

        for member in members:

            if member == self.node_id:
                continue

            packet = {
                "packet_id":
                generate_message_id(),

                "type":
                "group_reaction",

                "source_node":
                self.node_id,

                "destination_node":
                member,

                "ttl":
                5,

                "group_id":
                group_id,

                "group_message_id":
                group_message_id,

                "reaction":
                reaction
            }

            sent = self.send_pending_packet(
                member,
                packet
            )

            if not sent:

                self.db.add_pending_packet(
                    packet["packet_id"],
                    self.node_id,
                    member,
                    "[group reaction]",
                    packet
                )

    def send_group_edit(
        self,
        group_id,
        group_message_id,
        text
    ):

        members = self.db.get_group_members(
            group_id
        )

        if self.group_members_missing_encryption_keys(
            group_id,
            members
        ):

            QMessageBox.warning(
                self,
                "Шифрование группы",
                "Не у всех участников получены ключи шифрования."
            )

            return

        self.db.update_group_message(
            group_message_id,
            text
        )

        key_id, encrypted_text = self.encrypt_group_text(
            group_id,
            text
        )

        _, sender_key_envelope = self.build_group_key_envelope(
            group_id,
            self.node_id,
            key_id
        )

        for member in members:

            if member == self.node_id:
                continue

            _, key_envelope = self.build_group_key_envelope(
                group_id,
                member,
                key_id
            )

            packet = {
                "packet_id": generate_message_id(),
                "type": "group_message_edit",
                "source_node": self.node_id,
                "destination_node": member,
                "ttl": 5,
                "group_id": group_id,
                "group_message_id": group_message_id,
                "message": encrypted_text,
                "group_key_id": key_id,
                "group_key_envelope": key_envelope,
                "group_key_sender_envelope": sender_key_envelope
            }

            sent = self.send_pending_packet(
                member,
                packet
            )

            if not sent:

                self.db.add_pending_packet(
                    packet["packet_id"],
                    self.node_id,
                    member,
                    "[group edit]",
                    packet
                )

    def send_group_pin(
        self,
        group_id,
        message_id,
        text,
        is_pinned
    ):

        if not self.db.can_manage_group(
            group_id,
            self.node_id
        ):
            return

        scope = f"group:{group_id}"

        if is_pinned:
            self.db.remove_pin(
                scope,
                message_id
            )
        else:
            self.db.save_pin(
                scope,
                message_id,
                text,
                self.node_id
            )

        window = self.group_windows.get(
            group_id
        )

        if window:
            window.refresh_pinned_message()

        members = self.db.get_group_members(
            group_id
        )

        key_id, encrypted_text = self.encrypt_group_text(
            group_id,
            text
        )

        _, sender_envelope = self.build_group_key_envelope(
            group_id,
            self.node_id,
            key_id
        )

        for member in members:

            if member == self.node_id:
                continue

            _, envelope = self.build_group_key_envelope(
                group_id,
                member,
                key_id
            )

            packet = {
                "packet_id": generate_message_id(),
                "type": "group_pin",
                "source_node": self.node_id,
                "destination_node": member,
                "ttl": 5,
                "group_id": group_id,
                "message_id": message_id,
                "action": "unpin" if is_pinned else "pin",
                "text": encrypted_text,
                "group_key_id": key_id,
                "group_key_envelope": envelope,
                "group_key_sender_envelope": sender_envelope
            }

            sent = self.send_pending_packet(
                member,
                packet
            )

            if not sent:
                self.db.add_pending_packet(
                    packet["packet_id"],
                    self.node_id,
                    member,
                    "[group pin]",
                    packet
                )

    def send_group_delete_message(
        self,
        group_id,
        group_message_id
    ):

        self.db.delete_group_message(
            group_message_id
        )

        members = self.db.get_group_members(
            group_id
        )

        for member in members:

            if member == self.node_id:
                continue

            packet = {
                "packet_id": generate_message_id(),
                "type": "group_message_delete",
                "source_node": self.node_id,
                "destination_node": member,
                "ttl": 5,
                "group_id": group_id,
                "group_message_id": group_message_id
            }

            sent = self.send_pending_packet(
                member,
                packet
            )

            if not sent:

                self.db.add_pending_packet(
                    packet["packet_id"],
                    self.node_id,
                    member,
                    "[group delete message]",
                    packet
                )

    def broadcast_group_update(
        self,
        group_id,
        group_name,
        members,
        notify_members=None,
        owner_node=None,
        admins=None
    ):

        if owner_node is None:

            owner_node, admins = self.db.get_group_roles(
                group_id
            )

        if notify_members is None:

            notify_members = members

        for member in notify_members:

            if member == self.node_id:
                continue

            packet = group_update_packet(
                self.node_id,
                member,
                group_id,
                group_name,
                members,
                owner_node,
                admins
            )

            if member in members:

                key_id, key_envelope = self.build_group_key_envelope(
                    group_id,
                    member
                )

            else:

                key_id, _ = self.get_group_encryption_key(
                    group_id
                )
                key_envelope = ""

            _, sender_key_envelope = self.build_group_key_envelope(
                group_id,
                self.node_id,
                key_id
            )

            packet.update(
                {
                    "group_key_id": key_id,
                    "group_key_envelope": key_envelope,
                    "group_key_sender_envelope": sender_key_envelope
                }
            )

            sent = self.send_pending_packet(
                member,
                packet
            )

            if not sent:

                self.db.add_pending_packet(
                    packet["packet_id"],
                    self.node_id,
                    member,
                    f"[group update] {group_name}",
                    packet
                )

    def broadcast_group_delete(
        self,
        group_id,
        members
    ):

        for member in members:

            if member == self.node_id:
                continue

            packet = group_delete_packet(
                self.node_id,
                member,
                group_id
            )

            sent = self.send_pending_packet(
                member,
                packet
            )

            if not sent:

                self.db.add_pending_packet(
                    packet["packet_id"],
                    self.node_id,
                    member,
                    "[group delete]",
                    packet
                )

    def handle_group_message(
        self,
        packet
    ):

        group_id = packet.get(
            "group_id"
        )

        group_name = packet.get(
            "group_name"
        ) or "Группа"

        sender_node = packet.get(
            "source_node"
        )

        sender_name = packet.get(
            "sender"
        ) or "Unknown"

        message = packet.get(
            "message"
        )

        key_id = packet.get(
            "group_key_id"
        )

        self.accept_group_key_envelope(
            group_id,
            key_id,
            packet.get("group_key_envelope"),
            True
        )

        message = self.decrypt_group_text(
            group_id,
            key_id,
            message
        )

        if (
            not group_id
            or not sender_node
            or not message
        ):
            return

        members = packet.get(
            "members"
        ) or []

        existing_members = self.db.get_group_members(
            group_id
        )

        existing_owner, existing_admins = self.db.get_group_roles(
            group_id
        )

        if existing_members:

            if sender_node not in existing_members:
                return

            members = existing_members
            owner_node = existing_owner
            admins = existing_admins

        else:

            owner_node = (
                packet.get("owner_node")
                or sender_node
            )

            admins = packet.get(
                "admins"
            ) or []

        members = list(
            dict.fromkeys(
                members
                + [
                    self.node_id,
                    sender_node
                ]
            )
        )

        self.db.save_group(
            group_id,
            group_name,
            members,
            owner_node,
            admins
        )

        self.db.save_group_message(
            group_id,
            packet.get(
                "group_message_id"
            ) or packet.get(
                "packet_id"
            ),
            sender_node,
            sender_name,
            message
        )

        if self.should_notify_for_chat(
            group_id,
            True
        ):

            self.notify(
                group_name,
                f"{sender_name}: {message}"
            )

        if group_id in self.group_windows:

            self.group_windows[
                group_id
            ].receive_message(
                sender_name,
                message,
                packet.get(
                    "group_message_id"
                ) or packet.get(
                    "packet_id"
                )
            )

        self.refresh_chats()

    def handle_group_message_edit(
        self,
        packet
    ):

        group_id = packet.get(
            "group_id"
        )

        message_id = packet.get(
            "group_message_id"
        )

        message = packet.get(
            "message"
        )

        key_id = packet.get(
            "group_key_id"
        )

        self.accept_group_key_envelope(
            group_id,
            key_id,
            packet.get("group_key_envelope"),
            True
        )

        message = self.decrypt_group_text(
            group_id,
            key_id,
            message
        )

        if not group_id or not message_id or message is None:
            return

        self.db.update_group_message(
            message_id,
            message
        )

        if group_id in self.group_windows:

            self.group_windows[
                group_id
            ].apply_message_edit(
                message_id,
                message,
                send=False
            )

    def handle_group_message_delete(
        self,
        packet
    ):

        group_id = packet.get(
            "group_id"
        )

        message_id = packet.get(
            "group_message_id"
        )

        if not group_id or not message_id:
            return

        self.db.delete_group_message(
            message_id
        )

        if group_id in self.group_windows:

            self.group_windows[
                group_id
            ].apply_message_delete(
                message_id,
                send=False
            )

    def handle_group_reaction(
        self,
        packet
    ):

        group_id = packet.get(
            "group_id"
        )

        message_id = packet.get(
            "group_message_id"
        )

        reaction = packet.get(
            "reaction"
        )

        sender_node = packet.get(
            "source_node"
        )

        if (
            group_id
            and message_id
            and reaction
        ):

            self.db.save_reaction(
                f"group:{group_id}",
                message_id,
                sender_node,
                reaction
            )

            if group_id in self.group_windows:

                self.group_windows[
                    group_id
                ].apply_reaction(
                    message_id,
                    reaction,
                    sender_node
                )

    def handle_group_pin(
        self,
        packet
    ):

        group_id = packet.get(
            "group_id"
        )
        message_id = packet.get(
            "message_id"
        )
        sender_node = packet.get(
            "source_node"
        )

        if (
            not group_id
            or not message_id
            or not self.db.can_manage_group(
                group_id,
                sender_node
            )
        ):
            return

        scope = f"group:{group_id}"

        if packet.get("action") == "unpin":
            self.db.remove_pin(
                scope,
                message_id
            )
        else:
            self.accept_group_key_envelope(
                group_id,
                packet.get("group_key_id"),
                packet.get("group_key_envelope"),
                True
            )
            self.db.save_pin(
                scope,
                message_id,
                self.decrypt_group_text(
                    group_id,
                    packet.get("group_key_id"),
                    packet.get("text") or ""
                ),
                sender_node
            )

        window = self.group_windows.get(
            group_id
        )

        if window:
            window.refresh_pinned_message()

    def handle_group_update(
        self,
        packet
    ):

        group_id = packet.get(
            "group_id"
        )

        group_name = packet.get(
            "group_name"
        ) or "Группа"

        members = packet.get(
            "members"
        ) or []

        if not group_id:
            return

        sender_node = packet.get(
            "source_node"
        )

        current_owner, current_admins = self.db.get_group_roles(
            group_id
        )

        claimed_owner = packet.get(
            "owner_node"
        )

        if (
            not claimed_owner
            or claimed_owner not in members
        ):
            return

        if current_owner:

            if (
                sender_node != current_owner
                and sender_node not in current_admins
            ):
                return

            if claimed_owner != current_owner:
                return

            if sender_node != current_owner:

                claimed_admins = packet.get(
                    "admins"
                ) or []

                if (
                    set(claimed_admins) != set(current_admins)
                    or current_owner not in members
                    or any(
                        admin_node not in members
                        for admin_node in current_admins
                    )
                ):
                    return

        elif sender_node != claimed_owner:
            return

        if self.node_id in members:

            self.accept_group_key_envelope(
                group_id,
                packet.get("group_key_id"),
                packet.get("group_key_envelope"),
                True
            )

        if self.node_id not in members:

            if group_id in self.group_windows:

                window = self.group_windows.pop(
                    group_id
                )

                window.close()

            self.db.delete_group(
                group_id
            )

            self.refresh_chats()

            return

        members = list(
            dict.fromkeys(
                members
            )
        )

        self.db.save_group(
            group_id,
            group_name,
            members,
            claimed_owner or current_owner,
            packet.get("admins")
        )

        self.db.set_group_members(
            group_id,
            members
        )

        if group_id in self.group_windows:

            self.group_windows[
                group_id
            ].set_group_name(
                group_name
            )

        self.refresh_chats()

    def handle_group_delete(
        self,
        packet
    ):

        group_id = packet.get(
            "group_id"
        )

        if not group_id:
            return

        owner_node, _ = self.db.get_group_roles(
            group_id
        )

        if packet.get(
            "source_node"
        ) != owner_node:
            return

        if group_id in self.group_windows:

            window = self.group_windows.pop(
                group_id
            )

            window.close()

        self.db.delete_group(
            group_id
        )

        self.refresh_chats()
