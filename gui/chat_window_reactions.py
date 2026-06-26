import threading

from PyQt6.QtCore import Qt
from PyQt6.QtWidgets import QHBoxLayout, QInputDialog, QLabel, QMenu, QWidget

from network.message_id import generate_message_id


class ChatReactionMixin:
    def show_message_context_menu(
        self,
        position
    ):

        item = self.chat_log.itemAt(
            position
        )

        if not item:
            return

        item_type = item.data(
            Qt.ItemDataRole.UserRole + 2
        )

        text = item.data(
            Qt.ItemDataRole.UserRole + 3
        ) or ""

        menu = QMenu(
            self
        )

        reply_action = menu.addAction(
            "Ответить"
        )

        forward_action = menu.addAction(
            "Переслать"
        )

        mine = item.data(
            Qt.ItemDataRole.UserRole + 4
        )

        message_id = item.data(
            Qt.ItemDataRole.UserRole + 5
        )

        pinned_ids = {
            pin[0]
            for pin in self.db.get_pins(
                self.pin_scope()
            )
        }

        pin_action = None

        if item_type == "message" and message_id:

            pin_action = menu.addAction(
                (
                    "Открепить"
                    if message_id in pinned_ids
                    else "Закрепить"
                )
            )

        if item_type == "message" and mine and message_id:

            edit_action = menu.addAction(
                "Изменить"
            )

            delete_action = menu.addAction(
                "Удалить"
            )

        else:

            edit_action = None
            delete_action = None

        if item_type == "file":

            open_action = menu.addAction(
                "Открыть"
            )

            save_action = menu.addAction(
                "Сохранить как..."
            )

        else:

            open_action = None
            save_action = None

        menu.addSeparator()

        reaction_actions = {}

        for reaction in (
            "❤️",
            "👌",
            "🫎",
            "👍"
        ):

            reaction_actions[
                menu.addAction(
                    reaction
                )
            ] = reaction

        action = menu.exec(
            self.chat_log.mapToGlobal(
                position
            )
        )

        if action == reply_action:

            self.set_reply_to(
                text
            )

        elif action == forward_action:

            self.forward_message_item(
                item_type,
                text
            )

        elif pin_action and action == pin_action:

            self.toggle_pin_message(
                message_id,
                text,
                message_id in pinned_ids
            )

        elif edit_action and action == edit_action:

            self.edit_message_item(
                item
            )

        elif delete_action and action == delete_action:

            self.delete_message_item(
                item
            )

        elif open_action and action == open_action:

            self.open_file(
                text
            )

        elif save_action and action == save_action:

            self.save_file_from_item(
                item
            )

        elif action in reaction_actions:

            self.add_reaction_to_item(
                item,
                reaction_actions[
                    action
                ],
                reactor_node=self.my_node_id
            )

    def forward_message_item(
        self,
        item_type,
        text
    ):

        if not self.forward_callback:
            return

        if item_type == "file":

            data = self.get_file_data(
                text
            )

            if not data:
                return

            self.forward_callback(
                "file",
                data,
                text,
                self
            )

            return

        self.forward_callback(
            "message",
            text,
            "",
            self
        )

    def toggle_pin_message(
        self,
        message_id,
        text,
        is_pinned
    ):

        scope = self.pin_scope()

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
                self.my_node_id
            )

        self.refresh_pinned_message()

        wire_text = (
            self.encrypt_message_callback(
                self.peer_node_id,
                text
            )
            if self.encrypt_message_callback
            else text
        )

        packet = {
            "packet_id": generate_message_id(),
            "type": "message_pin",
            "source_node": self.my_node_id,
            "destination_node": self.peer_node_id,
            "ttl": 5,
            "message_id": message_id,
            "action": "unpin" if is_pinned else "pin",
            "text": wire_text
        }

        threading.Thread(
            target=self.send_peer_packet,
            args=(packet,),
            daemon=True
        ).start()

    def edit_message_item(
        self,
        item
    ):

        message_id = item.data(
            Qt.ItemDataRole.UserRole + 5
        )

        old_text = item.data(
            Qt.ItemDataRole.UserRole + 3
        ) or ""

        if not message_id:
            return

        new_text, ok = QInputDialog.getMultiLineText(
            self,
            "Изменить сообщение",
            "Текст:",
            old_text
        )

        if not ok:
            return

        new_text = new_text.strip()

        if not new_text or new_text == old_text:
            return

        self.apply_message_edit(
            message_id,
            new_text,
            send=True
        )

    def delete_message_item(
        self,
        item
    ):

        message_id = item.data(
            Qt.ItemDataRole.UserRole + 5
        )

        if not message_id:
            return

        self.apply_message_delete(
            message_id,
            send=True
        )

    def add_reaction_to_item(
        self,
        item,
        reaction,
        send=True,
        reactor_node=None,
        persist=True
    ):

        widget = self.chat_log.itemWidget(
            item
        )

        if not widget:
            return

        reactor_node = reactor_node or self.my_node_id

        reaction_users = item.data(
            Qt.ItemDataRole.UserRole + 8
        ) or {}

        users = set(
            reaction_users.get(
                reaction,
                []
            )
        )

        already_reacted = reactor_node in users

        if not already_reacted:

            users.add(
                reactor_node
            )

        reaction_users[
            reaction
        ] = list(
            users
        )

        item.setData(
            Qt.ItemDataRole.UserRole + 8,
            reaction_users
        )

        reaction_counts = item.data(
            Qt.ItemDataRole.UserRole + 7
        ) or {}

        reaction_counts[
            reaction
        ] = len(
            users
        )

        item.setData(
            Qt.ItemDataRole.UserRole + 6,
            reaction
        )

        item.setData(
            Qt.ItemDataRole.UserRole + 7,
            reaction_counts
        )

        message_id = item.data(
            Qt.ItemDataRole.UserRole + 5
        )

        if (
            persist
            and message_id
            and not already_reacted
        ):

            self.db.save_reaction(
                "chat",
                message_id,
                reactor_node,
                reaction
            )

        if send and message_id and not already_reacted:

            packet = {
                "packet_id":
                generate_message_id(),

                "type":
                "message_reaction",

                "source_node":
                self.my_node_id,

                "destination_node":
                self.peer_node_id,

                "ttl":
                5,

                "message_id":
                message_id,

                "reaction":
                reaction
            }

            threading.Thread(
                target=self.send_peer_packet,
                args=(packet,),
                daemon=True
            ).start()

        labels = widget.findChildren(
            QLabel,
            "reaction_label"
        )

        matching_label = None

        for existing_label in labels:

            if existing_label.property("reaction") == reaction:

                matching_label = existing_label
                break

        if matching_label:

            matching_label.setText(
                self.format_reaction_text(
                    reaction,
                    reaction_counts[
                        reaction
                    ]
                )
            )

            self.resize_item_to_widget(
                item,
                widget
            )

            return

        label = QLabel(
            self.format_reaction_text(
                reaction,
                reaction_counts[
                    reaction
                ]
            )
        )

        label.setObjectName(
            "reaction_label"
        )

        label.setProperty(
            "reaction",
            reaction
        )

        label.setStyleSheet(
            """
            color:white;
            background:#4a5362;
            border-radius:9px;
            padding:2px 7px;
            font-size:12px;
            """
        )

        label.setMinimumHeight(
            24
        )

        label.setMinimumWidth(
            34
        )

        label.setMaximumWidth(
            64
        )

        label.setAlignment(
            Qt.AlignmentFlag.AlignCenter
        )

        bubble = widget.findChild(
            QWidget,
            "message_bubble"
        )

        if not bubble:
            return

        mine = item.data(
            Qt.ItemDataRole.UserRole + 4
        )

        row = widget.findChild(
            QWidget,
            "reaction_row"
        )

        if not row:

            row = QWidget()
            row.setObjectName(
                "reaction_row"
            )
            row_layout = QHBoxLayout(
                row
            )
            row_layout.setContentsMargins(
                0, 0, 0, 0
            )
            row_layout.setSpacing(
                0
            )

        reaction_layout = row.layout()

        if reaction_layout.count() == 0 and mine:

            reaction_layout.addStretch()

        if mine:

            reaction_layout.addWidget(
                label
            )

        else:

            if reaction_layout.count() > 0:

                last_item = reaction_layout.itemAt(
                    reaction_layout.count() - 1
                )

                if last_item and last_item.spacerItem():

                    reaction_layout.insertWidget(
                        reaction_layout.count() - 1,
                        label
                    )

                else:

                    reaction_layout.addWidget(
                        label
                    )

                    reaction_layout.addStretch()

            else:

                reaction_layout.addWidget(
                    label
                )

                reaction_layout.addStretch()

        row.show()

        stack = bubble.parentWidget()

        if not (
            stack
            and stack.objectName() == "message_stack"
        ):

            bubble.layout().addWidget(
                row
            )

        self.resize_item_to_widget(
            item,
            widget
        )

    def format_reaction_text(
        self,
        reaction,
        count
    ):

        if count > 1:

            return f"{reaction} {count}"

        return reaction

    def apply_reaction(
        self,
        message_id,
        reaction,
        reactor_node=None
    ):

        item = self.message_items.get(
            message_id
        )

        if not item:
            return

        self.add_reaction_to_item(
            item,
            reaction,
            False,
            reactor_node
        )

    def load_reactions_for_item(
        self,
        item,
        message_id
    ):

        if not message_id:
            return

        for reactor_node, reaction in self.db.get_reactions(
            "chat",
            message_id
        ):

            self.add_reaction_to_item(
                item,
                reaction,
                False,
                reactor_node,
                False
            )
