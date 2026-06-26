import json
import threading

from network.bluetooth_transport import send_bluetooth_packet
from network.client import send_packet
from network.protocol import chat_message_packet


class MainPendingMixin:
    def retry_pending_messages(self):

        if self.pending_retry_in_progress:
            return

        self.pending_retry_in_progress = True

        threading.Thread(
            target=self.run_pending_retry,
            daemon=True
        ).start()

    def run_pending_retry(self):

        try:

            pending_messages = self.db.get_pending_messages(
                self.node_id
            )

            for (
                message_id,
                receiver_node,
                message,
                attempts,
                packet_json
            ) in pending_messages:

                if packet_json:

                    try:

                        packet = json.loads(
                            packet_json
                        )

                    except json.JSONDecodeError:

                        self.db.remove_pending_message(
                            message_id
                        )

                        continue

                else:

                    packet = chat_message_packet(
                        self.node_id,
                        receiver_node,
                        self.username,
                        self.encrypt_direct_message(
                            receiver_node,
                            message
                        ),
                        message_id
                    )

                if (
                    packet.get("type") == "chat_message"
                    and packet.get("message") == message
                ):

                    packet["message"] = self.encrypt_direct_message(
                        receiver_node,
                        message
                    )

                sent = self.send_pending_packet(
                    receiver_node,
                    packet
                )

                if sent:

                    self.db.remove_pending_message(
                        message_id
                    )

                    if packet.get("type") == "chat_message":

                        self.pending_message_sent.emit(
                            message_id
                        )

                else:

                    self.db.mark_pending_attempt(
                        message_id
                    )

        finally:

            self.pending_retry_in_progress = False

    def send_pending_packet(
        self,
        receiver_node,
        packet
    ):

        info = self.db.get_user_info(
            receiver_node
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

        peer = self.discovery.get_user_by_node_id(
            receiver_node
        )

        if not peer:
            return self.send_server_packet(
                packet
            )

        ip, port = peer

        sent = send_packet(
            ip,
            port,
            packet
        )

        if sent:
            return True

        return self.send_server_packet(
            packet
        )

    def mark_pending_message_sent(
        self,
        message_id
    ):

        for chat in self.chat_windows.values():

            chat.mark_message_sent(
                message_id
            )
