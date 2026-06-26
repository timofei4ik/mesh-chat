import json

try:
    from pywebpush import WebPushException, webpush
except ModuleNotFoundError:
    WebPushException = None
    webpush = None

try:
    from server.config import (
        WEB_PUSH_VAPID_PRIVATE_KEY,
        WEB_PUSH_VAPID_PUBLIC_KEY,
        WEB_PUSH_VAPID_SUBJECT
    )
except ModuleNotFoundError:
    from config import (
        WEB_PUSH_VAPID_PRIVATE_KEY,
        WEB_PUSH_VAPID_PUBLIC_KEY,
        WEB_PUSH_VAPID_SUBJECT
    )


class ServerPushMixin:
    @property
    def web_push_enabled(self):
        return bool(
            webpush
            and WEB_PUSH_VAPID_PRIVATE_KEY
            and WEB_PUSH_VAPID_PUBLIC_KEY
        )

    def web_push_public_key(self):
        return WEB_PUSH_VAPID_PUBLIC_KEY if self.web_push_enabled else ""

    async def send_web_push_for_packet(
        self,
        destination_node,
        packet
    ):
        if not self.web_push_enabled or not destination_node:
            return

        notification = self._web_push_payload(packet)

        if not notification:
            return

        for endpoint, subscription in self.web_push_subscriptions_for_node(
            destination_node
        ):
            try:
                webpush(
                    subscription_info=subscription,
                    data=json.dumps(notification, ensure_ascii=False),
                    vapid_private_key=WEB_PUSH_VAPID_PRIVATE_KEY,
                    vapid_claims={
                        "sub": WEB_PUSH_VAPID_SUBJECT
                    },
                    timeout=5
                )
            except Exception as error:
                status_code = getattr(
                    getattr(error, "response", None),
                    "status_code",
                    None
                )
                if status_code in (404, 410):
                    self.delete_web_push_subscription(endpoint=endpoint)
                else:
                    print(f"Web Push failed: {error}")

    def _web_push_payload(
        self,
        packet
    ):
        packet_type = packet.get("type")
        sender = (
            packet.get("sender")
            or packet.get("sender_name")
            or "MeshChat"
        )

        if packet_type == "chat_message":
            return {
                "title": sender,
                "body": "Новое сообщение",
                "url": "/"
            }

        if packet_type == "group_message":
            group_name = packet.get("group_name") or "Группа"
            return {
                "title": group_name,
                "body": f"{sender}: новое сообщение",
                "url": "/"
            }

        if packet_type == "file_chunk" and packet.get("chunk_index") == 0:
            return {
                "title": sender,
                "body": "Новый файл",
                "url": "/"
            }

        if packet_type == "call_offer":
            return {
                "title": sender,
                "body": "Входящий звонок",
                "url": "/"
            }

        return None
