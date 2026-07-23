import asyncio
import inspect
import re
import unittest

from server import server as server_module
from server import (
    server_auth,
    server_billing,
    server_boosty,
    server_command_bus,
    server_commands,
    server_commands_ai,
    server_commands_automation,
    server_commands_identity,
    server_commands_push,
    server_commands_subscriptions,
    server_commands_sync,
    server_connection,
    server_email_auth,
    server_mutations,
    server_protocol,
    server_subscription,
    server_transport,
    server_workers,
)


class FakeBillingHttpServer:
    def __init__(self, relay):
        self.relay = relay
        self.started = False
        self.closed = False

    async def start(self):
        self.started = True
        return True

    async def close(self):
        self.closed = True


class FakeRelay:
    def __init__(self):
        self.boosty_started = False
        self.boosty_stopped = False
        self.wireguard_runs = 0
        self.schedule_runs = 0

    async def start_boosty_bridge(self):
        self.boosty_started = True
        return True

    async def stop_boosty_bridge(self):
        self.boosty_stopped = True

    def reconcile_wireguard_peers(self):
        self.wireguard_runs += 1
        return {"active": 0}

    async def dispatch_due_scheduled_messages(self):
        self.schedule_runs += 1


class ServerArchitectureTests(unittest.IsolatedAsyncioTestCase):
    def test_protocol_symbols_remain_available_from_entrypoint(self):
        self.assertIs(
            server_module.protocol_compatibility,
            server_protocol.protocol_compatibility,
        )
        self.assertEqual(
            server_module.WEBSOCKET_MAX_SIZE,
            server_protocol.WEBSOCKET_MAX_SIZE,
        )
        self.assertTrue(
            issubclass(
                server_module.MeshRelayServer,
                server_transport.ServerTransportMixin,
            )
        )

    def test_transport_protocol_and_worker_modules_do_not_access_sql(self):
        for module in (
            server_command_bus,
            server_commands,
            server_commands_ai,
            server_commands_automation,
            server_commands_identity,
            server_commands_push,
            server_commands_subscriptions,
            server_commands_sync,
            server_connection,
            server_mutations,
            server_protocol,
            server_transport,
            server_workers,
        ):
            source = inspect.getsource(module).lower()
            self.assertNotIn(
                "self.db",
                source,
                f"{module.__name__}: direct database access",
            )
            sql_statement = re.search(
                r"(?im)^\s*(select|insert\s+into|update|delete\s+from|"
                r"create\s+table)\b",
                source,
            )
            self.assertIsNone(
                sql_statement,
                f"{module.__name__}: embedded SQL statement",
            )

    def test_entrypoint_is_a_composition_root(self):
        source = inspect.getsource(server_module.MeshRelayServer)
        self.assertNotIn("self.db.execute", source)
        self.assertLess(
            len(inspect.getsource(server_module.MeshRelayServer.handler).splitlines()),
            90,
        )

    def test_email_auth_uses_identity_repository(self):
        for module in (server_auth, server_email_auth):
            source = inspect.getsource(module).lower()
            self.assertNotIn("self.db", source)
            self.assertIsNone(
                re.search(
                    r"(?im)^\s*(select|insert\s+into|update|delete\s+from)\b",
                    source,
                ),
                module.__name__,
            )

    def test_subscription_service_uses_subscription_repository(self):
        for module in (server_subscription, server_boosty):
            source = inspect.getsource(module).lower()
            self.assertNotIn("self.db", source, module.__name__)
            self.assertIsNone(
                re.search(
                    r"(?im)^\s*(select|insert\s+into|update|delete\s+from)\b",
                    source,
                ),
                module.__name__,
            )

    def test_billing_service_uses_billing_repository(self):
        source = inspect.getsource(server_billing).lower()
        self.assertNotIn("self.db", source)
        self.assertIsNone(
            re.search(
                r"(?im)^\s*(select|insert\s+into|update|delete\s+from)\b",
                source,
            ),
        )

    def test_command_composition_keeps_protocol_surface_stable(self):
        commands = server_commands.build_command_registry()
        controls = server_commands.build_control_command_registry()

        self.assertEqual(27, len(commands.packet_types))
        self.assertEqual(8, len(controls.packet_types))
        self.assertLess(
            len(inspect.getsource(server_commands).splitlines()),
            100,
        )

    async def test_worker_supervisor_starts_and_stops_dependencies(self):
        relay = FakeRelay()
        supervisor = server_workers.ServerWorkerSupervisor(
            relay,
            billing_http_factory=FakeBillingHttpServer,
        )

        await supervisor.start()
        await asyncio.sleep(0)

        self.assertTrue(relay.boosty_started)
        self.assertTrue(supervisor.billing_started)
        self.assertEqual(1, relay.wireguard_runs)
        self.assertGreaterEqual(relay.schedule_runs, 1)

        await supervisor.stop()

        self.assertTrue(supervisor.stop_event.is_set())
        self.assertTrue(supervisor.billing_http.closed)
        self.assertTrue(relay.boosty_stopped)
        self.assertEqual([], supervisor._tasks)
