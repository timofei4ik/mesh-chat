"""Local SQL queue probe, not a capacity estimate for the full messenger."""
import argparse
import json
import os
import time
import uuid
from concurrent.futures import ThreadPoolExecutor
from urllib.parse import urlparse

from server.persistence.postgres import connect_postgres, PostgresCompatibilityConnection
from server.reliable_delivery import DeliveryOutbox


def validate_url(url):
    parsed = urlparse(url)
    if (parsed.scheme not in {"postgresql", "postgres"}
            or parsed.hostname not in {"127.0.0.1", "localhost"}
            or not parsed.path.startswith("/meshchat_reliability_test")):
        raise ValueError("Only a loopback meshchat_reliability_test database is allowed")


def run(url, count):
    validate_url(url)
    connections = [PostgresCompatibilityConnection(connect_postgres(url)) for _ in range(3)]
    samples = []
    login = f"lab-{uuid.uuid4()}"
    try:
        queues = [DeliveryOutbox(connection) for connection in connections]
        # Each consumer has its own connection, like independent relay workers.
        with ThreadPoolExecutor(max_workers=2) as pool:
            for number in range(count):
                started = time.perf_counter()
                delivery = queues[0].enqueue("lab-phone", login, {
                    "type": "chat_message", "message_id": str(number), "message": "x" * 256,
                })
                claims = list(pool.map(lambda queue: queue.claim(delivery), queues[1:]))
                if sum(claims) != 1:
                    raise AssertionError("Concurrent consumers did not claim exactly once")
                if queues[0].acknowledge("lab-phone", "wrong-account", delivery) is not None:
                    raise AssertionError("Foreign account acknowledged a delivery")
                if queues[0].acknowledge("lab-phone", login, delivery) is None:
                    raise AssertionError("Authenticated acknowledgement missing")
                samples.append((time.perf_counter() - started) * 1000)
        values = sorted(samples)
        return {
            "scope": "local SQL enqueue / two concurrent claims / authenticated ACK",
            "messages": count,
            "claim_conflicts_or_lost_acks": 0,
            "p50_ms": round(values[int((count - 1) * .5)], 2),
            "p95_ms": round(values[int((count - 1) * .95)], 2),
            "max_ms": round(values[-1], 2),
        }
    finally:
        connections[0].execute("DELETE FROM realtime_delivery_outbox WHERE account_login=?", (login,))
        for connection in connections:
            connection.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--messages", type=int, default=200)
    args = parser.parse_args()
    if not 1 <= args.messages <= 10000:
        parser.error("messages must be between 1 and 10000")
    result = run(os.environ.get("MESH_TEST_DATABASE_URL", ""), args.messages)
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
