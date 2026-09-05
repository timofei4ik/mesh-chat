import base64
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path
from unittest.mock import AsyncMock, patch

from server import server_ai, server_storage, server_subscription, server_sync


class TranscriptionHallucinationTests(unittest.TestCase):
    def test_filters_common_silence_hallucinations(self):
        for phrase in (
            "Продолжение следует...",
            "ДО НОВЫХ ВСТРЕЧ!",
            "Thank you.",
            "Добавил субтитры DimaTorzok",
        ):
            with self.subTest(phrase=phrase):
                self.assertTrue(server_ai._is_transcription_hallucination(phrase))

    def test_keeps_normal_speech(self):
        self.assertFalse(
            server_ai._is_transcription_hallucination("Привет, как дела?")
        )


class AiRelay(
    server_storage.ServerStorageMixin,
    server_subscription.ServerSubscriptionMixin,
    server_sync.ServerSyncMixin,
    server_ai.ServerAiMixin,
):
    def __init__(self):
        self.db = self.open_db()
        self.fail_provider = False
        self.fail_transcription = False
        self.fail_ocr = False
        self.fail_smart_replies = False
        self.fail_person_memory = False
        self.fail_call_summary = False

    @property
    def ai_backend_ready(self):
        return True

    @property
    def ai_transcription_backend_ready(self):
        return True

    @property
    def ai_vision_backend_ready(self):
        return True

    async def _request_ai_rewrite(self, text, style):
        if self.fail_provider:
            raise RuntimeError("provider unavailable")
        return f"{style}: {text}"

    async def _request_ai_summary(self, transcript):
        if self.fail_provider:
            raise RuntimeError("provider unavailable")
        return f"Summary: {transcript}"

    async def _request_ai_translation(
        self,
        text,
        target_language,
        emojify=False,
    ):
        if self.fail_provider:
            raise RuntimeError("provider unavailable")
        suffix = "+emoji" if emojify else ""
        return f"{target_language}{suffix}: {text}"

    async def _request_ai_transcription(
        self,
        audio_bytes,
        filename,
        content_type,
        language_hint="",
    ):
        if self.fail_transcription:
            raise RuntimeError("provider unavailable")
        return {
            "text": "Hello from the voice message",
            "language": "en",
            "duration_seconds": 75,
        }

    async def _request_ai_ocr(self, image_bytes, content_type):
        if self.fail_ocr:
            raise RuntimeError("provider unavailable")
        return "Invoice 42\nTotal: 500 RUB"

    async def _request_ai_smart_replies(self, conversation, latest_incoming):
        if self.fail_smart_replies:
            raise RuntimeError("provider unavailable")
        return ["Sounds good", "I will check", "Can we do it later?"]

    async def _request_ai_person_memory(self, question, transcript):
        if self.fail_person_memory:
            raise RuntimeError("provider unavailable")
        return f"{question}: {transcript.splitlines()[0]}"

    async def _request_ai_call_summary(self, notes):
        if self.fail_call_summary:
            raise RuntimeError("provider unavailable")
        return f"Topics: {notes}"


class LanguageGuardRelay(server_ai.ServerAiMixin):
    def __init__(self, responses):
        self.responses = list(responses)
        self.calls = []

    async def _perform_ai_rewrite(
        self,
        text,
        style,
        language_mode,
        strict_language=False,
    ):
        self.calls.append((language_mode, strict_language))
        return self.responses.pop(0)


class AiTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.previous_db_path = server_storage.DB_PATH
        server_storage.DB_PATH = Path(self.temp_dir.name) / "server.db"
        self.relay = AiRelay()
        self.relay.db.execute(
            """
            INSERT INTO accounts(
                login,
                password_salt,
                password_hash,
                display_name
            )
            VALUES('subscriber', 'salt', 'hash', 'Subscriber')
            """
        )
        self.relay.db.commit()

    async def asyncTearDown(self):
        self.relay.db.close()
        server_storage.DB_PATH = self.previous_db_path
        self.temp_dir.cleanup()

    async def test_rewrite_requires_meshpro_and_tracks_monthly_usage(self):
        denied = await self.relay.rewrite_text_with_ai(
            "subscriber",
            "hello there",
            "proofread",
        )
        self.assertEqual("meshpro_required", denied["error"])

        self.relay.grant_subscription("subscriber", days=7)
        result = await self.relay.rewrite_text_with_ai(
            "subscriber",
            "hello there",
            "friendly",
        )
        self.assertTrue(result["ok"])
        self.assertEqual("friendly: hello there", result["text"])
        self.assertEqual(49, result["remaining"])

    async def test_styled_rewrite_supports_emojify(self):
        self.relay.grant_subscription("subscriber", days=7)
        result = await self.relay.rewrite_text_with_ai(
            "subscriber",
            "we leave at dawn",
            "viking+emojify",
        )
        self.assertTrue(result["ok"])
        self.assertEqual(
            "viking+emojify: we leave at dawn",
            result["text"],
        )

    def test_style_examples_match_the_source_language(self):
        russian = server_ai._rewrite_style_example("viking", "russian")
        english = server_ai._rewrite_style_example("viking", "english")

        self.assertIn("Здравия", russian)
        self.assertIn("Hail", english)

    def test_greeting_question_may_make_implicit_addressee_explicit(self):
        self.assertTrue(
            server_ai._rewrite_structure_is_preserved(
                "Привет, как дела?",
                "Здравия тебе! Крепок ли дух, как идут дела?",
            )
        )
        self.assertFalse(
            server_ai._rewrite_structure_is_preserved(
                "Привет, как дела?",
                "Я отлично себя чувствую!",
            )
        )

    async def test_lifetime_ai_does_not_consume_a_counter(self):
        self.relay.grant_lifetime_subscription("subscriber")

        first = await self.relay.rewrite_text_with_ai(
            "subscriber",
            "hello there",
            "friendly",
        )
        second = await self.relay.rewrite_text_with_ai(
            "subscriber",
            "hello again",
            "friendly",
        )

        self.assertTrue(first["ok"])
        self.assertTrue(second["ok"])
        self.assertGreater(first["remaining"], 2_000_000_000)
        self.assertEqual(
            0,
            self.relay.meshpro_usage_count(
                "subscriber",
                "ai_text_rewrite",
                datetime.now(timezone.utc).strftime("%Y-%m"),
            ),
        )

    def test_rewrite_guard_rejects_answers_and_mixed_alphabet_noise(self):
        source = "приветствую, как дела?"
        self.assertFalse(
            server_ai._rewrite_structure_is_preserved(
                source,
                "Привет, всё хорошо",
            )
        )
        self.assertFalse(
            server_ai._rewrite_structure_is_preserved(
                source,
                "Привет! Как жизнь тебя trataet?",
            )
        )
        self.assertTrue(
            server_ai._rewrite_structure_is_preserved(
                source,
                "Приветствую! Как идут дела?",
            )
        )

    def test_rewrite_guard_rejects_invented_speaker_roles(self):
        source = "\u043f\u0440\u0438\u0432\u0435\u0442\u0441\u0442\u0432\u0443\u044e, \u043a\u0430\u043a \u0434\u0435\u043b\u0430?"
        self.assertFalse(
            server_ai._rewrite_structure_is_preserved(
                source,
                "\u0423\u0433\u0430-\u0443\u0433\u0430! \u042f \u0445\u043e\u0440\u043e\u0448\u043e. \u0422\u044b \u043a\u0430\u043a?",
            )
        )
        self.assertFalse(
            server_ai._rewrite_structure_is_preserved(
                source,
                "\u0421\u043e\u043b\u043d\u0446\u0435 \u0441\u0432\u0435\u0442\u0438\u0442. \u041a\u0430\u043a \u0434\u0435\u043b\u0430?",
            )
        )
        self.assertTrue(
            server_ai._rewrite_structure_is_preserved(
                source,
                "\u0417\u0434\u0440\u0430\u0432\u0438\u044f. \u041a\u0430\u043a \u0438\u0434\u0443\u0442 \u0434\u0435\u043b\u0430?",
            )
        )

    async def test_provider_failure_returns_reserved_quota(self):
        self.relay.grant_subscription("subscriber", days=7)
        self.relay.fail_provider = True
        result = await self.relay.rewrite_text_with_ai(
            "subscriber",
            "hello",
            "business",
        )
        self.assertEqual("provider_error", result["error"])
        usage = self.relay.db.execute(
            "SELECT COALESCE(SUM(used_count), 0) FROM meshpro_usage"
        ).fetchone()[0]
        self.assertEqual(0, usage)

    async def test_translation_requires_meshpro_and_tracks_usage(self):
        denied = await self.relay.translate_message_with_ai(
            "subscriber",
            "hello",
            "ru",
        )
        self.assertEqual("meshpro_required", denied["error"])

        self.relay.grant_subscription("subscriber", days=7)
        result = await self.relay.translate_message_with_ai(
            "subscriber",
            "hello",
            "ru",
        )
        self.assertTrue(result["ok"])
        self.assertEqual("ru: hello", result["text"])
        self.assertEqual("en", result["source_language"])
        self.assertEqual(149, result["remaining"])

        emoji_result = await self.relay.translate_message_with_ai(
            "subscriber",
            "hello",
            "ru",
            True,
        )
        self.assertTrue(emoji_result["ok"])
        self.assertEqual("ru+emoji: hello", emoji_result["text"])

    async def test_translation_releases_quota_after_provider_failure(self):
        self.relay.grant_subscription("subscriber", days=7)
        self.relay.fail_provider = True
        result = await self.relay.translate_message_with_ai(
            "subscriber",
            "hello",
            "de",
        )
        self.assertEqual("provider_error", result["error"])
        usage = self.relay.meshpro_usage_count(
            "subscriber",
            "ai_message_translation",
            datetime.now(timezone.utc).strftime("%Y-%m"),
        )
        self.assertEqual(0, usage)

    async def test_summary_requires_meshpro_and_tracks_usage(self):
        denied = await self.relay.summarize_chat_with_ai(
            "subscriber",
            [{"sender": "Alex", "text": "Meet at six"}],
        )
        self.assertEqual("meshpro_required", denied["error"])

        self.relay.grant_subscription("subscriber", days=7)
        result = await self.relay.summarize_chat_with_ai(
            "subscriber",
            [
                {"sender": "Alex", "text": "Meet at six"},
                {"sender": "You", "text": "Agreed"},
            ],
        )
        self.assertTrue(result["ok"])
        self.assertIn("Meet at six", result["text"])
        self.assertEqual(29, result["remaining"])

    async def test_person_memory_requires_meshpro_and_uses_chat_evidence(self):
        messages = [
            {
                "sender": "Max",
                "date": "2026-07-18T18:00:00Z",
                "text": "Pepperoni is my favorite pizza",
            }
        ]
        denied = await self.relay.answer_person_memory_with_ai(
            "subscriber",
            "Which pizza does Max like?",
            messages,
        )
        self.assertEqual("meshpro_required", denied["error"])

        self.relay.grant_subscription("subscriber", days=7)
        result = await self.relay.answer_person_memory_with_ai(
            "subscriber",
            "Which pizza does Max like?",
            messages,
        )
        self.assertTrue(result["ok"])
        self.assertIn("Pepperoni", result["text"])
        self.assertEqual(59, result["remaining"])

    async def test_person_memory_provider_failure_releases_quota(self):
        self.relay.grant_subscription("subscriber", days=7)
        self.relay.fail_person_memory = True
        result = await self.relay.answer_person_memory_with_ai(
            "subscriber",
            "What did Max choose?",
            [{"sender": "Max", "text": "Pepperoni", "date": "today"}],
        )
        self.assertEqual("provider_error", result["error"])
        usage = self.relay.meshpro_usage_count(
            "subscriber",
            "ai_person_memory",
            datetime.now(timezone.utc).strftime("%Y-%m"),
        )
        self.assertEqual(0, usage)

    async def test_call_summary_requires_meshpro_and_tracks_usage(self):
        denied = await self.relay.summarize_call_notes_with_ai(
            "subscriber",
            "We agreed to meet on Friday",
        )
        self.assertEqual("meshpro_required", denied["error"])

        self.relay.grant_subscription("subscriber", days=7)
        result = await self.relay.summarize_call_notes_with_ai(
            "subscriber",
            "We agreed to meet on Friday",
        )
        self.assertTrue(result["ok"])
        self.assertIn("Friday", result["text"])
        self.assertEqual(29, result["remaining"])

    async def test_transcription_is_metered_saved_and_reused(self):
        self.relay.grant_subscription("subscriber", days=7)
        encoded = base64.b64encode(b"fake m4a bytes").decode()
        result = await self.relay.transcribe_voice_with_ai(
            "subscriber",
            "voice-message-1",
            "voice_75s.m4a",
            encoded,
            75,
            "en",
        )
        self.assertTrue(result["ok"])
        self.assertEqual("Hello from the voice message", result["text"])
        self.assertEqual(58, result["remaining_minutes"])
        self.assertFalse(result["cached"])

        cached = await self.relay.transcribe_voice_with_ai(
            "subscriber",
            "voice-message-1",
            "voice_75s.m4a",
            "",
            0,
        )
        self.assertTrue(cached["ok"])
        self.assertTrue(cached["cached"])
        usage = self.relay.meshpro_usage_count(
            "subscriber",
            "ai_voice_transcription",
            datetime.now(timezone.utc).strftime("%Y-%m"),
        )
        self.assertEqual(2, usage)

    async def test_live_call_captions_are_not_saved_as_voice_message_history(self):
        self.relay.grant_subscription("subscriber", days=7)
        result = await self.relay.transcribe_voice_with_ai(
            "subscriber", "call-caption-room-chunk", "voice.m4a",
            base64.b64encode(b"fake m4a bytes").decode(), 2, "en",
        )
        self.assertTrue(result["ok"])
        self.assertFalse(self.relay.get_ai_voice_transcription("subscriber", "call-caption-room-chunk"))

    async def test_live_captions_charge_seconds_instead_of_a_minute_per_chunk(self):
        self.relay.grant_subscription("subscriber", days=7)
        transcript = {"text": "Hello there", "language": "en", "duration_seconds": 3}
        with patch.object(self.relay, "_request_ai_transcription", AsyncMock(return_value=transcript)):
            for index in range(4):
                result = await self.relay.transcribe_voice_with_ai(
                    "subscriber", f"call-caption-{index}", "voice.m4a",
                    base64.b64encode(b"fake audio").decode(), 3, "en",
                )
                self.assertTrue(result["ok"])
        period = datetime.now(timezone.utc).strftime("%Y-%m")
        self.assertEqual(12, self.relay.meshpro_usage_count("subscriber", "ai_call_caption_seconds", period))
        self.assertEqual(0, self.relay.meshpro_usage_count("subscriber", "ai_voice_transcription", period))

    async def test_first_usage_reservation_cannot_exceed_entire_allowance(self):
        self.assertFalse(self.relay.reserve_meshpro_usage("subscriber", "test", "2026-09", 1, amount=2))
        self.assertEqual(0, self.relay.meshpro_usage_count("subscriber", "test", "2026-09"))

    async def test_transcription_failure_releases_reserved_minutes(self):
        self.relay.grant_subscription("subscriber", days=7)
        self.relay.fail_transcription = True
        result = await self.relay.transcribe_voice_with_ai(
            "subscriber",
            "voice-message-2",
            "voice_125s.m4a",
            base64.b64encode(b"fake m4a bytes").decode(),
            125,
        )
        self.assertEqual("provider_error", result["error"])
        usage = self.relay.meshpro_usage_count(
            "subscriber",
            "ai_voice_transcription",
            datetime.now(timezone.utc).strftime("%Y-%m"),
        )
        self.assertEqual(0, usage)

    async def test_transcription_is_attached_to_account_sync(self):
        self.relay.save_ai_voice_transcription(
            "subscriber",
            "voice-message-sync",
            "Persistent transcript",
            "en",
            12.5,
        )
        self.relay.db.execute(
            """
            INSERT INTO server_files(
                file_id,
                sender_node,
                sender_login,
                sender_name,
                receiver_node,
                receiver_login,
                filename,
                data
            )
            VALUES(?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                "voice-message-sync",
                "node-1",
                "subscriber",
                "Subscriber",
                "node-2",
                "peer",
                "voice_12s.m4a",
                "00",
            ),
        )
        self.relay.db.commit()
        packet = self.relay.build_sync_packet("subscriber", "node-1")
        file_info = next(
            item
            for item in packet["files"]
            if item["file_id"] == "voice-message-sync"
        )
        self.assertEqual("Persistent transcript", file_info["transcription"])
        self.assertEqual("en", file_info["transcription_language"])
        self.assertEqual(12.5, file_info["transcription_duration_seconds"])

    async def test_ocr_is_metered_saved_reused_and_attached_to_sync(self):
        self.relay.grant_subscription("subscriber", days=7)
        encoded = base64.b64encode(b"fake jpeg bytes").decode()
        result = await self.relay.extract_image_text_with_ai(
            "subscriber",
            "image-message-1",
            "receipt.jpg",
            encoded,
        )
        self.assertTrue(result["ok"])
        self.assertEqual("Invoice 42\nTotal: 500 RUB", result["text"])
        self.assertEqual(99, result["remaining"])
        self.assertFalse(result["cached"])

        cached = await self.relay.extract_image_text_with_ai(
            "subscriber",
            "image-message-1",
            "receipt.jpg",
            "",
        )
        self.assertTrue(cached["ok"])
        self.assertTrue(cached["cached"])

        self.relay.db.execute(
            """
            INSERT INTO server_files(
                file_id,
                sender_node,
                sender_login,
                sender_name,
                receiver_node,
                receiver_login,
                filename,
                data
            )
            VALUES(?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                "image-message-1",
                "node-1",
                "subscriber",
                "Subscriber",
                "node-2",
                "peer",
                "receipt.jpg",
                "00",
            ),
        )
        self.relay.db.commit()
        packet = self.relay.build_sync_packet("subscriber", "node-1")
        file_info = next(
            item
            for item in packet["files"]
            if item["file_id"] == "image-message-1"
        )
        self.assertTrue(file_info["ocr_processed"])
        self.assertEqual("Invoice 42\nTotal: 500 RUB", file_info["ocr_text"])

    async def test_ocr_provider_failure_releases_usage(self):
        self.relay.grant_subscription("subscriber", days=7)
        self.relay.fail_ocr = True
        result = await self.relay.extract_image_text_with_ai(
            "subscriber",
            "image-message-2",
            "receipt.png",
            base64.b64encode(b"fake png bytes").decode(),
        )
        self.assertEqual("provider_error", result["error"])
        period = datetime.now(timezone.utc).strftime("%Y-%m")
        self.assertEqual(
            0,
            self.relay.meshpro_usage_count(
                "subscriber",
                "ai_image_ocr",
                period,
            ),
        )

    async def test_smart_replies_require_meshpro_and_track_usage(self):
        messages = [
            {"sender": "Alex", "text": "Meet at six?", "is_mine": False},
            {"sender": "You", "text": "Maybe", "is_mine": True},
            {"sender": "Alex", "text": "Please confirm", "is_mine": False},
        ]
        denied = await self.relay.suggest_replies_with_ai(
            "subscriber",
            messages,
        )
        self.assertEqual("meshpro_required", denied["error"])

        self.relay.grant_subscription("subscriber", days=7)
        result = await self.relay.suggest_replies_with_ai(
            "subscriber",
            messages,
        )
        self.assertTrue(result["ok"])
        self.assertEqual(3, len(result["replies"]))
        self.assertEqual(99, result["remaining"])

    async def test_smart_reply_provider_failure_releases_usage(self):
        self.relay.grant_subscription("subscriber", days=7)
        self.relay.fail_smart_replies = True
        result = await self.relay.suggest_replies_with_ai(
            "subscriber",
            [{"sender": "Alex", "text": "Hello", "is_mine": False}],
        )
        self.assertEqual("provider_error", result["error"])
        period = datetime.now(timezone.utc).strftime("%Y-%m")
        self.assertEqual(
            0,
            self.relay.meshpro_usage_count(
                "subscriber",
                "ai_smart_replies",
                period,
            ),
        )

    def test_smart_reply_json_parser_is_strict_and_deduplicates(self):
        parsed = self.relay._parse_smart_replies(
            '{"replies":["Yes", "Yes", "Later", "Tell me more"]}'
        )
        self.assertEqual(["Yes", "Later", "Tell me more"], parsed)

    def test_chat_completion_output_supports_provider_shapes(self):
        self.assertEqual(
            "plain response",
            self.relay._extract_ai_output({"output_text": "plain response"}),
        )
        self.assertEqual(
            "joined response",
            self.relay._extract_ai_output(
                {
                    "choices": [
                        {
                            "message": {
                                "content": [
                                    {"type": "text", "text": "joined "},
                                    {"type": "text", "text": "response"},
                                ]
                            }
                        }
                    ]
                }
            ),
        )
        self.assertEqual(
            "",
            self.relay._extract_ai_output(
                {"choices": [{"message": {"reasoning": "internal only"}}]}
            ),
        )

    async def test_usage_reservation_supports_multiple_units_atomically(self):
        period = datetime.now(timezone.utc).strftime("%Y-%m")
        self.assertTrue(
            self.relay.reserve_meshpro_usage(
                "subscriber",
                "test_units",
                period,
                3,
                amount=2,
            )
        )
        self.assertFalse(
            self.relay.reserve_meshpro_usage(
                "subscriber",
                "test_units",
                period,
                3,
                amount=2,
            )
        )
        self.assertEqual(
            2,
            self.relay.meshpro_usage_count(
                "subscriber",
                "test_units",
                period,
            ),
        )

    async def test_rewrite_rejects_unknown_style_and_enforces_quota(self):
        self.relay.grant_subscription("subscriber", days=7)
        invalid = await self.relay.rewrite_text_with_ai(
            "subscriber",
            "hello",
            "do-anything",
        )
        self.assertEqual("unsupported_style", invalid["error"])

        period = datetime.now(timezone.utc).strftime("%Y-%m")
        self.relay.db.execute(
            """
            INSERT INTO meshpro_usage(
                login,
                feature_id,
                period_key,
                used_count
            )
            VALUES('subscriber', 'ai_text_rewrite', ?, 50)
            """,
            (period,),
        )
        self.relay.db.commit()
        exhausted = await self.relay.rewrite_text_with_ai(
            "subscriber",
            "hello",
            "proofread",
        )
        self.assertEqual("quota_exceeded", exhausted["error"])

    async def test_russian_translation_is_retried_in_russian(self):
        relay = LanguageGuardRelay(
            [
                "Hello, how are you?",
                "Привет, как твои дела?",
            ]
        )
        result = await relay._request_ai_rewrite(
            "привет как у тебя дела",
            "friendly",
        )
        self.assertEqual("Привет, как твои дела?", result)
        self.assertEqual(
            [("russian", False), ("russian", True)],
            relay.calls,
        )

    async def test_english_text_stays_english_without_retry(self):
        relay = LanguageGuardRelay(["Hello, how are you doing?"])
        result = await relay._request_ai_rewrite(
            "hello how are you",
            "proofread",
        )
        self.assertEqual("Hello, how are you doing?", result)
        self.assertEqual([("english", False)], relay.calls)

    async def test_persistent_language_change_is_rejected(self):
        relay = LanguageGuardRelay(
            [
                "This was translated.",
                "This is still translated.",
            ]
        )
        with self.assertRaisesRegex(RuntimeError, "changed the source language"):
            await relay._request_ai_rewrite(
                "это нельзя переводить",
                "business",
            )


if __name__ == "__main__":
    unittest.main()
