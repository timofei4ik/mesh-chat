import asyncio
import signal
import sqlite3

try:
    from server.config import (
        DATABASE_BACKEND,
        DATABASE_URL,
        DB_PATH,
        MEDIA_HTTP_HOST,
        MEDIA_HTTP_PORT,
    )
    from server.persistence import (
        PostgresCompatibilityConnection,
        connect_postgres,
    )
    from server.server_media import ServerMediaMixin
    from server.server_media_http import MediaHttpServer
except ModuleNotFoundError:
    from config import (
        DATABASE_BACKEND,
        DATABASE_URL,
        DB_PATH,
        MEDIA_HTTP_HOST,
        MEDIA_HTTP_PORT,
    )
    from persistence import (
        PostgresCompatibilityConnection,
        connect_postgres,
    )
    from server_media import ServerMediaMixin
    from server_media_http import MediaHttpServer


class MediaServiceRuntime(ServerMediaMixin):
    def __init__(self):
        self.db = self._open_catalog()
        self.initialize_media_delivery()

    @staticmethod
    def _open_catalog():
        if DATABASE_BACKEND == "postgres":
            if not DATABASE_URL:
                raise RuntimeError(
                    "MESH_DATABASE_URL is required for the media service"
                )
            return PostgresCompatibilityConnection(
                connect_postgres(DATABASE_URL)
            )
        if not DB_PATH.is_file():
            raise RuntimeError(f"media catalog does not exist: {DB_PATH}")
        return sqlite3.connect(
            f"{DB_PATH.resolve().as_uri()}?mode=ro",
            uri=True,
            check_same_thread=False,
        )

    def close(self):
        self.db.close()


async def run():
    runtime = MediaServiceRuntime()
    server = MediaHttpServer(runtime)
    stop_event = asyncio.Event()
    loop = asyncio.get_running_loop()
    for current_signal in (signal.SIGINT, signal.SIGTERM):
        try:
            loop.add_signal_handler(current_signal, stop_event.set)
        except NotImplementedError:
            pass
    try:
        await server.start()
        print(
            "Mesh media service listening on "
            f"http://{MEDIA_HTTP_HOST}:{MEDIA_HTTP_PORT}"
        )
        await stop_event.wait()
    finally:
        await server.close()
        runtime.close()


def main():
    asyncio.run(run())


if __name__ == "__main__":
    main()
