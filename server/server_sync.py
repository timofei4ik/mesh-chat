import json

import websockets

SERVER_FILE_SYNC_CHUNK_SIZE = 256 * 1024


class ServerSyncMixin:
    def build_sync_packet(
        self,
        login,
        node_id
    ):

        cursor = self.db.cursor()

        cursor.execute(
            """
            SELECT login,
                   node_id,
                   display_name,
                   public_username,
                   about,
                   avatar_data,
                   encryption_public_key
            FROM accounts
            WHERE login=?
               OR node_id=?
            ORDER BY CASE WHEN node_id=? THEN 0 ELSE 1 END
            LIMIT 1
            """,
            (
                login,
                node_id,
                node_id
            )
        )

        own_profile = None
        row = cursor.fetchone()

        if row:

            own_profile = {
                "login": row[0],
                "node_id": row[1],
                "display_name": row[2],
                "public_username": row[3],
                "about": row[4],
                "avatar_data": row[5]
                ,"encryption_public_key": row[6]
            }

        cursor.execute(
            """
            SELECT message_id,
                   sender_node,
                   sender_login,
                   sender_name,
                   receiver_node,
                   receiver_login,
                   message,
                   reply_to_message_id,
                   reply_to_text,
                   created_at
            FROM direct_messages
            WHERE sender_login=?
               OR receiver_login=?
               OR sender_node=?
               OR receiver_node=?
            ORDER BY id
            """.replace(
                "ORDER BY id",
                "ORDER BY created_at"
            ),
            (
                login,
                login,
                node_id,
                node_id
            )
        )

        direct_messages = [
            {
                "message_id": row[0],
                "sender_node": row[1],
                "sender_login": row[2],
                "sender_name": row[3],
                "receiver_node": row[4],
                "receiver_login": row[5],
                "message": row[6],
                "reply_to_message_id": row[7],
                "reply_to_text": row[8],
                "created_at": row[9]
            }
            for row in cursor.fetchall()
        ]

        cursor.execute(
            """
            SELECT DISTINCT g.group_id,
                            g.group_name,
                            g.members_json,
                            g.owner_node,
                            g.admins_json,
                            COALESCE(g.is_channel, 0),
                            COALESCE(g.group_about, ''),
                            COALESCE(g.group_avatar_data, '')
            FROM server_groups g
            JOIN server_group_members m
              ON m.group_id = g.group_id
            WHERE m.login=?
               OR m.node_id=?
            """,
            (
                login,
                node_id
            )
        )

        groups = [
            {
                "group_id": row[0],
                "group_name": row[1],
                "members": json.loads(
                    row[2] or "[]"
                ),
                "owner_node": row[3],
                "admins": json.loads(
                    row[4] or "[]"
                ),
                "is_channel": bool(row[5]),
                "group_about": row[6] or "",
                "group_avatar_data": row[7] or ""
            }
            for row in cursor.fetchall()
        ]

        cursor.execute(
            """
            SELECT peer_node
            FROM server_chat_deletes
            WHERE owner_node=?
            """,
            (
                node_id,
            )
        )

        deleted_peers = {
            row[0]
            for row in cursor.fetchall()
            if row[0]
        }

        if deleted_peers:

            direct_messages = [
                message
                for message in direct_messages
                if (
                    message.get("sender_node") not in deleted_peers
                    and message.get("receiver_node") not in deleted_peers
                )
            ]

        for group in groups:

            cursor.execute(
                """
                SELECT key_id,
                       key_envelope
                FROM server_group_keys
                WHERE group_id=?
                  AND (
                      member_login=?
                      OR member_node=?
                  )
                ORDER BY created_at,
                         rowid
                """,
                (
                    group["group_id"],
                    login,
                    node_id
                )
            )

            group["group_keys"] = [
                {
                    "key_id": row[0],
                    "key_envelope": row[1]
                }
                for row in cursor.fetchall()
            ]

        group_ids = [
            group["group_id"]
            for group in groups
        ]

        group_messages = []

        if group_ids:

            placeholders = ",".join(
                "?"
                for _ in group_ids
            )

            cursor.execute(
                f"""
                SELECT message_id,
                       group_id,
                       group_name,
                       sender_node,
                       sender_login,
                       sender_name,
                       message,
                       reply_to_message_id,
                       reply_to_text,
                       members_json,
                       group_key_id,
                       created_at
                FROM server_group_messages
                WHERE group_id IN ({placeholders})
                ORDER BY created_at
                """,
                group_ids
            )

            group_messages = [
                {
                    "message_id": row[0],
                    "group_id": row[1],
                    "group_name": row[2],
                    "sender_node": row[3],
                    "sender_login": row[4],
                    "sender_name": row[5],
                    "message": row[6],
                    "reply_to_message_id": row[7],
                    "reply_to_text": row[8],
                    "members": json.loads(
                        row[9] or "[]"
                    ),
                    "group_key_id": row[10],
                    "created_at": row[11]
                }
                for row in cursor.fetchall()
            ]

        message_ids = [
            message["message_id"]
            for message in direct_messages
        ] + [
            message["message_id"]
            for message in group_messages
        ]

        file_conditions = [
            "sender_login=?",
            "receiver_login=?",
            "sender_node=?",
            "receiver_node=?"
        ]

        file_params = [
            login,
            login,
            node_id,
            node_id
        ]

        if group_ids:

            placeholders = ",".join(
                "?"
                for _ in group_ids
            )

            file_conditions.append(
                f"group_id IN ({placeholders})"
            )

            file_params.extend(
                group_ids
            )

        file_where = f"({' OR '.join(file_conditions)})"

        if deleted_peers:

            placeholders = ",".join(
                "?"
                for _ in deleted_peers
            )

            file_where += (
                f"""
                AND (
                    COALESCE(sender_node, '') NOT IN ({placeholders})
                    AND COALESCE(receiver_node, '') NOT IN ({placeholders})
                )
                """
            )

            file_params.extend(deleted_peers)
            file_params.extend(deleted_peers)

        cursor.execute(
            f"""
            SELECT file_id,
                   sender_node,
                   sender_login,
                   sender_name,
                   receiver_node,
                   receiver_login,
                   group_id,
                   filename,
                   caption,
                   data,
                   group_key_id,
                   created_at
            FROM server_files
            WHERE {file_where}
            ORDER BY created_at
            """,
            file_params
        )

        files = [
            {
                "file_id": row[0],
                "sender_node": row[1],
                "sender_login": row[2],
                "sender_name": row[3],
                "receiver_node": row[4],
                "receiver_login": row[5],
                "group_id": row[6],
                "filename": row[7],
                "caption": row[8] or "",
                "data": row[9],
                "group_key_id": row[10],
                "created_at": row[11]
            }
            for row in cursor.fetchall()
        ]

        message_ids += [
            file_info["file_id"]
            for file_info in files
            if file_info.get("file_id")
        ]

        reactions = []
        pins = []

        if message_ids:

            placeholders = ",".join(
                "?"
                for _ in message_ids
            )

            cursor.execute(
                f"""
                SELECT scope,
                       message_id,
                       reactor_node,
                       reaction
                FROM server_reactions
                WHERE message_id IN ({placeholders})
                """,
                message_ids
            )

            reactions = [
                {
                    "scope": row[0],
                    "message_id": row[1],
                    "reactor_node": row[2],
                    "reaction": row[3]
                }
                for row in cursor.fetchall()
            ]

            cursor.execute(
                f"""
                SELECT scope,
                       message_id,
                       pinner_node,
                       text,
                       group_key_id,
                       created_at
                FROM server_pins
                WHERE message_id IN ({placeholders})
                ORDER BY created_at
                """,
                message_ids
            )

            pins = [
                {
                    "scope": row[0],
                    "message_id": row[1],
                    "pinner_node": row[2],
                    "text": row[3],
                    "group_key_id": row[4],
                    "created_at": row[5]
                }
                for row in cursor.fetchall()
            ]

        profile_nodes = {
            node_id
        }

        for message in direct_messages:
            profile_nodes.add(message.get("sender_node"))
            profile_nodes.add(message.get("receiver_node"))

        for message in group_messages:
            profile_nodes.add(message.get("sender_node"))

        for file_info in files:
            profile_nodes.add(file_info.get("sender_node"))
            profile_nodes.add(file_info.get("receiver_node"))

        profile_nodes = [
            profile_node
            for profile_node in profile_nodes
            if profile_node
        ]

        profiles = []

        if profile_nodes:

            placeholders = ",".join(
                "?"
                for _ in profile_nodes
            )

            cursor.execute(
                f"""
                SELECT a.login,
                       ids.node_id,
                       a.display_name,
                       a.public_username,
                       a.about,
                       a.avatar_data,
                       a.encryption_public_key
                FROM (
                    SELECT ? AS node_id
                    {''.join([' UNION SELECT ?' for _ in profile_nodes[1:]])}
                ) ids
                JOIN account_devices d
                  ON d.node_id=ids.node_id
                JOIN accounts a
                  ON a.login=d.login
                UNION
                SELECT a.login,
                       a.node_id,
                       a.display_name,
                       a.public_username,
                       a.about,
                       a.avatar_data,
                       a.encryption_public_key
                FROM accounts a
                WHERE a.node_id IN ({placeholders})
                """,
                profile_nodes + profile_nodes
            )

            profiles = [
                {
                    "login": row[0],
                    "node_id": row[1],
                    "display_name": row[2],
                    "public_username": row[3],
                    "about": row[4],
                    "avatar_data": row[5]
                    ,"encryption_public_key": row[6]
                }
                for row in cursor.fetchall()
            ]

        return {
            "type": "server_sync",
            "profile": own_profile,
            "profiles": profiles,
            "direct_messages": direct_messages,
            "groups": groups,
            "group_messages": group_messages,
            "files": files,
            "reactions": reactions,
            "pins": pins
        }

    async def send_account_sync(
        self,
        websocket,
        login,
        node_id
    ):

        packet = self.build_sync_packet(
            login,
            node_id
        )

        file_payloads = []

        for file_info in packet.get(
            "files",
            []
        ):

            data = file_info.pop(
                "data",
                ""
            ) or ""

            if data:
                file_payloads.append(
                    (
                        dict(file_info),
                        data
                    )
                )

        await websocket.send(
            json.dumps(
                packet,
                ensure_ascii=False
            )
        )

        total_files = len(
            file_payloads
        )

        for file_number, (
            file_info,
            data
        ) in enumerate(
            file_payloads,
            start=1
        ):

            total_chunks = max(
                1,
                (
                    len(data)
                    + SERVER_FILE_SYNC_CHUNK_SIZE
                    - 1
                )
                // SERVER_FILE_SYNC_CHUNK_SIZE
            )

            for chunk_index in range(
                total_chunks
            ):

                start = (
                    chunk_index
                    * SERVER_FILE_SYNC_CHUNK_SIZE
                )

                await websocket.send(
                    json.dumps(
                        {
                            "type": "server_file_sync_chunk",
                            **file_info,
                            "chunk_index": chunk_index,
                            "total_chunks": total_chunks,
                            "file_number": file_number,
                            "total_files": total_files,
                            "data": data[
                                start:
                                start + SERVER_FILE_SYNC_CHUNK_SIZE
                            ]
                        },
                        ensure_ascii=False
                    )
                )

        await websocket.send(
            json.dumps(
                {
                    "type": "server_sync_done",
                    "total_files": total_files
                },
                ensure_ascii=False
            )
        )

    async def send_user_list(self):

        users = []

        try:
            client_names = list(self.client_names.items())
        except RuntimeError:
            client_names = []

        for node_id, username in client_names:

            profile = self.get_profile_by_node(node_id)

            users.append(
                {
                    "node_id": node_id,
                    "username": username,
                    "display_name": profile.get("display_name") or username,
                    "public_username": profile.get("public_username"),
                    "about": profile.get("about"),
                    "avatar_data": profile.get("avatar_data"),
                    "encryption_public_key": profile.get("encryption_public_key")
                }
            )

        packet = {
            "type": "server_users",
            "users": users
        }

        dead = []

        try:
            client_items = list(self.clients.items())
        except RuntimeError:
            client_items = []

        for node_id, websocket in client_items:

            try:

                await websocket.send(
                    json.dumps(
                        packet,
                        ensure_ascii=False
                    )
                )

            except websockets.ConnectionClosed:

                dead.append(
                    node_id
                )

        for node_id in dead:

            self.clients.pop(
                node_id,
                None
            )

            self.client_names.pop(
                node_id,
                None
            )
