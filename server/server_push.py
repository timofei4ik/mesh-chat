import asyncio
import json
from pathlib import Path
from urllib.parse import urlencode

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

    def _offline_push_target_nodes(self, destination_node):
        destination_node = str(destination_node or "").strip()
        if not destination_node:
            return []

        candidates = [destination_node]
        destination_login = str(
            self.get_login_by_node(destination_node) or ""
        ).strip().lower()
        if destination_login:
            candidates.extend(self.get_account_node_ids(destination_login))

        targets = []
        seen = set()
        for node_id in candidates:
            normalized = str(node_id or "").strip()
            if (
                not normalized
                or normalized in seen
                or normalized in self.clients
            ):
                continue
            seen.add(normalized)
            targets.append(normalized)
        return targets

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

        for target_node in self._offline_push_target_nodes(destination_node):
            if self.web_push_enabled:
                for endpoint, subscription in (
                    self.web_push_subscriptions_for_node(target_node)
                ):
                    try:
                        webpush(
                            subscription_info=subscription,
                            data=json.dumps(
                                notification,
                                ensure_ascii=False,
                            ),
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
                            self.delete_web_push_subscription(
                                endpoint=endpoint
                            )
                        else:
                            print(f"Web Push failed: {error}")

            if self.android_push_enabled:
                await self._send_android_push(target_node, notification)

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
            if notification.get("cancel"):
                message = messaging.Message(
                    data={
                        "type": str(packet_type),
                        "tag": str(notification.get("tag") or ""),
                        "packet_id": str(
                            notification.get("packet_id") or ""
                        ),
                        "call_id": str(notification.get("call_id") or ""),
                        "source_node": str(
                            notification.get("source_node") or ""
                        ),
                        "group_id": str(
                            notification.get("group_id") or ""
                        ),
                    },
                    android=messaging.AndroidConfig(priority="high"),
                    token=token,
                )
                try:
                    await asyncio.to_thread(
                        messaging.send,
                        message,
                        app=app,
                    )
                except Exception as error:
                    if error.__class__.__name__ in {
                        "UnregisteredError",
                        "SenderIdMismatchError",
                    }:
                        self.delete_android_push_token(token=token)
                    else:
                        print(f"Android push failed: {error}")
                continue
            message = messaging.Message(
                notification=messaging.Notification(
                    title=notification.get("title") or "MeshChat",
                    body=notification.get("body") or "Новое сообщение",
                ),
                data={
                    "type": str(packet_type),
                    "url": str(notification.get("url") or "/"),
                    "tag": str(notification.get("tag") or ""),
                    "packet_id": str(notification.get("packet_id") or ""),
                    "call_id": str(notification.get("call_id") or ""),
                    "source_node": str(
                        notification.get("source_node") or ""
                    ),
                    "group_id": str(notification.get("group_id") or ""),
                },
                android=messaging.AndroidConfig(
                    priority="high",
                    collapse_key=str(notification.get("tag") or ""),
                    notification=messaging.AndroidNotification(
                        channel_id=channel_id,
                        sound="default",
                        visibility="public",
                        tag=(
                            f"meshchat_call_{notification.get('call_id')}"
                            if packet_type == "call_offer"
                            else str(notification.get("tag") or "")
                        ),
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
        source_node = str(packet.get("source_node") or "")
        group_id = str(packet.get("group_id") or "")
        call_id = str(packet.get("call_id") or "")

        def target_url(kind):
            return "/?" + urlencode(
                {
                    "notification_type": kind,
                    "source_node": source_node,
                    "group_id": group_id,
                    "call_id": call_id,
                }
            )

        if packet_type == "chat_message":
            return {
                "title": sender,
                "body": "Новое сообщение",
                "url": target_url(packet_type),
                "packet_type": packet_type,
                "packet_id": packet.get("packet_id") or "",
                "tag": f"chat:{packet.get('source_node') or sender}",
                "source_node": source_node,
                "group_id": group_id,
            }

        if packet_type == "group_message":
            group_name = packet.get("group_name") or "Группа"
            return {
                "title": group_name,
                "body": f"{sender}: новое сообщение",
                "url": target_url(packet_type),
                "packet_type": packet_type,
                "packet_id": packet.get("packet_id") or "",
                "tag": f"group:{packet.get('group_id') or group_name}",
                "source_node": source_node,
                "group_id": group_id,
            }

        if packet_type == "file_chunk" and packet.get("chunk_index") == 0:
            return {
                "title": sender,
                "body": "Новый файл",
                "url": target_url(packet_type),
                "packet_type": packet_type,
                "packet_id": packet.get("packet_id") or "",
                "tag": f"file:{packet.get('file_id') or sender}",
                "source_node": source_node,
                "group_id": group_id,
            }

        if packet_type == "call_offer":
            return {
                "title": sender,
                "body": "Входящий звонок",
                "url": target_url(packet_type),
                "packet_type": packet_type,
                "packet_id": packet.get("packet_id") or "",
                "call_id": packet.get("call_id") or "",
                "tag": f"call:{packet.get('call_id') or sender}",
                "source_node": source_node,
                "group_id": group_id,
            }

        if packet_type == "call_end":
            return {
                "title": "",
                "body": "",
                "url": target_url(packet_type),
                "packet_type": packet_type,
                "packet_id": packet.get("packet_id") or "",
                "call_id": call_id,
                "tag": f"call:{call_id or sender}",
                "source_node": source_node,
                "group_id": group_id,
                "cancel": True,
            }

        return None
