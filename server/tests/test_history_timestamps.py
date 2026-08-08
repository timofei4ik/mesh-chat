import unittest

from server.server_storage import _history_created_at


class HistoryTimestampTests(unittest.TestCase):
    def test_preserves_iso_and_unix_message_times(self):
        self.assertEqual(
            "2026-07-04 18:05:06.123",
            _history_created_at({"created_at": "2026-07-04T18:05:06.123Z"}),
        )
        self.assertEqual(
            "2026-07-04 18:05:06.000",
            _history_created_at({"sent_at": 1783188306}),
        )

    def test_invalid_time_uses_current_utc_instead_of_bad_input(self):
        value = _history_created_at({"created_at": "not-a-date"})
        self.assertRegex(value, r"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3}$")


if __name__ == "__main__":
    unittest.main()
