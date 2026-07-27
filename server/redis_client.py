"""Bounded asynchronous Redis clients for burst-safe server coordination."""

from __future__ import annotations

import os


def create_async_redis(
    redis_url,
    *,
    max_connections=None,
    decode_responses=True,
):
    import redis.asyncio as redis_async

    connection_limit = max(
        8,
        int(
            max_connections
            or os.environ.get("MESH_REDIS_MAX_CONNECTIONS", "32")
        ),
    )
    pool_timeout = max(
        1.0,
        float(os.environ.get("MESH_REDIS_POOL_TIMEOUT_SECONDS", "30")),
    )
    socket_timeout = max(
        1.0,
        float(os.environ.get("MESH_REDIS_SOCKET_TIMEOUT_SECONDS", "10")),
    )
    pool = redis_async.BlockingConnectionPool.from_url(
        redis_url,
        decode_responses=decode_responses,
        health_check_interval=15,
        socket_connect_timeout=5,
        socket_timeout=socket_timeout,
        max_connections=connection_limit,
        timeout=pool_timeout,
    )
    return redis_async.Redis(connection_pool=pool)


async def warm_async_redis(client, connection_count):
    """Open the bounded pool before request traffic reaches the event loop."""
    pool = client.connection_pool
    connections = []
    try:
        for _ in range(max(1, int(connection_count))):
            connections.append(await pool.get_connection())
    finally:
        for connection in connections:
            await pool.release(connection)
