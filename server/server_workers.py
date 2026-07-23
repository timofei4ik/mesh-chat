import asyncio

try:
    from server.server_billing_http import BillingHttpServer
except ModuleNotFoundError:
    from server_billing_http import BillingHttpServer


class ServerWorkerSupervisor:
    def __init__(self, relay, billing_http_factory=BillingHttpServer):
        self.relay = relay
        self.stop_event = asyncio.Event()
        self.billing_http = billing_http_factory(relay)
        self.boosty_started = False
        self.billing_started = False
        self._tasks = []

    async def start(self):
        self.boosty_started = await self.relay.start_boosty_bridge()
        self.billing_started = await self.billing_http.start()
        try:
            stats = self.relay.reconcile_wireguard_peers()
            print(f"WireGuard peer reconcile: {stats}")
        except Exception as error:
            print(f"WireGuard peer reconcile failed: {error}")

        self._tasks = [
            asyncio.create_task(
                self._wireguard_maintenance(),
                name="wireguard-maintenance",
            ),
            asyncio.create_task(
                self._scheduled_message_maintenance(),
                name="scheduled-message-maintenance",
            ),
        ]

    async def stop(self):
        self.stop_event.set()
        for task in self._tasks:
            task.cancel()
        await asyncio.gather(*self._tasks, return_exceptions=True)
        self._tasks.clear()
        await self.billing_http.close()
        await self.relay.stop_boosty_bridge()

    async def _wireguard_maintenance(self):
        while not self.stop_event.is_set():
            try:
                await asyncio.wait_for(self.stop_event.wait(), timeout=60)
            except asyncio.TimeoutError:
                try:
                    self.relay.reconcile_wireguard_peers()
                except Exception as error:
                    print("WireGuard maintenance failed:", error)

    async def _scheduled_message_maintenance(self):
        while not self.stop_event.is_set():
            try:
                await self.relay.dispatch_due_scheduled_messages()
            except Exception as error:
                print("Scheduled message maintenance failed:", error)
            try:
                await asyncio.wait_for(self.stop_event.wait(), timeout=1)
            except asyncio.TimeoutError:
                pass
