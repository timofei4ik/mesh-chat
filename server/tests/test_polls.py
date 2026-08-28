import tempfile
import unittest
from pathlib import Path

from server import server_polls, server_storage


class PollRelay(server_storage.ServerStorageMixin, server_polls.ServerPollsMixin):
    def __init__(self):
        self.clients = {}
        self.invalidations = []
        self.client_logins = {
            "node-owner": "owner",
            "node-member": "member",
            "node-outsider": "outsider",
        }
        self.db = self.open_db()
        self.initialize_poll_storage()

    def invalidate_sync_v2_snapshot(
        self,
        login,
        reason,
        operation_id,
        metadata=None,
    ):
        self.invalidations.append(
            (login, reason, operation_id, dict(metadata or {}))
        )


class PollTests(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.previous_db_path = server_storage.DB_PATH
        server_storage.DB_PATH = Path(self.temp_dir.name) / "server.db"
        self.relay = PollRelay()
        for login, node in (
            ("owner", "node-owner"),
            ("member", "node-member"),
            ("outsider", "node-outsider"),
        ):
            self.relay.db.execute(
                """
                INSERT INTO accounts(login, password_salt, password_hash, display_name, node_id)
                VALUES(?,?,?,?,?)
                """,
                (login, "salt", "hash", login, node),
            )
        self.relay.db.execute(
            """
            INSERT INTO server_groups(group_id, group_name, members_json, owner_node)
            VALUES('group-1', 'Group', '["node-owner", "node-member"]', 'node-owner')
            """
        )
        self.relay.db.executemany(
            """
            INSERT INTO server_group_members(group_id, node_id, login)
            VALUES('group-1', ?, ?)
            """,
            (("node-owner", "owner"), ("node-member", "member")),
        )
        self.relay.db.executemany(
            """
            INSERT INTO server_group_messages(
                message_id, group_id, sender_node, sender_login, message
            ) VALUES(?,?,?,?,?)
            """,
            (
                ("message-1", "group-1", "node-owner", "owner", "Question"),
                ("member-message", "group-1", "node-member", "member", "Other"),
            ),
        )
        self.relay.db.commit()

    def tearDown(self):
        self.relay.db.close()
        server_storage.DB_PATH = self.previous_db_path
        self.temp_dir.cleanup()

    def create_poll(self, **overrides):
        packet = {
            "poll_id": "poll-1",
            "message_id": "message-1",
            "group_id": "group-1",
            "question": "Where should we meet?",
            "options": ["Cafe", "Park", "Office"],
            **overrides,
        }
        return self.relay.create_group_poll("node-owner", packet)

    def test_second_vote_is_rejected_and_first_choice_is_personalized(self):
        ok, _, poll = self.create_poll()
        self.assertTrue(ok)
        self.assertEqual([0, 0, 0], poll["counts"])

        ok, _, _ = self.relay.vote_group_poll("node-member", "poll-1", [1])
        self.assertTrue(ok)
        ok, reason, member_poll = self.relay.vote_group_poll(
            "node-member", "poll-1", [2]
        )
        self.assertFalse(ok)
        self.assertEqual("already_voted", reason)
        self.assertEqual([0, 1, 0], member_poll["counts"])
        self.assertEqual([1], member_poll["selected_options"])
        owner_poll = self.relay.poll_by_id("poll-1", "owner")
        self.assertEqual([], owner_poll["selected_options"])

    def test_quiz_validates_correct_option_and_rejects_outsider(self):
        ok, reason, _ = self.create_poll(is_quiz=True, correct_option=7)
        self.assertFalse(ok)
        self.assertEqual("invalid_correct_option", reason)

        ok, _, poll = self.create_poll(is_quiz=True, correct_option=1)
        self.assertTrue(ok)
        self.assertEqual(1, poll["correct_option"])
        self.assertFalse(poll["allows_multiple"])
        member_view = self.relay.poll_by_id("poll-1", "member")
        self.assertIsNone(member_view["correct_option"])
        ok, reason, _ = self.relay.vote_group_poll(
            "node-outsider", "poll-1", [1]
        )
        self.assertFalse(ok)
        self.assertEqual("group_access_denied", reason)
        ok, _, member_view = self.relay.vote_group_poll(
            "node-member", "poll-1", [0]
        )
        self.assertTrue(ok)
        self.assertEqual(1, member_view["correct_option"])

    def test_multiple_answers_require_explicit_option(self):
        ok, _, _ = self.create_poll()
        self.assertTrue(ok)
        ok, reason, _ = self.relay.vote_group_poll(
            "node-member", "poll-1", [0, 1]
        )
        self.assertFalse(ok)
        self.assertEqual("invalid_vote", reason)

        self.relay.db.execute("DELETE FROM server_polls")
        self.relay.db.commit()
        ok, _, _ = self.create_poll(allows_multiple=True)
        self.assertTrue(ok)
        ok, _, poll = self.relay.vote_group_poll(
            "node-member", "poll-1", [0, 1]
        )
        self.assertTrue(ok)
        self.assertEqual([1, 1, 0], poll["counts"])

    def test_quiz_never_accepts_multiple_answers(self):
        ok, _, poll = self.create_poll(
            is_quiz=True,
            correct_option=1,
            allows_multiple=True,
        )
        self.assertTrue(ok)
        self.assertFalse(poll["allows_multiple"])
        ok, reason, _ = self.relay.vote_group_poll(
            "node-member", "poll-1", [0, 1]
        )
        self.assertFalse(ok)
        self.assertEqual("invalid_vote", reason)

    def test_poll_and_personal_answer_survive_server_restart(self):
        ok, _, _ = self.create_poll(is_quiz=True, correct_option=2)
        self.assertTrue(ok)
        ok, _, _ = self.relay.vote_group_poll("node-member", "poll-1", [2])
        self.assertTrue(ok)

        self.relay.db.close()
        self.relay = PollRelay()

        member_poll = self.relay.poll_for_message("message-1", "member")
        self.assertIsNotNone(member_poll)
        self.assertEqual("Where should we meet?", member_poll["question"])
        self.assertEqual(["Cafe", "Park", "Office"], member_poll["options"])
        self.assertEqual([0, 0, 1], member_poll["counts"])
        self.assertEqual([2], member_poll["selected_options"])
        owner_poll = self.relay.polls_for_account("owner")[0]
        self.assertEqual([], owner_poll["selected_options"])
        self.assertEqual([0, 0, 1], owner_poll["counts"])

    def test_poll_mutations_invalidate_offline_member_snapshots(self):
        ok, _, _ = self.create_poll()
        self.assertTrue(ok)
        self.assertEqual(
            {"owner", "member"},
            {item[0] for item in self.relay.invalidations},
        )
        self.assertTrue(
            all(item[1] == "poll_created" for item in self.relay.invalidations)
        )

        self.relay.invalidations.clear()
        ok, _, _ = self.relay.vote_group_poll("node-member", "poll-1", [1])
        self.assertTrue(ok)
        self.assertEqual(
            {("owner", "poll_voted"), ("member", "poll_voted")},
            {(item[0], item[1]) for item in self.relay.invalidations},
        )

    def test_poll_cannot_attach_to_missing_or_another_users_message(self):
        ok, reason, _ = self.create_poll(message_id="missing-message")
        self.assertFalse(ok)
        self.assertEqual("poll_message_not_found", reason)

        ok, reason, _ = self.create_poll(message_id="member-message")
        self.assertFalse(ok)
        self.assertEqual("poll_message_mismatch", reason)

    def test_deleting_poll_message_removes_poll_and_votes(self):
        ok, _, _ = self.create_poll()
        self.assertTrue(ok)
        ok, _, _ = self.relay.vote_group_poll("node-member", "poll-1", [1])
        self.assertTrue(ok)

        saved = self.relay.save_history_packet(
            {
                "type": "group_message_delete",
                "group_message_id": "message-1",
                "source_node": "node-owner",
            }
        )

        self.assertIsNot(saved, False)
        self.assertIsNone(self.relay.poll_by_id("poll-1", "owner"))
        self.assertEqual(
            0,
            self.relay.db.execute(
                "SELECT COUNT(*) FROM server_poll_votes"
            ).fetchone()[0],
        )

    def test_deleting_group_removes_poll_and_votes(self):
        ok, _, _ = self.create_poll()
        self.assertTrue(ok)
        ok, _, _ = self.relay.vote_group_poll("node-member", "poll-1", [1])
        self.assertTrue(ok)

        self.relay.save_history_packet(
            {"type": "group_delete", "group_id": "group-1"}
        )

        self.assertEqual(
            0,
            self.relay.db.execute(
                "SELECT COUNT(*) FROM server_polls"
            ).fetchone()[0],
        )
        self.assertEqual(
            0,
            self.relay.db.execute(
                "SELECT COUNT(*) FROM server_poll_votes"
            ).fetchone()[0],
        )


if __name__ == "__main__":
    unittest.main()
