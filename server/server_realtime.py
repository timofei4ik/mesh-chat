"""Redis-backed presence and live packet delivery between relay workers."""

import asyncio
import json
import uuid

from server.reliable_delivery import RELIABLE_PACKET_TYPES
from server.reliable_sync import RELIABLE_SYNC_TYPES


_UNREGISTER_SCRIPT = """
if redis.call('HGET', KEYS[1], 'session_id') == ARGV[1] then
  redis.call('DEL', KEYS[1])
  if ARGV[2] ~= '' then
    redis.call('SREM', KEYS[2], ARGV[3])
  end
  return 1
end
return 0
"""

_REFRESH_SCRIPT = """
local owner = redis.call('HGET', KEYS[1], 'session_id')
if owner and owner ~= ARGV[1] then
  return 0
end
if not owner then
  local record = cjson.decode(ARGV[3])
  for field, value in pairs(record) do
    redis.call('HSET', KEYS[1], field, value)
  end
end
redis.call('EXPIRE', KEYS[1], ARGV[2])
if ARGV[4] ~= '' then
  redis.call('SADD', KEYS[2], ARGV[5])
  redis.call('EXPIRE', KEYS[2], tonumber(ARGV[2]) * 4)
end
return 1
"""


class RealtimeCoordinator:
    def __init__(
        self,
        server,
        redis_url="",
        prefix="meshchat",
        worker_id="worker-0",
        presence_ttl=45,
        heartbeat_interval=15,
    ):
        self.server = server
        self.redis_url = str(redis_url or "").strip()
        self.prefix = str(prefix or "meshchat").strip()
        self.worker_id = str(worker_id or "worker-0").strip()
        self.presence_ttl = int(presence_ttl)
        self.heartbeat_interval = int(heartbeat_interval)
        self.redis = None
        self.pubsub = None
        self._listener_task = None
        self._heartbeat_task = None
        self._delivery_task = None
        self._lag_task = None
        self._closing = False
        self._local_sessions = {}
        self._local_presence = {}
        self._presence_lock = asyncio.Lock()
        self._last_error = ""
        self._sync_retries = {}
        self._hint_tasks = {}
        self._last_queue_cleanup = 0

    @property
    def enabled(self):
        return bool(self.redis_url)

    def _presence_key(self, node_id, kind="client"):
        return f"{self.prefix}:presence:{kind}:{node_id}"

    def _account_key(self, login, kind="client"):
        return f"{self.prefix}:account:{kind}:{login}:nodes"

    def _worker_channel(self, worker_id=None):
        return f"{self.prefix}:worker:{worker_id or self.worker_id}"

    def _worker_key(self):
        return f"{self.prefix}:worker:heartbeat:{self.worker_id}"

    def _operation_key(self, namespace, operation_id):
        return f"{self.prefix}:operation:{namespace}:{operation_id}"

    async def start(self):
        self._closing = False
        if not self.enabled:
            self._start_delivery_loop()
            return
        try:
            from server.redis_client import (
                create_async_redis,
                warm_async_redis,
            )
            self.redis = create_async_redis(self.redis_url)
        except ImportError as error:
            raise RuntimeError(
                "MESH_REDIS_URL is configured but the redis package is missing"
            ) from error
        await warm_async_redis(self.redis, 32)
        await self.redis.ping()
        await self.redis.set(
            self._worker_key(),
            str(asyncio.get_running_loop().time()),
            ex=self.presence_ttl,
        )
        await self._open_pubsub()
        self._listener_task = asyncio.create_task(
            self._listen(),
            name=f"realtime-listener:{self.worker_id}",
        )
        self._heartbeat_task = asyncio.create_task(
            self._heartbeat(),
            name=f"realtime-heartbeat:{self.worker_id}",
        )
        self._start_delivery_loop()

    def _start_delivery_loop(self):
        if getattr(self.server, "runtime_metrics", None) is not None:
            self._lag_task = asyncio.create_task(self._measure_loop_lag())
            self._delivery_task = asyncio.create_task(
                self._retry_deliveries(), name=f"realtime-delivery:{self.worker_id}"
            )

    async def stop(self):
        self._closing = True
        hint_tasks = [entry[2] for entry in self._hint_tasks.values()]
        for task in hint_tasks:
            task.cancel()
        await asyncio.gather(*hint_tasks, return_exceptions=True)
        self._hint_tasks.clear()
        sessions = list(self._local_sessions.items())
        for (kind, node_id), session_id in sessions:
            await self.unregister(node_id, session_id, kind=kind)
        tasks = (self._listener_task, self._heartbeat_task, self._delivery_task, self._lag_task)
        for task in tasks:
            if task is not None:
                task.cancel()
        await asyncio.gather(
            *(
                task
                for task in tasks
                if task is not None
            ),
            return_exceptions=True,
        )
        if self.pubsub is not None:
            await self.pubsub.aclose()
        if self.redis is not None:
            await self.redis.delete(self._worker_key())
            await self.redis.aclose()
        self.pubsub = None
        self.redis = None

    async def register(
        self, node_id, login="", username="", capabilities=None,
        kind="client", service="",
    ):
        async with self._presence_lock:
            return await self._register(
                node_id, login, username, capabilities, kind, service,
            )

    async def _register(
        self,
        node_id,
        login="",
        username="",
        capabilities=None,
        kind="client",
        service="",
    ):
        session_id = str(uuid.uuid4())
        local_key = (kind, node_id)
        self._local_sessions[local_key] = session_id
        if not self.enabled or self.redis is None:
            return session_id

        key = self._presence_key(node_id, kind)
        login = str(login or "").strip().lower()
        account_key = self._account_key(login, kind) if login else ""
        previous = await self.redis.hgetall(key)
        payload = {
            "node_id": str(node_id),
            "worker_id": self.worker_id,
            "session_id": session_id,
            "login": str(login or "").strip().lower(),
            "username": str(username or node_id),
            "kind": kind,
            "service": str(service or ""),
            "capabilities": json.dumps(
                capabilities or {},
                separators=(",", ":"),
            ),
        }
        pipeline = self.redis.pipeline(transaction=True)
        pipeline.hset(key, mapping=payload)
        pipeline.expire(key, self.presence_ttl)
        if account_key:
            pipeline.sadd(account_key, str(node_id))
            pipeline.expire(account_key, self.presence_ttl * 4)
        await pipeline.execute()
        self._local_presence[local_key] = payload

        previous_worker = previous.get("worker_id")
        previous_session = previous.get("session_id")
        if (
            previous_worker
            and previous_session
            and previous_session != session_id
        ):
            await self._publish(
                previous_worker,
                {
                    "action": "close",
                    "node_id": str(node_id),
                    "kind": kind,
                    "session_id": previous_session,
                    "code": 4002,
                    "reason": "connection was replaced",
                },
            )
        return session_id

    async def unregister(self, node_id, session_id, kind="client"):
        async with self._presence_lock:
            return await self._unregister(node_id, session_id, kind)

    async def _unregister(self, node_id, session_id, kind="client"):
        local_key = (kind, node_id)
        if self._local_sessions.get(local_key) == session_id:
            self._local_sessions.pop(local_key, None)
            self._local_presence.pop(local_key, None)
            self._sync_retries.pop(node_id, None)
            pending = self._hint_tasks.get(node_id)
            if pending is not None and pending[0] == session_id:
                self._hint_tasks.pop(node_id, None)
                pending[2].cancel()
        if not self.enabled or self.redis is None or not session_id:
            return True

        key = self._presence_key(node_id, kind)
        try:
            login = await self.redis.hget(key, "login") or ""
            account_key = self._account_key(login, kind) if login else key
            removed = await self.redis.eval(
                _UNREGISTER_SCRIPT,
                2,
                key,
                account_key,
                session_id,
                login,
                str(node_id),
            )
            return bool(removed)
        except Exception as error:
            self._report_error("unregister", error)
            return False

    async def send_to_node(
        self,
        node_id,
        packet,
        required_capability=None,
        kind="client",
    ):
        socket_map = (
            self.server.service_clients
            if kind == "service"
            else self.server.clients
        )
        websocket = socket_map.get(node_id)
        if websocket is not None:
            if not self._local_capability_allowed(
                node_id,
                required_capability,
                kind,
            ):
                return False
            if (kind == "client" and packet.get("type") in RELIABLE_SYNC_TYPES
                    and getattr(self.server, "sync_delivery_queue", None) is not None
                    and self._local_capability_allowed(node_id, "reliable_sync_v2", kind)):
                self._schedule_sync_hint(node_id, websocket, force=True)
                return True
            delivery_id = self._queue_delivery(
                node_id, getattr(self.server, "client_logins", {}).get(node_id, ""), packet,
                required_capability, kind,
                self._local_capability_allowed(node_id, "reliable_delivery_v1", kind),
            )
            if delivery_id:
                await self._deliver_pending(node_id, websocket)
                return True
            try:
                await websocket.send(json.dumps(packet, ensure_ascii=False))
                return True
            except Exception:
                return False

        if not self.enabled or self.redis is None:
            return False
        try:
            presence = await self.redis.hgetall(
                self._presence_key(node_id, kind)
            )
        except Exception as error:
            self._report_error("presence lookup", error)
            return False
        if not presence:
            return False
        if not self._remote_capability_allowed(
            presence,
            required_capability,
        ):
            return False
        delivery_id = self._queue_delivery(
            node_id, presence.get("login", ""), packet, required_capability, kind,
            self._remote_capability_allowed(presence, "reliable_delivery_v1"),
        )
        sync_ready = (
            kind == "client" and packet.get("type") in RELIABLE_SYNC_TYPES
            and getattr(self.server, "sync_delivery_queue", None) is not None
            and self._remote_capability_allowed(presence, "reliable_sync_v2")
        )
        subscribers = await self._publish(
            presence.get("worker_id"),
            {
                "action": "sync_ready" if sync_ready else "delivery_ready" if delivery_id else "deliver",
                "node_id": str(node_id),
                "kind": kind,
                "session_id": presence.get("session_id"),
                "required_capability": required_capability or "",
                "packet": None if sync_ready or delivery_id else packet,
            },
        )
        return bool(sync_ready or delivery_id or subscribers)

    def _queue_delivery(self, node_id, login, packet, required, kind, supported):
        outbox = getattr(self.server, "delivery_outbox", None)
        if (outbox is None or not login or kind != "client" or not supported
                or packet.get("type") not in RELIABLE_PACKET_TYPES):
            return None
        delivery_id = outbox.enqueue(node_id, login, packet, required)
        self.server.runtime_metrics.increment("delivery_enqueued_total")
        return delivery_id

    async def _deliver_pending(self, node_id, websocket):
        outbox = getattr(self.server, "delivery_outbox", None)
        login = self.server.client_logins.get(node_id, "")
        if (outbox is None or not login or not self._local_capability_allowed(
                node_id, "reliable_delivery_v1", "client")):
            return
        # Check ownership before retrying: a replaced worker must not keep
        # sending to the previous authenticated connection.
        if self.redis is not None:
            owner = await self.redis.hget(self._presence_key(node_id), "session_id")
            if owner != self._local_sessions.get(("client", node_id)):
                return
        for delivery_id, encoded, required, _ in outbox.pending(node_id, login):
            if (self.server.clients.get(node_id) is not websocket
                    or self.server.client_logins.get(node_id) != login):
                return
            if not self._local_capability_allowed(node_id, required, "client"):
                continue
            if not outbox.claim(delivery_id):
                continue
            self.server.runtime_metrics.increment("delivery_attempts_total")
            try:
                payload = json.loads(encoded)
                payload["_delivery_id"] = delivery_id
                await asyncio.wait_for(websocket.send(
                    json.dumps(payload, ensure_ascii=False)), timeout=5)
            except Exception:
                self.server.runtime_metrics.increment("delivery_send_errors_total")
                return

    async def _retry_deliveries(self):
        while not self._closing:
            await asyncio.sleep(1)
            queue = getattr(self.server, "sync_delivery_queue", None)
            if queue is not None:
                now = asyncio.get_running_loop().time()
                if now - self._last_queue_cleanup >= 60:
                    try:
                        with self.server.atomic_storage_transaction():
                            queue.prune()
                        self._last_queue_cleanup = now
                    except Exception as error:
                        self._report_error("queue cleanup", error)
            if getattr(self.server, "delivery_outbox", None) is None and queue is None:
                continue
            async def attempt(node_id, websocket):
                try:
                    if queue is not None:
                        await self._send_sync_hint(node_id, websocket)
                    else:
                        await self._deliver_pending(node_id, websocket)
                except Exception as error:
                    self._report_error("delivery retry", error)
            clients = list(self.server.clients.items())
            if queue is not None:
                for node_id, websocket in clients:
                    self._schedule_sync_hint(node_id, websocket)
                continue
            for offset in range(0, len(clients), 8):
                await asyncio.gather(*(attempt(*client) for client in clients[offset:offset + 8]))

    def _schedule_sync_hint(self, node_id, websocket, force=False):
        if self._closing:
            return
        session = self._local_sessions.get(("client", node_id))
        previous = self._hint_tasks.get(node_id)
        if previous is not None:
            if previous[0] == session and previous[1] is websocket and not previous[2].done():
                previous[3] = previous[3] or force
                return
            previous[2].cancel()

        # At most one bounded send per connected device. SQL checkpoints retain
        # missed work, so PubSub never needs to wait for a slow socket to drain.
        async def send():
            try:
                await self._send_sync_hint(node_id, websocket, force=self._hint_tasks[node_id][3])
            except asyncio.CancelledError:
                raise
            except Exception as error:
                self._report_error("sync hint", error)
            finally:
                current = self._hint_tasks.get(node_id)
                if current is not None and current[2] is asyncio.current_task():
                    self._hint_tasks.pop(node_id, None)
        task = asyncio.create_task(send(), name="sync-hint:" + node_id)
        self._hint_tasks[node_id] = [session, websocket, task, force]

    async def _send_sync_hint(self, node_id, websocket, force=False):
        queue = getattr(self.server, "sync_delivery_queue", None)
        if queue is None or not self._local_capability_allowed(node_id, "reliable_sync_v2", "client"):
            return
        login = self.server.client_logins.get(node_id, "")
        if not login:
            return
        session = self._local_sessions.get(("client", node_id))
        now = asyncio.get_running_loop().time()
        previous_session, due, attempts = self._sync_retries.get(node_id, (None, 0, 0))
        if previous_session == session and now < due and not force:
            return
        if previous_session != session:
            attempts = 0
        if self.redis is not None:
            owner = await self.redis.hget(self._presence_key(node_id), "session_id")
            if owner != session:
                return
        if self.server.clients.get(node_id) is not websocket:
            return
        cursor = queue.pending_cursor(login, node_id)
        delay = min(30, 2 ** min(attempts + 1, 5)) if cursor else 2
        self._sync_retries[node_id] = (session, now + delay, attempts + 1 if cursor else 0)
        if not cursor:
            return
        try:
            await asyncio.wait_for(websocket.send(json.dumps({
                "type": "reliable_sync_hint", "cursor": cursor,
            })), timeout=5)
            self.server.runtime_metrics.increment("delivery_attempts_total")
        except Exception:
            self.server.runtime_metrics.increment("delivery_send_errors_total")

    async def _measure_loop_lag(self):
        loop = asyncio.get_running_loop()
        while not self._closing:
            expected = loop.time() + 1
            await asyncio.sleep(1)
            self.server.runtime_metrics.event_loop_lag = max(0, loop.time() - expected)

    async def close_node(
        self,
        node_id,
        code=1000,
        reason="",
        packet=None,
        kind="client",
    ):
        socket_map = (
            self.server.service_clients
            if kind == "service"
            else self.server.clients
        )
        websocket = socket_map.get(node_id)
        if websocket is not None:
            try:
                if packet is not None:
                    await websocket.send(json.dumps(packet, ensure_ascii=False))
                await websocket.close(code=code, reason=reason)
                return True
            except Exception:
                return False
        if not self.enabled or self.redis is None:
            return False
        try:
            presence = await self.redis.hgetall(
                self._presence_key(node_id, kind)
            )
        except Exception as error:
            self._report_error("close lookup", error)
            return False
        if not presence:
            return False
        return bool(
            await self._publish(
                presence.get("worker_id"),
                {
                    "action": "close",
                    "node_id": str(node_id),
                    "kind": kind,
                    "session_id": presence.get("session_id"),
                    "code": int(code),
                    "reason": str(reason or ""),
                    "packet": packet,
                },
            )
        )

    async def account_nodes(self, login, kind="client"):
        normalized = str(login or "").strip().lower()
        if not normalized:
            return []
        if not self.enabled or self.redis is None:
            return []
        account_key = self._account_key(normalized, kind)
        try:
            members = list(await self.redis.smembers(account_key))
        except Exception as error:
            self._report_error("account presence lookup", error)
            return []
        if not members:
            return []
        pipeline = self.redis.pipeline(transaction=False)
        for node_id in members:
            pipeline.hgetall(self._presence_key(node_id, kind))
        try:
            records = await pipeline.execute()
        except Exception as error:
            self._report_error("account presence pipeline", error)
            return []
        online = []
        stale = []
        for node_id, record in zip(members, records):
            if (
                record
                and record.get("login") == normalized
                and record.get("kind") == kind
            ):
                online.append(node_id)
            else:
                stale.append(node_id)
        if stale:
            try:
                await self.redis.srem(account_key, *stale)
            except Exception as error:
                self._report_error("stale presence cleanup", error)
        return online

    async def presence_users(self):
        if not self.enabled or self.redis is None:
            return []
        records = []
        pattern = self._presence_key("*", "client")
        try:
            async for key in self.redis.scan_iter(match=pattern, count=200):
                record = await self.redis.hgetall(key)
                if record:
                    records.append(record)
            return records
        except Exception as error:
            self._report_error("presence scan", error)
            return [
                {
                    "node_id": node_id,
                    "username": username,
                    "login": self.server.client_logins.get(node_id, ""),
                }
                for node_id, username in list(
                    self.server.client_names.items()
                )
            ]

    async def claim_operation(self, namespace, operation_id, ttl_seconds=300):
        if not operation_id:
            return True
        if not self.enabled or self.redis is None:
            return None
        try:
            return bool(
                await self.redis.set(
                    self._operation_key(namespace, operation_id),
                    self.worker_id,
                    nx=True,
                    ex=max(1, int(ttl_seconds)),
                )
            )
        except Exception as error:
            self._report_error("operation claim", error)
            return None

    async def _publish(self, worker_id, envelope):
        if not worker_id or self.redis is None:
            return 0
        try:
            return await self.redis.publish(
                self._worker_channel(worker_id),
                json.dumps(envelope, ensure_ascii=False),
            )
        except Exception as error:
            self._report_error("publish", error)
            return 0

    def _local_capability_allowed(
        self,
        node_id,
        required_capability,
        kind,
    ):
        if not required_capability or kind == "service":
            return True
        return bool(
            self.server.client_capabilities.get(node_id, {}).get(
                required_capability,
                False,
            )
        )

    @staticmethod
    def _remote_capability_allowed(presence, required_capability):
        if not required_capability:
            return True
        try:
            capabilities = json.loads(presence.get("capabilities") or "{}")
        except (TypeError, ValueError):
            return False
        return bool(capabilities.get(required_capability, False))

    async def _listen(self):
        while not self._closing:
            try:
                if self.pubsub is None:
                    await self._open_pubsub()
                async for message in self.pubsub.listen():
                    if message.get("type") != "message":
                        continue
                    try:
                        envelope = json.loads(message.get("data") or "{}")
                        await self._handle_envelope(envelope)
                    except Exception as error:
                        self._report_error("envelope", error)
            except asyncio.CancelledError:
                raise
            except Exception as error:
                self._report_error("listener reconnect", error)
                if self.pubsub is not None:
                    try:
                        await self.pubsub.aclose()
                    except Exception:
                        pass
                self.pubsub = None
                await asyncio.sleep(1)

    async def _handle_envelope(self, envelope):
        action = str(envelope.get("action") or "")
        kind = str(envelope.get("kind") or "client")
        node_id = str(envelope.get("node_id") or "")
        session_id = str(envelope.get("session_id") or "")
        if self._local_sessions.get((kind, node_id)) != session_id:
            return
        socket_map = (
            self.server.service_clients
            if kind == "service"
            else self.server.clients
        )
        websocket = socket_map.get(node_id)
        if websocket is None:
            return
        if action == "sync_ready" and kind == "client":
            self._schedule_sync_hint(node_id, websocket, force=True)
        elif action == "delivery_ready" and kind == "client":
            await self._deliver_pending(node_id, websocket)
        elif action == "deliver":
            required = str(envelope.get("required_capability") or "")
            if not self._local_capability_allowed(node_id, required, kind):
                return
            await websocket.send(
                json.dumps(envelope.get("packet") or {}, ensure_ascii=False)
            )
        elif action == "close":
            packet = envelope.get("packet")
            if packet is not None:
                await websocket.send(json.dumps(packet, ensure_ascii=False))
            await websocket.close(
                code=int(envelope.get("code") or 1000),
                reason=str(envelope.get("reason") or ""),
            )

    async def _heartbeat(self):
        while True:
            await asyncio.sleep(self.heartbeat_interval)
            if self.redis is None:
                continue
            try:
                await self._refresh_heartbeat()
            except Exception as error:
                self._report_error("heartbeat", error)

    async def _refresh_heartbeat(self):
        # Serialize restoration with local registration/disconnect, so a delayed
        # heartbeat cannot resurrect a socket that has already signed out.
        async with self._presence_lock:
            stale = await self._refresh_presence()
        for kind, node_id, session_id, websocket in stale:
            socket_map = self.server.service_clients if kind == "service" else self.server.clients
            if (self._local_sessions.get((kind, node_id)) == session_id
                    and socket_map.get(node_id) is websocket):
                await asyncio.wait_for(websocket.close(
                    code=4002, reason="connection was replaced"), timeout=5)

    async def _refresh_presence(self):
        sessions = list(self._local_sessions.items())
        pipeline = self.redis.pipeline(transaction=False)
        pipeline.set(
            self._worker_key(),
            str(asyncio.get_running_loop().time()),
            ex=self.presence_ttl,
        )
        metrics = getattr(self.server, "runtime_metrics", None)
        if metrics is not None:
            values = metrics.snapshot()
            values.update(delivery_queue_depth=0, delivery_oldest_seconds=0,
                          delivery_intent_accounts=0, delivery_intent_oldest_seconds=0)
            outbox = getattr(self.server, "delivery_outbox", None)
            outbox = getattr(self.server, "sync_delivery_queue", None) or outbox
            if outbox is not None:
                values.update(outbox.stats())
            else:
                values.update(delivery_queue_depth=0, delivery_oldest_seconds=0)
            key = f"{self.prefix}:worker:metrics:{self.worker_id}"
            pipeline.hset(key, mapping=values)
            pipeline.expire(key, self.presence_ttl)
        refreshed = []
        for (kind, node_id), session_id in sessions:
            payload = self._local_presence.get((kind, node_id))
            socket_map = self.server.service_clients if kind == "service" else self.server.clients
            websocket = socket_map.get(node_id)
            if payload is None or payload["session_id"] != session_id or websocket is None:
                continue
            login = payload["login"]
            refreshed.append((kind, node_id, session_id, websocket))
            pipeline.eval(
                _REFRESH_SCRIPT,
                2,
                self._presence_key(node_id, kind),
                self._account_key(login, kind),
                session_id,
                self.presence_ttl,
                json.dumps(payload, separators=(",", ":")),
                login,
                str(node_id),
            )
        results = await pipeline.execute()
        stale = []
        if refreshed:
            for record, owned in zip(refreshed, results[-len(refreshed):]):
                if not owned:
                    kind, node_id, _, _ = record
                    self._local_presence.pop((kind, node_id), None)
                    stale.append(record)
        return stale

    async def _open_pubsub(self):
        self.pubsub = self.redis.pubsub(
            ignore_subscribe_messages=True,
        )
        await self.pubsub.subscribe(self._worker_channel())

    def _report_error(self, operation, error):
        signature = f"{operation}:{type(error).__name__}:{error}"
        if signature == self._last_error:
            return
        self._last_error = signature
        print(
            f"Realtime {operation} failed on {self.worker_id}:",
            error,
        )


class ServerRealtimeMixin:
    def initialize_realtime(
        self,
        redis_url="",
        prefix="meshchat",
        worker_id="worker-0",
        presence_ttl=45,
        heartbeat_interval=15,
    ):
        self.realtime = RealtimeCoordinator(
            self,
            redis_url=redis_url,
            prefix=prefix,
            worker_id=worker_id,
            presence_ttl=presence_ttl,
            heartbeat_interval=heartbeat_interval,
        )

    async def start_realtime(self):
        await self.realtime.start()

    async def stop_realtime(self):
        await self.realtime.stop()

    async def register_realtime_connection(
        self,
        node_id,
        login="",
        username="",
        capabilities=None,
        kind="client",
        service="",
    ):
        socket_map = (
            self.service_clients if kind == "service" else self.clients
        )
        previous = socket_map.get(node_id)
        if previous is not None:
            try:
                await previous.close(
                    code=4002,
                    reason="connection was replaced",
                )
            except Exception:
                pass
        return await self.realtime.register(
            node_id,
            login=login,
            username=username,
            capabilities=capabilities,
            kind=kind,
            service=service,
        )

    async def unregister_realtime_connection(
        self,
        node_id,
        session_id,
        kind="client",
    ):
        return await self.realtime.unregister(
            node_id,
            session_id,
            kind=kind,
        )

    async def send_packet_to_node(
        self,
        node_id,
        packet,
        required_capability=None,
        kind="client",
    ):
        return await self.realtime.send_to_node(
            node_id,
            packet,
            required_capability=required_capability,
            kind=kind,
        )

    async def close_realtime_node(
        self,
        node_id,
        code=1000,
        reason="",
        packet=None,
        kind="client",
    ):
        return await self.realtime.close_node(
            node_id,
            code=code,
            reason=reason,
            packet=packet,
            kind=kind,
        )

    async def get_realtime_account_nodes(self, login, kind="client"):
        if self.realtime.enabled:
            return await self.realtime.account_nodes(login, kind=kind)
        if kind == "service":
            normalized = str(login or "").strip().lower()
            return [
                node_id
                for node_id, current in self.service_logins.items()
                if current == normalized
            ]
        return list(self.get_online_account_nodes(login))

    async def get_realtime_presence_users(self):
        if self.realtime.enabled:
            return await self.realtime.presence_users()
        return [
            {
                "node_id": node_id,
                "username": username,
                "login": self.client_logins.get(node_id, ""),
            }
            for node_id, username in list(self.client_names.items())
        ]

    async def claim_realtime_operation(
        self,
        namespace,
        operation_id,
        ttl_seconds=300,
    ):
        return await self.realtime.claim_operation(
            namespace,
            operation_id,
            ttl_seconds=ttl_seconds,
        )
