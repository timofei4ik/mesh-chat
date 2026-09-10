import json
import sqlite3
import unittest

from server.server_storage import ServerStorageMixin
from server.server_sync import ServerSyncMixin


class DirectMessagePrivacyTests(unittest.TestCase):
    def setUp(self):
        self.server = ServerStorageMixin.__new__(ServerStorageMixin)
        self.server.db = sqlite3.connect(":memory:")
        self.server.db.executescript(
            """
            CREATE TABLE accounts(
                login TEXT PRIMARY KEY,
                direct_message_privacy TEXT NOT NULL DEFAULT 'everyone'
            );
            CREATE TABLE direct_messages(
                sender_login TEXT,
                receiver_login TEXT
            );
            CREATE TABLE server_group_members(
                group_id TEXT,
                node_id TEXT,
                login TEXT
            );
            INSERT INTO accounts(login, direct_message_privacy)
            VALUES ('alice', 'everyone'), ('bob', 'sharedGroups');
            """
        )

    def packet(self):
        return {
            "type": "chat_message",
            "sender_login": "alice",
            "receiver_login": "bob",
        }

    def tearDown(self):
        self.server.db.close()

    def test_shared_group_policy_rejects_stranger(self):
        self.assertFalse(self.server.authorize_direct_message(self.packet()))

    def test_shared_group_policy_accepts_member(self):
        self.server.db.executemany(
            "INSERT INTO server_group_members VALUES (?, ?, ?)",
            [("group-1", "alice-node", "alice"),
             ("group-1", "bob-node", "bob")],
        )
        self.assertTrue(self.server.authorize_direct_message(self.packet()))

    def test_existing_chat_is_never_locked(self):
        self.server.db.execute(
            "UPDATE accounts SET direct_message_privacy='nobody' "
            "WHERE login='bob'"
        )
        self.server.db.execute(
            "INSERT INTO direct_messages VALUES ('bob', 'alice')"
        )
        self.assertTrue(self.server.authorize_direct_message(self.packet()))


class _PresenceServer(ServerSyncMixin):
    def __init__(self):
        self.client_logins = {
            "alice-node": "alice",
            "bob-node": "bob",
        }
        self.client_names = {
            "alice-node": "Alice",
            "bob-node": "Bob",
        }
        self.clients = {}
        self.sent = {}

    async def get_realtime_presence_users(self):
        return [
            {"node_id": "alice-node", "username": "Alice"},
            {"node_id": "bob-node", "username": "Bob"},
        ]

    def get_profile_by_node(self, node_id):
        hidden = node_id == "alice-node"
        return {
            "login": "alice" if hidden else "bob",
            "display_name": "Alice" if hidden else "Bob",
            "public_username": "alice" if hidden else "bob",
            "about": "private bio" if hidden else "public bio",
            "avatar_data": "private avatar" if hidden else "public avatar",
            "encryption_public_key": f"key-{node_id}",
            "privacy_show_online": not hidden,
            "privacy_show_avatar": not hidden,
            "privacy_show_about": not hidden,
            "direct_message_privacy": "sharedGroups" if hidden else "everyone",
        }

    async def send_packet_to_node(self, node_id, packet):
        self.sent[node_id] = json.loads(json.dumps(packet))


class PresencePrivacyTests(unittest.IsolatedAsyncioTestCase):
    async def test_presence_is_filtered_per_viewer(self):
        server = _PresenceServer()
        await server.send_user_list()

        alice_for_self = next(
            user for user in server.sent["alice-node"]["users"]
            if user["node_id"] == "alice-node"
        )
        alice_for_bob = next(
            user for user in server.sent["bob-node"]["users"]
            if user["node_id"] == "alice-node"
        )
        self.assertTrue(alice_for_self["online"])
        self.assertEqual("private bio", alice_for_self["about"])
        self.assertFalse(alice_for_bob["online"])
        self.assertEqual("", alice_for_bob["about"])
        self.assertEqual("", alice_for_bob["avatar_data"])
        self.assertEqual("sharedGroups", alice_for_bob["direct_message_privacy"])
