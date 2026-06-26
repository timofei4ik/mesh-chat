from network.bluetooth_transport import send_bluetooth_packet
from network.client import send_packet
from network.message_id import generate_message_id
from network.protocol import message_received_packet
from network.router import forward_packet


class MainPacketMixin:
    def handle_packet(self, packet):

        if not isinstance(packet, dict):
            return

        source_node = packet.get(
            "source_node"
        )

        if source_node == self.node_id:
            return

        if source_node and self.db.is_contact_blocked(
            source_node
        ):
            return

        packet_id = packet.get("packet_id")

        if packet_id:
            if self.packet_cache.exists(packet_id):
                return
            self.packet_cache.add(packet_id)

        packet_type = packet.get("type")

        if packet_type == "server_sync":

            self.apply_server_sync(
                packet
            )

            return

        if packet_type == "server_file_sync_chunk":

            self.apply_server_file_sync_chunk(
                packet
            )

            return

        if packet_type == "username_lookup_result":

            self.handle_username_lookup_result(
                packet
            )

            return

        if packet_type == "profile_update_result":

            self.handle_profile_update_result(
                packet
            )

            return

        destination_node = packet.get(
            "destination_node"
        )

        if destination_node:

            if destination_node != self.node_id:


                forward_packet(
                    self.discovery,
                    self.node_id,
                    packet
                )

                return

        if packet_type == "chat_request":

            self.incoming_request.emit(packet)

        elif packet_type == "bluetooth_hello":

            self.handle_bluetooth_hello(
                packet
            )

        elif packet_type == "bluetooth_hello_response":

            self.handle_bluetooth_hello_response(
                packet
            )

        elif packet_type == "chat_response":

            self.incoming_response.emit(packet)

        elif packet_type == "chat_message":

            sender_node_id = packet.get("source_node")
            sender = packet.get("sender")
            message = packet.get("message")
            sender_ip = packet.get("sender_ip")
            sender_port = packet.get("sender_port")

            message = self.decrypt_direct_message(
                message
            )

            ack_packet = message_received_packet(
                self.node_id,
                sender_node_id,
                packet.get("packet_id")
            )

            self.send_packet_to_contact(
                sender_node_id,
                ack_packet
            )


            if not sender_node_id or not message:
                return

            if sender and sender_ip:

                self.db.update_user(
                    sender_node_id,
                    sender,
                    sender_ip or "",
                    sender_port or 0
                )

            if self.should_notify_for_chat(
                sender_node_id
            ):

                self.notify(
                    f"Новое сообщение от {sender}",
                    message
                )

            if sender_node_id in self.chat_windows:


                self.chat_windows[sender_node_id].receive_message(
                    sender,
                    sender_node_id,
                    message,
                    packet.get("packet_id")
                )

            else:

                self.db.save_message(
                    sender_node_id,
                    self.node_id,
                    message,
                    packet.get("packet_id")
                )

                self.db.add_unread(
                    sender_node_id,
                    self.node_id
                )

        elif packet_type == "group_message":

            self.handle_group_message(
                packet
            )

        elif packet_type == "group_update":

            self.handle_group_update(
                packet
            )

        elif packet_type == "group_delete":

            self.handle_group_delete(
                packet
            )

        elif packet_type == "group_reaction":

            self.handle_group_reaction(
                packet
            )

        elif packet_type == "group_message_edit":

            self.handle_group_message_edit(
                packet
            )

        elif packet_type == "group_message_delete":

            self.handle_group_message_delete(
                packet
            )

        elif packet_type == "group_pin":

            self.handle_group_pin(
                packet
            )

        elif packet_type == "message_pin":

            sender_node_id = packet.get(
                "source_node"
            )
            message_id = packet.get(
                "message_id"
            )

            if not sender_node_id or not message_id:
                return

            scope = "chat:" + ":".join(
                sorted(
                    (
                        self.node_id,
                        sender_node_id
                    )
                )
            )

            if packet.get("action") == "unpin":
                self.db.remove_pin(
                    scope,
                    message_id
                )
            else:
                self.db.save_pin(
                    scope,
                    message_id,
                    self.decrypt_direct_message(
                        packet.get("text") or ""
                    ),
                    sender_node_id
                )

            chat = self.chat_windows.get(
                sender_node_id
            )

            if chat:
                chat.refresh_pinned_message()

        elif packet_type == "file_chunk":

            sender = packet.get(
                "sender"
            )

            sender_node_id = packet.get(
                "source_node"
            )

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

            group_id = packet.get(
                "group_id"
            )

            if (
                not file_id
                or chunk_index is None
                or not total_chunks
            ):

                return

            if file_id not in self.file_chunks:

                self.file_chunks[
                    file_id
                ] = {

                    "sender": sender,

                    "sender_node_id": sender_node_id,

                    "filename": filename,

                    "group_id": group_id,

                    "group_key_id": packet.get(
                        "group_key_id"
                    ),

                    "total_chunks": total_chunks,

                    "chunks": {}
                }

                if group_id:

                    self.accept_group_key_envelope(
                        group_id,
                        packet.get("group_key_id"),
                        packet.get("group_key_envelope"),
                        True
                    )

                    filename = self.decrypt_group_text(
                        group_id,
                        packet.get("group_key_id"),
                        filename
                    )

                    self.file_chunks[
                        file_id
                    ][
                        "filename"
                    ] = filename

            self.file_chunks[
                file_id
            ][
                "chunks"
            ][
                chunk_index
            ] = data

            file_info = self.file_chunks[
                file_id
            ]

            filename = file_info.get(
                "filename"
            ) or filename

            if sender_node_id in self.chat_windows:

                percent = int(
                    len(
                        file_info["chunks"]
                    )
                    * 100
                    / file_info["total_chunks"]
                )

                self.chat_windows[
                    sender_node_id
                ].update_incoming_file_progress(
                    file_id,
                    filename,
                    percent
                )

            if (
                group_id
                and group_id in self.group_windows
            ):

                percent = int(
                    len(
                        file_info["chunks"]
                    )
                    * 100
                    / file_info["total_chunks"]
                )

                self.group_windows[
                    group_id
                ].update_incoming_file_progress(
                    file_id,
                    filename,
                    percent,
                    sender
                )

            if len(
                file_info["chunks"]
            ) == file_info["total_chunks"]:

                ack_packet = {

                    "packet_id":
                    generate_message_id(),

                    "type":
                    "file_complete",

                    "source_node":
                    self.node_id,

                    "destination_node":
                    sender_node_id,

                    "ttl":
                    5,

                    "file_id":
                        file_id
                }

                self.send_packet_to_contact(
                    sender_node_id,
                    ack_packet
                )

                full_data = "".join(

                    file_info[
                        "chunks"
                    ][i]

                    for i in range(
                        file_info[
                            "total_chunks"
                        ]
                    )
                )

                if not group_id:

                    filename, full_data = self.decrypt_direct_file(
                        filename,
                        full_data
                    )

                else:

                    filename, full_data = self.decrypt_group_file(
                        group_id,
                        file_info.get("group_key_id"),
                        filename,
                        full_data
                    )

                receiver_node = (
                    f"group:{group_id}"
                    if group_id
                    else self.node_id
                )

                self.db.save_file(
                    sender_node_id,
                    receiver_node,
                    filename,
                    full_data,
                    file_id
                )

                if self.should_notify_for_chat(
                    group_id if group_id else sender_node_id,
                    bool(group_id)
                ):

                    self.notify(
                        f"Файл от {sender}",
                        filename
                    )

                if (
                    group_id
                    and group_id in self.group_windows
                ):

                    self.group_windows[
                        group_id
                    ].receive_file(
                        sender,
                        filename,
                        full_data,
                        file_id
                    )

                elif sender_node_id in self.chat_windows:

                    self.file_received_signal.emit(
                        sender,
                        sender_node_id,
                        filename,
                        full_data,
                        file_id
                    )

                del self.file_chunks[
                    file_id
                ]

        elif packet_type == "file_complete":

            file_id = packet.get(
                "file_id"
            )

            if file_id in self.pending_sent_files:

                filename = self.pending_sent_files[
                    file_id
                ]

                for chat in self.chat_windows.values():

                    chat.update_file_status(
                        file_id,
                        "доставлено"
                    )

                for chat in self.group_windows.values():

                    chat.update_file_status(
                        file_id,
                        "доставлено"
                    )

                del self.pending_sent_files[
                    file_id
                ]

        elif packet_type == "typing":

            sender = packet.get(
                "sender"
            )

            sender_node_id = packet.get(
                "source_node"
            )

            self.typing_signal.emit(
                sender,
                sender_node_id
            )

        elif packet_type == "group_typing":

            group_id = packet.get(
                "group_id"
            )

            sender = packet.get(
                "sender"
            ) or packet.get(
                "source_node",
                ""
            )[:8]

            sender_node = packet.get(
                "source_node"
            )

            if (
                group_id in self.group_windows
                and sender_node != self.node_id
            ):

                self.group_windows[
                    group_id
                ].show_group_typing(
                    sender
                )

        elif packet_type == "message_received":

            message_id = packet.get(
                "message_id"
            )

            if message_id:

                self.db.remove_pending_message(
                    message_id
                )

            for chat in self.chat_windows.values():

                chat.mark_message_delivered(
                    message_id
                )

        elif packet_type == "message_edit":

            sender_node_id = packet.get(
                "source_node"
            )

            message_id = packet.get(
                "message_id"
            )

            message = packet.get(
                "message"
            )

            message = self.decrypt_direct_message(
                message
            )

            if message_id and message:

                self.db.update_message(
                    message_id,
                    message
                )

                if sender_node_id in self.chat_windows:

                    self.chat_windows[
                        sender_node_id
                    ].apply_message_edit(
                        message_id,
                        message,
                        send=False
                    )

        elif packet_type == "message_delete":

            sender_node_id = packet.get(
                "source_node"
            )

            message_id = packet.get(
                "message_id"
            )

            if message_id:

                self.db.delete_message(
                    message_id
                )

                if sender_node_id in self.chat_windows:

                    self.chat_windows[
                        sender_node_id
                    ].apply_message_delete(
                        message_id,
                        send=False
                    )

        elif packet_type == "message_reaction":

            sender_node_id = packet.get(
                "source_node"
            )

            message_id = packet.get(
                "message_id"
            )

            reaction = packet.get(
                "reaction"
            )

            if (
                message_id
                and reaction
            ):

                self.db.save_reaction(
                    "chat",
                    message_id,
                    sender_node_id,
                    reaction
                )

                if sender_node_id in self.chat_windows:

                    self.chat_windows[
                        sender_node_id
                    ].apply_reaction(
                        message_id,
                        reaction,
                        sender_node_id
                    )

    def route_packet(
        self,
        packet
    ):

        ttl = packet.get(
            "ttl",
            0
        )

        if ttl <= 0:
            return False

        packet["ttl"] = ttl - 1

        return True

    def send_packet_to_contact(
        self,
        peer_node_id,
        packet
    ):

        info = self.db.get_user_info(
            peer_node_id
        )

        if info:

            _, ip, port = info

            if (
                isinstance(
                    ip,
                    str
                )
                and ip.startswith("BT:")
            ):

                sent = send_bluetooth_packet(
                    ip[3:],
                    port,
                    packet
                )

                if sent:
                    return True

                return self.send_server_packet(
                    packet
                )

            if ip == "SERVER":

                return self.send_server_packet(
                    packet
                )

        forward_packet(
            self.discovery,
            self.node_id,
            packet
        )

        return self.send_server_packet(
            packet
        ) or True

    def register_pending_file(
        self,
        file_id,
        filename
    ):

        self.pending_sent_files[
            file_id
        ] = filename
