import unittest

from server.server_connection import cleanup_connection


class FakeConnectionServer:
    def __init__(self):
        self.clients = {}
        self.client_names = {}
        self.client_logins = {}
        self.client_capabilities = {}
        self.service_clients = {}
        self.service_logins = {}
        self.client_services = {}
        self.offline_updates = []
        self.user_list_sends = 0

    def set_account_device_online(self, login, node_id, online):
        self.offline_updates.append((login, node_id, online))

    async def send_user_list(self):
        self.user_list_sends += 1


class ServerConnectionTests(unittest.IsolatedAsyncioTestCase):
    async def test_cleanup_removes_only_the_current_client_socket(self):
        server = FakeConnectionServer()
        stale_socket = object()
        current_socket = object()
        server.clients["node-1"] = current_socket
        server.client_names["node-1"] = "Alice"
        server.client_logins["node-1"] = "alice"
        server.client_capabilities["node-1"] = {"sync_v2": True}

        await cleanup_connection(server, stale_socket, "node-1")
        self.assertIs(current_socket, server.clients["node-1"])
        self.assertEqual([], server.offline_updates)
        self.assertEqual(0, server.user_list_sends)

        await cleanup_connection(server, current_socket, "node-1")
        self.assertNotIn("node-1", server.clients)
        self.assertNotIn("node-1", server.client_names)
        self.assertNotIn("node-1", server.client_logins)
        self.assertNotIn("node-1", server.client_capabilities)
        self.assertEqual(
            [("alice", "node-1", False)],
            server.offline_updates,
        )
        self.assertEqual(1, server.user_list_sends)

    async def test_cleanup_removes_only_the_current_service_socket(self):
        server = FakeConnectionServer()
        stale_socket = object()
        current_socket = object()
        server.service_clients["vpn-node"] = current_socket
        server.service_logins["vpn-node"] = "alice"
        server.client_services["vpn-node"] = "meshprivacy"

        await cleanup_connection(server, stale_socket, "vpn-node")
        self.assertIs(current_socket, server.service_clients["vpn-node"])

        await cleanup_connection(server, current_socket, "vpn-node")
        self.assertNotIn("vpn-node", server.service_clients)
        self.assertNotIn("vpn-node", server.service_logins)
        self.assertNotIn("vpn-node", server.client_services)
