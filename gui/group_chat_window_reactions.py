from PyQt6.QtCore import Qt
from PyQt6.QtWidgets import QHBoxLayout, QInputDialog, QLabel, QMenu, QWidget


class GroupReactionMixin:
    def show_message_context_menu(
        self,
        position
    ):

        item = self.messages.itemAt(
            position
        )

        if not item:
            return

        text = item.data(
            Qt.ItemDataRole.UserRole + 3
        ) or ""

        item_type = item.data(
            Qt.ItemDataRole.UserRole + 2
        )

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

        can_pin = self.db.can_manage_group(
            self.group_id,
            self.main_window.node_id
        )

        pinned_ids = {
            pin[0]
            for pin in self.db.get_pins(
                self.pin_scope()
            )
        }

        pin_action = None

        if can_pin and item_type == "message" and message_id:

            pin_action = menu.addAction(
                (
                    "Открепить"
                    if message_id in pinned_ids
                    else "Закрепить"
                )
            )

        if mine and message_id:

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
            self.messages.mapToGlobal(
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

            self.main_window.send_group_pin(
                self.group_id,
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
                reactor_node=self.main_window.node_id
            )

    def forward_message_item(
        self,
        item_type,
        text
    ):

        if item_type == "file":

            data = self.get_file_data(
                text
            )

            if not data:
                return

            self.main_window.forward_content(
                "file",
                data,
                text,
                self
            )

            return

        self.main_window.forward_content(
            "message",
            text,
            "",
            self
        )

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

        widget = self.messages.itemWidget(
            item
        )

        if not widget:
            return

        reactor_node = reactor_node or self.main_window.node_id

        users_by_reaction = item.data(
            Qt.ItemDataRole.UserRole + 8
        ) or {}

        users = set(
            users_by_reaction.get(
                reaction,
                []
            )
        )

        already_reacted = reactor_node in users

        if not already_reacted:

            users.add(
                reactor_node
            )

        users_by_reaction[
            reaction
        ] = list(
            users
        )

        item.setData(
            Qt.ItemDataRole.UserRole + 8,
            users_by_reaction
        )

        counts = item.data(
            Qt.ItemDataRole.UserRole + 7
        ) or {}

        counts[
            reaction
        ] = len(
            users
        )

        item.setData(
            Qt.ItemDataRole.UserRole + 7,
            counts
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
                f"group:{self.group_id}",
                message_id,
                reactor_node,
                reaction
            )

        if send and message_id and not already_reacted:

            self.main_window.send_group_reaction(
                self.group_id,
                message_id,
                reaction
            )

        labels = widget.findChildren(
            QLabel,
            "reaction_label"
        )

        text = self.format_reaction_text(
            reaction,
            counts[
                reaction
            ]
        )

        matching_label = None

        for existing_label in labels:

            if existing_label.property("reaction") == reaction:

                matching_label = existing_label
                break

        if matching_label:

            matching_label.setText(
                text
            )

            self.resize_item_to_widget(
                item,
                widget
            )

            return

        label = QLabel(
            text
        )

        label.setObjectName(
            "reaction_label"
        )

        label.setProperty(
            "reaction",
            reaction
        )

        label.setMinimumWidth(
            34
        )

        label.setMaximumWidth(
            64
        )

        label.setMinimumHeight(
            24
        )

        label.setAlignment(
            Qt.AlignmentFlag.AlignCenter
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

        row_layout = row.layout()

        if row_layout.count() == 0 and mine:

            row_layout.addStretch()

        if mine:

            row_layout.addWidget(
                label
            )

        else:

            if row_layout.count() > 0:

                last_item = row_layout.itemAt(
                    row_layout.count() - 1
                )

                if last_item and last_item.spacerItem():

                    row_layout.insertWidget(
                        row_layout.count() - 1,
                        label
                    )

                else:

                    row_layout.addWidget(
                        label
                    )

                    row_layout.addStretch()

            else:

                row_layout.addWidget(
                    label
                )

                row_layout.addStretch()

        row.show()

        stack = bubble.parentWidget()

        if stack and stack.objectName() == "message_stack":

            pass

        else:

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
            f"group:{self.group_id}",
            message_id
        ):

            self.add_reaction_to_item(
                item,
                reaction,
                False,
                reactor_node,
                False
            )
