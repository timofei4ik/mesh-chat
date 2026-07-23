import asyncio
import hashlib
import hmac
import re
import secrets

try:
    import aiohttp
except ModuleNotFoundError:  # Installed from server/requirements.txt in production.
    aiohttp = None

try:
    from server.config import (
        BOOSTY_ACTIVATION_CODE_TTL_SECONDS,
        BOOSTY_ACTIVATION_SECRET,
        BOOSTY_ACTIVATION_URL,
        BOOSTY_KEY_DURATION_DAYS,
        BOOSTY_KEY_ISSUE_INTERVAL_DAYS,
        BOOSTY_RECONCILE_INTERVAL_SECONDS,
        BOOSTY_TELEGRAM_API_URL,
        BOOSTY_TELEGRAM_BOT_TOKEN,
        BOOSTY_TELEGRAM_GROUP_ID,
        BOOSTY_TELEGRAM_OWNER_ID,
    )
except ModuleNotFoundError:
    from config import (
        BOOSTY_ACTIVATION_CODE_TTL_SECONDS,
        BOOSTY_ACTIVATION_SECRET,
        BOOSTY_ACTIVATION_URL,
        BOOSTY_KEY_DURATION_DAYS,
        BOOSTY_KEY_ISSUE_INTERVAL_DAYS,
        BOOSTY_RECONCILE_INTERVAL_SECONDS,
        BOOSTY_TELEGRAM_API_URL,
        BOOSTY_TELEGRAM_BOT_TOKEN,
        BOOSTY_TELEGRAM_GROUP_ID,
        BOOSTY_TELEGRAM_OWNER_ID,
    )


BOOSTY_CODE_ALPHABET = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"
BOOSTY_CODE_GROUPS = 5
BOOSTY_CODE_GROUP_SIZE = 4
BOOSTY_MEMBER_STATUSES = frozenset({"creator", "administrator", "member"})
BOOSTY_GIFT_OPTIONS = (
    ("14 дней", "14d", 14),
    ("1 мес.", "1", 30),
    ("3 мес.", "3", 90),
    ("6 мес.", "6", 180),
    ("12 мес.", "12", 360),
)
BOOSTY_GIFT_DURATIONS = {
    code: duration_days
    for _, code, duration_days in BOOSTY_GIFT_OPTIONS
}
BOOSTY_KEY_NEVER_EXPIRES_AT = "9999-12-31 23:59:59"


class BoostyActivationError(RuntimeError):
    pass


class BoostyTelegramError(RuntimeError):
    pass


class ServerBoostyMixin:
    @property
    def boosty_bot_configured(self):
        return bool(
            aiohttp is not None
            and BOOSTY_TELEGRAM_BOT_TOKEN
            and BOOSTY_ACTIVATION_SECRET
            and BOOSTY_ACTIVATION_URL
        )

    @property
    def boosty_activation_configured(self):
        return bool(
            self.boosty_bot_configured
            and BOOSTY_TELEGRAM_GROUP_ID
        )

    async def start_boosty_bridge(self):
        self._boosty_tasks = []
        self._boosty_session = None
        self._boosty_stop_event = asyncio.Event()
        self._boosty_bot_username = ""
        if not self.boosty_bot_configured:
            return False

        self._boosty_session = aiohttp.ClientSession(
            timeout=aiohttp.ClientTimeout(total=40)
        )
        try:
            identity = await self._boosty_telegram_request("getMe")
            self._boosty_bot_username = str(
                identity.get("username") or ""
            ).strip()
            await self._boosty_telegram_request(
                "deleteWebhook",
                {"drop_pending_updates": False},
            )
        except Exception as error:
            print(
                "Boosty Telegram bridge initialization failed:",
                self._boosty_safe_error(error),
            )
            await self.stop_boosty_bridge()
            return False

        self._boosty_tasks = [
            asyncio.create_task(
                self._boosty_poll_loop(),
                name="boosty-telegram-poll",
            ),
            asyncio.create_task(
                self._boosty_reconcile_loop(),
                name="boosty-membership-reconcile",
            ),
        ]
        return True

    async def stop_boosty_bridge(self):
        stop_event = getattr(self, "_boosty_stop_event", None)
        if stop_event is not None:
            stop_event.set()
        tasks = list(getattr(self, "_boosty_tasks", []))
        for task in tasks:
            task.cancel()
        if tasks:
            await asyncio.gather(*tasks, return_exceptions=True)
        self._boosty_tasks = []
        session = getattr(self, "_boosty_session", None)
        if session is not None and not session.closed:
            await session.close()
        self._boosty_session = None

    def boosty_public_info(self):
        return {
            "configured": self.boosty_activation_configured,
            "bot_username": str(
                getattr(self, "_boosty_bot_username", "") or ""
            ).lstrip("@"),
            "activation_url": BOOSTY_ACTIVATION_URL,
            "code_ttl_seconds": BOOSTY_ACTIVATION_CODE_TTL_SECONDS,
            "key_duration_days": BOOSTY_KEY_DURATION_DAYS,
            "key_issue_interval_days": BOOSTY_KEY_ISSUE_INTERVAL_DAYS,
            "transferable_keys": True,
        }

    async def _boosty_poll_loop(self):
        offset = None
        while not self._boosty_stop_event.is_set():
            try:
                payload = {
                    "timeout": 25,
                    "allowed_updates": ["message", "callback_query"],
                }
                if offset is not None:
                    payload["offset"] = offset
                updates = await self._boosty_telegram_request(
                    "getUpdates",
                    payload,
                )
                for update in updates:
                    update_id = int(update.get("update_id", 0))
                    offset = max(offset or 0, update_id + 1)
                    await self._boosty_handle_update(update)
            except asyncio.CancelledError:
                raise
            except Exception as error:
                print(
                    "Boosty Telegram polling failed:",
                    self._boosty_safe_error(error),
                )
                await self._boosty_wait_or_stop(5)

    async def _boosty_reconcile_loop(self):
        await self._boosty_wait_or_stop(10)
        while not self._boosty_stop_event.is_set():
            try:
                await self.reconcile_boosty_memberships()
            except asyncio.CancelledError:
                raise
            except Exception as error:
                print(
                    "Boosty membership reconcile failed:",
                    self._boosty_safe_error(error),
                )
            await self._boosty_wait_or_stop(
                BOOSTY_RECONCILE_INTERVAL_SECONDS
            )

    async def _boosty_wait_or_stop(self, seconds):
        try:
            await asyncio.wait_for(
                self._boosty_stop_event.wait(),
                timeout=max(0.1, float(seconds)),
            )
        except asyncio.TimeoutError:
            pass

    async def _boosty_handle_update(self, update):
        callback = update.get("callback_query") or {}
        if callback:
            await self._boosty_handle_callback(callback)
            return

        message = update.get("message") or {}
        text = str(message.get("text") or "").strip()
        if not text.startswith("/"):
            return
        command = text.split(maxsplit=1)[0].split("@", 1)[0].lower()
        chat = message.get("chat") or {}
        sender = message.get("from") or {}
        chat_id = chat.get("id")
        telegram_user_id = sender.get("id")
        if chat_id is None or telegram_user_id is None:
            return

        chat_type = str(chat.get("type") or "")
        if command == "/groupid" and chat_type in {"group", "supergroup"}:
            try:
                member = await self._boosty_get_chat_member(
                    str(chat_id),
                    int(telegram_user_id),
                )
                if str(member.get("status") or "") not in {
                    "creator",
                    "administrator",
                }:
                    return
                await self._boosty_send_message(
                    chat_id,
                    f"ID этой группы: {chat_id}",
                )
            except BoostyTelegramError:
                return
            return

        if chat_type != "private":
            return
        self._boosty_register_recipient(message)
        if command in {"/start", "/help"}:
            await self._boosty_send_message(
                chat_id,
                "Я выдаю передаваемые ключи MeshPro подписчикам Boosty.\n\n"
                "/code — получить ежемесячный ключ на 30 дней\n"
                "/status — проверить подписку и дату следующего ключа\n"
                "/gift — подарочный ключ на выбранный срок (владелец)",
            )
            return
        if command == "/code":
            await self._boosty_issue_code_message(message)
            return
        if command == "/status":
            await self._boosty_status_message(message)
            return
        if command == "/gift":
            await self._boosty_gift_command(message, text)

    def _boosty_register_recipient(self, message):
        sender = message.get("from") or {}
        chat = message.get("chat") or {}
        telegram_user_id = int(sender["id"])
        private_chat_id = int(chat["id"])
        username = str(sender.get("username") or "")[:64]
        with self.unit_of_work_factory(write=True) as unit_of_work:
            unit_of_work.subscriptions.upsert_boosty_recipient(
                telegram_user_id,
                private_chat_id,
                username,
            )

    async def _boosty_handle_callback(self, callback):
        callback_id = str(callback.get("id") or "")
        data = str(callback.get("data") or "")
        sender = callback.get("from") or {}
        message = callback.get("message") or {}
        chat = message.get("chat") or {}
        match = re.fullmatch(r"boosty_gift:([a-z0-9]+)", data)
        gift_code = match.group(1) if match else ""
        duration_days = BOOSTY_GIFT_DURATIONS.get(gift_code)
        if duration_days is None or chat.get("type") != "private":
            if callback_id:
                await self._boosty_answer_callback(callback_id)
            return
        telegram_user_id = int(sender.get("id") or 0)
        if not await self._boosty_user_is_owner(telegram_user_id):
            await self._boosty_answer_callback(
                callback_id,
                "Подарочные ключи доступны только владельцу группы.",
                show_alert=True,
            )
            return
        await self._boosty_answer_callback(callback_id, "Ключ создан")
        await self._boosty_send_gift_key(
            int(chat["id"]),
            telegram_user_id,
            str(sender.get("username") or ""),
            duration_days,
        )

    async def _boosty_gift_command(self, message, text):
        chat_id = int(message["chat"]["id"])
        sender = message["from"]
        telegram_user_id = int(sender["id"])
        if not await self._boosty_user_is_owner(telegram_user_id):
            await self._boosty_send_message(
                chat_id,
                "Подарочные ключи доступны только владельцу группы.",
            )
            return
        parts = text.split(maxsplit=1)
        if len(parts) == 2:
            gift_code = parts[1].strip().lower()
            if gift_code in {"14", "2w"}:
                gift_code = "14d"
            duration_days = BOOSTY_GIFT_DURATIONS.get(gift_code)
            if duration_days is not None:
                await self._boosty_send_gift_key(
                    chat_id,
                    telegram_user_id,
                    str(sender.get("username") or ""),
                    duration_days,
                )
                return
        buttons = [
            {
                "text": label,
                "callback_data": f"boosty_gift:{code}",
            }
            for label, code, _ in BOOSTY_GIFT_OPTIONS
        ]
        keyboard = {
            "inline_keyboard": [
                buttons[:2],
                buttons[2:4],
                buttons[4:],
            ]
        }
        await self._boosty_send_message(
            chat_id,
            "Выберите срок подарочного ключа:",
            reply_markup=keyboard,
        )

    async def _boosty_send_gift_key(
        self,
        chat_id,
        telegram_user_id,
        telegram_username,
        duration_days,
    ):
        duration_days = int(duration_days)
        code = self.create_boosty_activation_code(
            telegram_user_id,
            telegram_username,
            duration_days=duration_days,
            issue_kind="gift",
        )
        await self._boosty_send_message(
            chat_id,
            self._boosty_key_message(code, duration_days, gift=True),
        )

    async def _boosty_issue_code_message(self, message):
        chat_id = int(message["chat"]["id"])
        sender = message["from"]
        telegram_user_id = int(sender["id"])
        self._boosty_register_recipient(message)
        if not BOOSTY_TELEGRAM_GROUP_ID:
            await self._boosty_send_message(
                chat_id,
                "Группа подписчиков ещё не настроена.",
            )
            return
        try:
            active = await self._boosty_user_is_member(telegram_user_id)
        except BoostyTelegramError:
            await self._boosty_send_message(
                chat_id,
                "Не удалось проверить подписку. Попробуйте чуть позже.",
            )
            return
        if not active:
            await self._boosty_send_message(
                chat_id,
                "Активная подписка Boosty не найдена. "
                "Сначала вступите в закрытую группу через Boosty.",
            )
            return

        username = str(sender.get("username") or "").strip()
        code, wait_seconds = self.issue_monthly_boosty_key(
            telegram_user_id,
            username,
        )
        if not code:
            await self._boosty_send_message(
                chat_id,
                "Ежемесячный ключ уже был выдан. Следующий будет доступен "
                f"через {self._boosty_format_wait(wait_seconds)}.",
            )
            return
        await self._boosty_send_message(
            chat_id,
            self._boosty_key_message(
                code,
                BOOSTY_KEY_DURATION_DAYS,
                gift=False,
            ),
        )

    async def _boosty_status_message(self, message):
        chat_id = int(message["chat"]["id"])
        telegram_user_id = int(message["from"]["id"])
        self._boosty_register_recipient(message)
        try:
            active = await self._boosty_user_is_member(telegram_user_id)
        except BoostyTelegramError:
            await self._boosty_send_message(
                chat_id,
                "Не удалось проверить Boosty. Попробуйте чуть позже.",
            )
            return
        with self.unit_of_work_factory(write=True) as unit_of_work:
            unit_of_work.subscriptions.update_boosty_membership(
                telegram_user_id,
                "active" if active else "inactive",
            )
        if not active:
            await self._boosty_send_message(
                chat_id,
                "Подписка Boosty неактивна. Новые ключи не выдаются.",
            )
            return
        wait_seconds = self._boosty_key_wait_seconds(telegram_user_id)
        availability = (
            "доступен сейчас"
            if wait_seconds <= 0
            else f"через {self._boosty_format_wait(wait_seconds)}"
        )
        await self._boosty_send_message(
            chat_id,
            "Подписка Boosty активна.\n"
            f"Следующий ключ MeshPro: {availability}.\n"
            f"Каждый ключ добавляет {BOOSTY_KEY_DURATION_DAYS} дней.",
        )

    def issue_monthly_boosty_key(
        self,
        telegram_user_id,
        telegram_username="",
    ):
        telegram_user_id = int(telegram_user_id)
        wait_seconds = self._boosty_key_wait_seconds(telegram_user_id)
        if wait_seconds > 0:
            return None, wait_seconds
        code, code_hash = self._boosty_generate_code()
        with self.unit_of_work_factory(write=True) as unit_of_work:
            unit_of_work.subscriptions.issue_boosty_subscriber_code(
                {
                    "code_hash": code_hash,
                    "telegram_user_id": telegram_user_id,
                    "telegram_username": telegram_username,
                    "duration_days": max(1, int(BOOSTY_KEY_DURATION_DAYS)),
                    "issue_kind": "subscriber",
                    "expires_at": BOOSTY_KEY_NEVER_EXPIRES_AT,
                },
                BOOSTY_KEY_ISSUE_INTERVAL_DAYS,
            )
        return code, 0

    def create_boosty_activation_code(
        self,
        telegram_user_id,
        telegram_username="",
        duration_days=None,
        issue_kind="gift",
    ):
        code, code_hash = self._boosty_generate_code()
        duration_days = max(
            1,
            min(3660, int(duration_days or BOOSTY_KEY_DURATION_DAYS)),
        )
        normalized_kind = str(issue_kind or "gift")[:24]
        with self.unit_of_work_factory(write=True) as unit_of_work:
            unit_of_work.subscriptions.create_boosty_code(
                {
                    "code_hash": code_hash,
                    "telegram_user_id": int(telegram_user_id),
                    "telegram_username": telegram_username,
                    "duration_days": duration_days,
                    "issue_kind": normalized_kind,
                    "expires_at": BOOSTY_KEY_NEVER_EXPIRES_AT,
                }
            )
        return code

    def _boosty_generate_code(self):
        raw = "".join(
            secrets.choice(BOOSTY_CODE_ALPHABET)
            for _ in range(BOOSTY_CODE_GROUPS * BOOSTY_CODE_GROUP_SIZE)
        )
        groups = [
            raw[index:index + BOOSTY_CODE_GROUP_SIZE]
            for index in range(0, len(raw), BOOSTY_CODE_GROUP_SIZE)
        ]
        code = "MPR-" + "-".join(groups)
        return code, self._boosty_code_hash(code)

    def _boosty_key_wait_seconds(self, telegram_user_id):
        with self.unit_of_work_factory() as unit_of_work:
            return unit_of_work.subscriptions.boosty_key_wait_seconds(
                int(telegram_user_id)
            )

    def _boosty_format_wait(self, seconds):
        seconds = max(0, int(seconds or 0))
        days, remainder = divmod(seconds, 86400)
        hours = max(1, (remainder + 3599) // 3600)
        if days:
            return f"{days} дн. {hours if remainder else 0} ч."
        return f"{hours} ч."

    def _boosty_key_message(self, code, duration_days, gift=False):
        prefix = "Подарочный" if gift else "Ежемесячный"
        next_line = (
            ""
            if gift
            else (
                f"\nСледующий ключ станет доступен через "
                f"{BOOSTY_KEY_ISSUE_INTERVAL_DAYS} дней."
            )
        )
        return (
            f"{prefix} одноразовый ключ MeshPro на {duration_days} дней:\n\n"
            f"{code}\n\n"
            "Ключ можно передать другому человеку. Он сработает один раз, "
            "а срок сложится с уже активной подпиской."
            f"{next_line}\n\nАктивация:\n{BOOSTY_ACTIVATION_URL}"
        )

    async def activate_boosty_subscription(self, login, password, code):
        if not self.boosty_activation_configured:
            raise BoostyActivationError("boosty_not_configured")
        normalized_login = str(login or "").strip().lower()
        if not normalized_login or not password:
            raise BoostyActivationError("invalid_credentials")
        ok, _ = self.authenticate_account(
            normalized_login,
            str(password),
            "",
            "",
            verify_only=True,
            allow_registration=False,
        )
        if not ok:
            raise BoostyActivationError("invalid_credentials")

        code_hash = self._boosty_code_hash(code)
        with self.unit_of_work_factory() as unit_of_work:
            row = unit_of_work.subscriptions.active_boosty_code(code_hash)
        if not row:
            raise BoostyActivationError("invalid_or_expired_code")
        telegram_user_id = int(row[0])
        duration_days = max(1, min(3660, int(row[1] or 30)))
        issue_kind = str(row[2] or "legacy")
        with self.unit_of_work_factory(write=True) as unit_of_work:
            if not unit_of_work.subscriptions.consume_boosty_code(
                code_hash,
                normalized_login,
            ):
                raise BoostyActivationError("invalid_or_expired_code")

        subscription = self.grant_subscription(
            normalized_login,
            "meshpro",
            plan_code=f"key_{duration_days}d",
            days=duration_days,
            provider="boosty_key",
            provider_subscription_id=f"key:{code_hash[:16]}",
            provider_event_id=f"boosty-key:{code_hash}",
        )
        self.record_subscription_event_once(
            normalized_login,
            "meshpro",
            "boosty_key_redeemed",
            {
                "telegram_user_id": telegram_user_id,
                "duration_days": duration_days,
                "issue_kind": issue_kind,
            },
            f"boosty-key-redeemed:{code_hash}",
        )
        return {
            "login": normalized_login,
            "duration_days": duration_days,
            "subscription": subscription,
        }

    async def reconcile_boosty_memberships(self):
        if not self.boosty_activation_configured:
            return {
                "checked": 0,
                "active": 0,
                "inactive": 0,
                "issued": 0,
                "errors": 0,
            }
        with self.unit_of_work_factory() as unit_of_work:
            rows = unit_of_work.subscriptions.boosty_recipients()
        stats = {
            "checked": 0,
            "active": 0,
            "inactive": 0,
            "issued": 0,
            "errors": 0,
        }
        for telegram_user_id, private_chat_id, telegram_username in rows:
            stats["checked"] += 1
            try:
                active = await self._boosty_user_is_member(
                    int(telegram_user_id)
                )
            except BoostyTelegramError as error:
                stats["errors"] += 1
                with self.unit_of_work_factory(write=True) as unit_of_work:
                    unit_of_work.subscriptions.update_boosty_membership(
                        telegram_user_id,
                        error=self._boosty_safe_error(error),
                    )
                continue

            with self.unit_of_work_factory(write=True) as unit_of_work:
                unit_of_work.subscriptions.update_boosty_membership(
                    telegram_user_id,
                    "active" if active else "inactive",
                )

            if not active:
                stats["inactive"] += 1
                await asyncio.sleep(0.08)
                continue

            stats["active"] += 1
            code, _ = self.issue_monthly_boosty_key(
                int(telegram_user_id),
                str(telegram_username or ""),
            )
            if code:
                try:
                    await self._boosty_send_message(
                        int(private_chat_id),
                        self._boosty_key_message(
                            code,
                            BOOSTY_KEY_DURATION_DAYS,
                            gift=False,
                        ),
                    )
                    stats["issued"] += 1
                except BoostyTelegramError as error:
                    self._boosty_revert_undelivered_key(
                        int(telegram_user_id),
                        code,
                        error,
                    )
                    stats["errors"] += 1
            await asyncio.sleep(0.08)
        self._boosty_cleanup_codes()
        return stats

    def _boosty_revert_undelivered_key(
        self,
        telegram_user_id,
        code,
        error,
    ):
        code_hash = self._boosty_code_hash(code)
        with self.unit_of_work_factory(write=True) as unit_of_work:
            unit_of_work.subscriptions.revert_boosty_subscriber_code(
                code_hash,
                int(telegram_user_id),
                self._boosty_safe_error(error),
            )

    async def _boosty_user_is_member(self, telegram_user_id):
        member = await self._boosty_get_chat_member(
            BOOSTY_TELEGRAM_GROUP_ID,
            int(telegram_user_id),
        )
        status = str(member.get("status") or "")
        return bool(
            status in BOOSTY_MEMBER_STATUSES
            or (status == "restricted" and member.get("is_member") is True)
        )

    async def _boosty_user_is_owner(self, telegram_user_id):
        if not BOOSTY_TELEGRAM_GROUP_ID or not BOOSTY_TELEGRAM_OWNER_ID:
            return False
        try:
            if int(telegram_user_id) != int(BOOSTY_TELEGRAM_OWNER_ID):
                return False
        except (TypeError, ValueError):
            return False
        member = await self._boosty_get_chat_member(
            BOOSTY_TELEGRAM_GROUP_ID,
            int(telegram_user_id),
        )
        return str(member.get("status") or "") == "creator"

    async def _boosty_get_chat_member(self, chat_id, telegram_user_id):
        return await self._boosty_telegram_request(
            "getChatMember",
            {
                "chat_id": chat_id,
                "user_id": int(telegram_user_id),
            },
        )

    async def _boosty_send_message(
        self,
        chat_id,
        text,
        reply_markup=None,
    ):
        payload = {
            "chat_id": chat_id,
            "text": str(text),
            "disable_web_page_preview": True,
        }
        if reply_markup:
            payload["reply_markup"] = reply_markup
        await self._boosty_telegram_request(
            "sendMessage",
            payload,
        )

    async def _boosty_answer_callback(
        self,
        callback_id,
        text="",
        show_alert=False,
    ):
        if not callback_id:
            return
        await self._boosty_telegram_request(
            "answerCallbackQuery",
            {
                "callback_query_id": str(callback_id),
                "text": str(text or "")[:200],
                "show_alert": bool(show_alert),
            },
        )

    async def _boosty_telegram_request(self, method, payload=None):
        session = getattr(self, "_boosty_session", None)
        if session is None or session.closed:
            raise BoostyTelegramError("telegram_session_unavailable")
        url = (
            f"{BOOSTY_TELEGRAM_API_URL}/bot"
            f"{BOOSTY_TELEGRAM_BOT_TOKEN}/{method}"
        )
        try:
            async with session.post(url, json=payload or {}) as response:
                data = await response.json(content_type=None)
        except (aiohttp.ClientError, asyncio.TimeoutError, ValueError) as error:
            raise BoostyTelegramError(
                f"telegram_{method}_request_failed"
            ) from error
        if response.status != 200 or not isinstance(data, dict) or not data.get("ok"):
            description = "telegram_api_error"
            if isinstance(data, dict):
                description = re.sub(
                    r"[^a-zA-Z0-9 _-]",
                    "",
                    str(data.get("description") or description),
                )[:120]
            raise BoostyTelegramError(
                f"telegram_{method}_failed:{response.status}:{description}"
            )
        return data.get("result")

    def _boosty_cleanup_codes(self):
        with self.unit_of_work_factory(write=True) as unit_of_work:
            unit_of_work.subscriptions.cleanup_boosty_codes()

    def _boosty_code_hash(self, code):
        normalized = re.sub(r"[^A-Z0-9]", "", str(code or "").upper())
        if not normalized.startswith("MPR"):
            normalized = "MPR" + normalized
        return hmac.new(
            BOOSTY_ACTIVATION_SECRET.encode("utf-8"),
            normalized.encode("ascii", errors="ignore"),
            hashlib.sha256,
        ).hexdigest()

    def _boosty_safe_error(self, error):
        message = str(error or "unknown_error")
        if BOOSTY_TELEGRAM_BOT_TOKEN:
            message = message.replace(BOOSTY_TELEGRAM_BOT_TOKEN, "[redacted]")
        return message[:200]
