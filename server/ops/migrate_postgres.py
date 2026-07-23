import argparse
import os
import sys
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[2]
if str(PROJECT_ROOT) not in sys.path:
    sys.path.insert(0, str(PROJECT_ROOT))

from server.persistence.postgres import (  # noqa: E402
    apply_postgres_migrations,
    connect_postgres,
)


def main():
    parser = argparse.ArgumentParser(
        description="Apply ordered MeshChat PostgreSQL migrations.",
    )
    parser.add_argument(
        "--database-url",
        default=os.environ.get("MESH_DATABASE_URL", "").strip(),
        help="PostgreSQL URL; defaults to MESH_DATABASE_URL.",
    )
    arguments = parser.parse_args()
    if not arguments.database_url:
        parser.error(
            "--database-url or MESH_DATABASE_URL is required",
        )

    connection = connect_postgres(arguments.database_url)
    try:
        apply_postgres_migrations(connection)
    finally:
        connection.close()
    print("PostgreSQL migrations applied successfully.")


if __name__ == "__main__":
    main()
