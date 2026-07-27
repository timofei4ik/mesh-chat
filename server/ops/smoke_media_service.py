from __future__ import annotations

import argparse
import json
import urllib.request
from urllib.parse import quote

from server.media_service import MediaServiceRuntime


def _candidate(runtime):
    return runtime.db.execute(
        """
        SELECT file_id,
               COALESCE(
                   NULLIF(sender_login, ''),
                   NULLIF(receiver_login, '')
               )
        FROM server_files
        WHERE (
                COALESCE(storage_path, '')!=''
                OR COALESCE(data, '')!=''
              )
          AND (
                COALESCE(sender_login, '')!=''
                OR COALESCE(receiver_login, '')!=''
              )
        ORDER BY created_at DESC
        LIMIT 1
        """
    ).fetchone()


def run(base_url):
    runtime = MediaServiceRuntime()
    try:
        candidate = _candidate(runtime)
        if not candidate:
            raise RuntimeError("no downloadable media candidate")
        file_id, login = (str(candidate[0]), str(candidate[1]))
        issued = runtime.issue_media_download(login, file_id)
        if not issued:
            raise RuntimeError("media token was not issued")
        expected_size = int(issued["size_bytes"] or 0)
        if expected_size <= 0:
            raise RuntimeError("media candidate is empty")
        end = min(31, expected_size - 1)
        url = f"{base_url.rstrip('/')}/{quote(file_id, safe='')}"
        request = urllib.request.Request(
            url,
            headers={
                "Authorization": f'Bearer {issued["download_token"]}',
                "Range": f"bytes=0-{end}",
                "User-Agent": "mesh-media-smoke/1",
            },
        )
        with urllib.request.urlopen(request, timeout=10) as response:
            payload = response.read()
            status = int(response.status)

        object_path = runtime.media_object_storage.resolve(
            issued["storage_path"],
            issued["media_id"],
        )
        if object_path:
            with object_path.open("rb") as source:
                expected = source.read(end + 1)
        else:
            expected = bytes.fromhex(issued["inline_hex"])[: end + 1]
        if status != 206 or payload != expected:
            raise RuntimeError("downloaded range does not match media object")
        return {
            "ok": True,
            "file_id": file_id,
            "status": status,
            "range_bytes": len(payload),
            "size_bytes": expected_size,
        }
    finally:
        runtime.close()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--base-url",
        default="http://127.0.0.1:8777/media/v2",
    )
    args = parser.parse_args()
    print(
        json.dumps(
            run(args.base_url),
            ensure_ascii=True,
            sort_keys=True,
        )
    )


if __name__ == "__main__":
    main()
