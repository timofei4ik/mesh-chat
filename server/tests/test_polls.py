import tempfile
import unittest
from pathlib import Path

from server import server_polls, server_storage


class PollRelay(server_storage.ServerStorageMixin, server_polls.ServerPollsMixin):
    def __init__(self):
        self.clients = {}
        self.client_logins = {
            "node-owner": "owner",
            "node-member": "member",
            "node-outsider": "outsider",
        }
        self.db = self.open_db()
        self.initialize_poll_storage()


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

    def test_vote_replaces_previous_choice_and_is_personalized(self):
        ok, _, poll = self.create_poll()
        self.assertTrue(ok)
        self.assertEqual([0, 0, 0], poll["counts"])

        ok, _, _ = self.relay.vote_group_poll("node-member", "poll-1", [1])
        self.assertTrue(ok)
        ok, _, member_poll = self.relay.vote_group_poll(
            "node-member", "poll-1", [2]
        )
        self.assertTrue(ok)
        self.assertEqual([0, 0, 1], member_poll["counts"])
        self.assertEqual([2], member_poll["selected_options"])
        owner_poll = self.relay.poll_by_id("poll-1", "owner")
        self.assertEqual([], owner_poll["selected_options"])

    def test_quiz_validates_correct_option_and_rejects_outsider(self):
        ok, reason, _ = self.create_poll(is_quiz=True, correct_option=7)
        self.assertFalse(ok)
        self.assertEqual("invalid_correct_option", reason)

        ok, _, poll = self.create_poll(is_quiz=True, correct_option=1)
        self.assertTrue(ok)
        self.assertEqual(1, poll["correct_option"])
        ok, reason, _ = self.relay.vote_group_poll(
            "node-outsider", "poll-1", [1]
        )
        self.assertFalse(ok)
        self.assertEqual("group_access_denied", reason)

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


if __name__ == "__main__":
    unittest.main()
