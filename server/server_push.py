import asyncio
import json
from pathlib import Path

try:
    from pywebpush import WebPushException, webpush
except ModuleNotFoundError:
    WebPushException = None
    webpush = None

try:
    import firebase_admin
    from firebase_admin import credentials, messaging
except ModuleNotFoundError:
    firebase_admin = None
    credentials = None
    messaging = None

try:
    from server.config import (
        WEB_PUSH_VAPID_PRIVATE_KEY,
        WEB_PUSH_VAPID_PUBLIC_KEY,
        WEB_PUSH_VAPID_SUBJECT,
        FIREBASE_CREDENTIALS,
        FIREBASE_PROJECT_ID,
    )
except ModuleNotFoundError:
    from config import (
        WEB_PUSH_VAPID_PRIVATE_KEY,
        WEB_PUSH_VAPID_PUBLIC_KEY,
        WEB_PUSH_VAPID_SUBJECT,
        FIREBASE_CREDENTIALS,
        FIREBASE_PROJECT_ID,
    )


class ServerPushMixin:
    _firebase_app_instance = None

    @property
    def web_push_enabled(self):
        return bool(
            webpush
            and WEB_PUSH_VAPID_PRIVATE_KEY
            and WEB_PUSH_VAPID_PUBLIC_KEY
        )

    def web_push_public_key(self):
        return WEB_PUSH_VAPID_PUBLIC_KEY if self.web_push_enabled else ""

    @property
    def android_push_enabled(self):
        return bool(
            firebase_admin
            and messaging
            and FIREBASE_CREDENTIALS
            and Path(FIREBASE_CREDENTIALS).is_file()
        )

    def _firebase_app(self):
        if not self.android_push_enabled:
            return None
        if self._firebase_app_instance is not None:
            return self._firebase_app_instance
        options = (
            {"projectId": FIREBASE_PROJECT_ID}
            if FIREBASE_PROJECT_ID
            else None
        )
        self._firebase_app_instance = firebase_admin.initialize_app(
            credentials.Certificate(FIREBASE_CREDENTIALS),
            options=options,
            name="meshchat-push",
        )
        return self._firebase_app_instance

    async def send_web_push_for_packet(
        self,
        destination_node,
        packet
    ):
        if not destination_node:
            return

        notification = self._web_push_payload(packet)

        if not notification:
            return

        if self.web_push_enabled:
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

        if self.android_push_enabled and destination_node not in self.clients:
            await self._send_android_push(destination_node, notification)

    async def _send_android_push(self, destination_node, notification):
        app = self._firebase_app()
        if app is None:
            return
        packet_type = notification.get("packet_type") or "message"
        channel_id = (
            "meshchat_calls"
            if packet_type == "call_offer"
            else "meshchat_messages"
        )
        for token in self.android_push_tokens_for_node(destination_node):
            message = messaging.Message(
                notification=messaging.Notification(
                    title=notification.get("title") or "MeshChat",
                    body=notification.get("body") or "Новое сообщение",
                ),
                data={
                    "type": str(packet_type),
                    "url": str(notification.get("url") or "/"),
                },
                android=messaging.AndroidConfig(
                    priority="high",
                    notification=messaging.AndroidNotification(
                        channel_id=channel_id,
                        sound="default",
                        visibility="public",
                    ),
                ),
                token=token,
            )
            try:
                await asyncio.to_thread(messaging.send, message, app=app)
            except Exception as error:
                if error.__class__.__name__ in {
                    "UnregisteredError",
                    "SenderIdMismatchError",
                }:
                    self.delete_android_push_token(token=token)
                else:
                    print(f"Android push failed: {error}")

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
                "url": "/",
                "packet_type": packet_type,
            }

        if packet_type == "group_message":
            group_name = packet.get("group_name") or "Группа"
            return {
                "title": group_name,
                "body": f"{sender}: новое сообщение",
                "url": "/",
                "packet_type": packet_type,
            }

        if packet_type == "file_chunk" and packet.get("chunk_index") == 0:
            return {
                "title": sender,
                "body": "Новый файл",
                "url": "/",
                "packet_type": packet_type,
            }

        if packet_type == "call_offer":
            return {
                "title": sender,
                "body": "Входящий звонок",
                "url": "/",
                "packet_type": packet_type,
            }

        return None
