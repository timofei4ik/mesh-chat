import json

import websockets

SERVER_FILE_SYNC_CHUNK_SIZE = 256 * 1024
SERVER_STICKER_LIBRARY_INLINE_LIMIT = 512 * 1024
SERVER_STICKER_LIBRARY_SYNC_CHUNK_SIZE = 128 * 1024


class ServerSyncMixin:
    def _attach_story_engagement(self, cursor, stories, node_id):
        story_ids = [
            story.get("id")
            for story in stories
            if story.get("id")
        ]
        if not story_ids:
            return
        placeholders = ",".join("?" for _ in story_ids)
        cursor.execute(
            f"""
            SELECT story_id,
                   reactor_node,
                   reaction
            FROM server_story_reactions
            WHERE story_id IN ({placeholders})
              AND liked=1
            """,
            story_ids
        )
        reactions = {}
        for story_id, reactor_node, reaction in cursor.fetchall():
            if self._same_account_nodes(reactor_node, node_id):
                reactor_node = node_id
            bucket = reactions.setdefault(story_id, {})
            bucket.setdefault(reaction or "heart", []).append(reactor_node)
        for story in stories:
            story_reactions = {
                reaction: sorted(set(nodes))
                for reaction, nodes in reactions.get(
                    story.get("id"),
                    {}
                ).items()
            }
            story["reactions"] = story_reactions
            story["liked_by_node_ids"] = story_reactions.get("heart", [])

        cursor.execute(
            f"""
            SELECT story_id,
                   viewer_node
            FROM server_story_views
            WHERE story_id IN ({placeholders})
            """,
            story_ids
        )
        views = {}
        for story_id, viewer_node in cursor.fetchall():
            if self._same_account_nodes(viewer_node, node_id):
                viewer_node = node_id
            views.setdefault(story_id, []).append(viewer_node)
        for story in stories:
            story["viewed_by_node_ids"] = sorted(
                set(views.get(story.get("id"), []))
            )

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
                   encryption_public_key,
                   COALESCE(profile_background, 'mesh'),
                   COALESCE(profile_effect, 'stars'),
                   COALESCE(profile_blink_shape, 'auto'),
                   COALESCE(avatar_decoration, 'none'),
                   COALESCE(profile_glow, 0),
                   COALESCE(profile_accent, 4282557941)
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
                "node_id": node_id,
                "canonical_node_id": row[1],
                "display_name": row[2],
                "public_username": row[3],
                "about": row[4],
                "avatar_data": row[5],
                "encryption_public_key": row[6],
                "node_aliases": self.get_account_node_ids(row[0]),
                **self._meshpro_public_profile_fields(
                    row[0],
                    row[7],
                    row[8],
                    row[9],
                    row[10],
                    row[11],
                    row[12]
                )
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
                   COALESCE(chat_kind, 'normal'),
                   COALESCE(chat_id, ''),
                   COALESCE(message_effect, 'none'),
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
                "chat_kind": row[9],
                "chat_id": row[10],
                "message_effect": row[11],
                "created_at": row[12]
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
                            COALESCE(g.group_avatar_data, ''),
                            COALESCE(g.comments_enabled, 1)
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
                "group_avatar_data": row[7] or "",
                "comments_enabled": row[8] != 0
            }
            for row in cursor.fetchall()
        ]

        def sync_node_alias(value):
            value = (value or "").strip()
            if not value:
                return ""
            value_login = self.get_login_by_node(value)
            if value_login and value_login.strip().lower() == login:
                return node_id
            return value

        def sync_node_aliases(values):
            aliases = []
            for value in values:
                alias = sync_node_alias(value)
                if alias and alias not in aliases:
                    aliases.append(alias)
            return aliases

        for group in groups:
            group["owner_node"] = sync_node_alias(group["owner_node"])
            group["members"] = sync_node_aliases(group["members"])
            group["admins"] = sync_node_aliases(group["admins"])

        cursor.execute(
            """
            SELECT peer_node,
                   COALESCE(chat_kind, 'normal'),
                   COALESCE(chat_id, ''),
                   COALESCE(peer_login, '')
            FROM server_chat_deletes
            WHERE owner_node=?
               OR owner_login=?
               OR owner_node IN (
                    SELECT node_id
                    FROM account_devices
                    WHERE login=?
               )
            """,
            (
                node_id,
                login,
                login,
            )
        )

        deleted_threads = [
            {
                "peer_node": row[0],
                "chat_kind": row[1] or "normal",
                "chat_id": row[2] or "",
                "peer_login": row[3] or ""
            }
            for row in cursor.fetchall()
            if row[0]
        ]
        deleted_peers = {
            item["peer_node"]
            for item in deleted_threads
            if not item["chat_id"]
        }
        deleted_peer_logins = {
            item["peer_login"]
            for item in deleted_threads
            if not item["chat_id"] and item["peer_login"]
        }
        deleted_chat_ids = {
            item["chat_id"]
            for item in deleted_threads
            if item["chat_id"]
        }

        if deleted_peers or deleted_peer_logins:

            direct_messages = [
                message
                for message in direct_messages
                if (
                    (
                        message.get("sender_node") not in deleted_peers
                        and message.get("receiver_node") not in deleted_peers
                        and message.get("sender_login") not in deleted_peer_logins
                        and message.get("receiver_login") not in deleted_peer_logins
                    )
                    or message.get("chat_id")
                )
            ]

        if deleted_chat_ids:

            direct_messages = [
                message
                for message in direct_messages
                if message.get("chat_id") not in deleted_chat_ids
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
                       COALESCE(message_effect, 'none'),
                       COALESCE(is_channel_comment, 0),
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
                    "message_effect": row[11],
                    "is_channel_comment": bool(row[12]) or bool(row[7]),
                    "created_at": row[13]
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

        cursor.execute(
            f"""
            SELECT file_id,
                   sender_node,
                   sender_login,
                   sender_name,
                   receiver_node,
                   receiver_login,
                   group_id,
                   COALESCE(group_name, ''),
                   COALESCE(is_channel, 0),
                   COALESCE(comments_enabled, 1),
                   filename,
                   caption,
                   COALESCE(reply_to_message_id, ''),
                   COALESCE(reply_to_text, ''),
                   COALESCE(is_channel_comment, 0),
                   data,
                   group_key_id,
                   COALESCE(message_kind, 'file'),
                   COALESCE(chat_kind, 'normal'),
                   COALESCE(chat_id, ''),
                   COALESCE(message_effect, 'none'),
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
                "group_name": row[7] or "",
                "is_channel": bool(row[8]),
                "comments_enabled": row[9] != 0,
                "filename": row[10],
                "caption": row[11] or "",
                "reply_to_message_id": row[12] or "",
                "reply_to_text": row[13] or "",
                "is_channel_comment": bool(row[14]),
                "data": row[15],
                "group_key_id": row[16],
                "message_kind": row[17] or "file",
                "chat_kind": row[18],
                "chat_id": row[19],
                "message_effect": row[20],
                "created_at": row[21]
            }
            for row in cursor.fetchall()
        ]

        cursor.execute(
            """
            SELECT message_id, text, language, duration_seconds
            FROM ai_voice_transcriptions
            WHERE login=?
            """,
            (str(login or "").strip().lower(),),
        )
        voice_transcriptions = {
            row[0]: {
                "transcription": row[1] or "",
                "transcription_language": row[2] or "",
                "transcription_duration_seconds": max(
                    0.0,
                    float(row[3] or 0),
                ),
            }
            for row in cursor.fetchall()
        }
        for file_info in files:
            transcription = voice_transcriptions.get(file_info["file_id"])
            if transcription:
                file_info.update(transcription)

        cursor.execute(
            """
            SELECT message_id, text, language
            FROM ai_image_ocr
            WHERE login=?
            """,
            (str(login or "").strip().lower(),),
        )
        image_ocr = {
            row[0]: {
                "ocr_text": row[1] or "",
                "ocr_language": row[2] or "",
                "ocr_processed": True,
            }
            for row in cursor.fetchall()
        }
        for file_info in files:
            ocr = image_ocr.get(file_info["file_id"])
            if ocr:
                file_info.update(ocr)

        if deleted_peers or deleted_peer_logins:

            files = [
                file_info
                for file_info in files
                if (
                    (
                        file_info.get("sender_node") not in deleted_peers
                        and file_info.get("receiver_node") not in deleted_peers
                        and file_info.get("sender_login") not in deleted_peer_logins
                        and file_info.get("receiver_login") not in deleted_peer_logins
                    )
                    or file_info.get("chat_id")
                )
            ]

        if deleted_chat_ids:

            files = [
                file_info
                for file_info in files
                if file_info.get("chat_id") not in deleted_chat_ids
            ]

        message_ids += [
            file_info["file_id"]
            for file_info in files
            if file_info.get("file_id")
        ]

        cursor.execute(
            """
            SELECT story_id,
                   owner_node,
                   owner_login,
                   story_json,
                   recipients_json
            FROM server_stories
            WHERE DATETIME(created_at) >= DATETIME('now', '-1 day')
            ORDER BY created_at DESC
            """
        )

        stories = []
        story_ids = []

        for (
            story_id,
            owner_node,
            owner_login,
            story_json,
            recipients_json
        ) in cursor.fetchall():
            try:
                recipients = set(json.loads(recipients_json or "[]"))
                story = json.loads(story_json or "{}")
            except json.JSONDecodeError:
                continue

            owner_login = (
                owner_login
                or self.get_login_by_node(owner_node)
                or ""
            ).strip().lower()
            recipient_logins = {
                (self.get_login_by_node(recipient) or "").strip().lower()
                for recipient in recipients
            }

            if (
                node_id != owner_node
                and node_id not in recipients
                and login != owner_login
                and login not in recipient_logins
            ):
                continue

            if not isinstance(story, dict):
                continue

            story["id"] = story.get("id") or story_id
            story["owner_node"] = (
                node_id
                if owner_login and owner_login == login
                else story.get("owner_node") or owner_node
            )
            stories.append(story)
            story_ids.append(story_id)

        self._attach_story_engagement(cursor, stories, node_id)

        story_archive = []
        subscription = self.subscription_status(login)
        entitlements = subscription.get("entitlements", {})
        archive_enabled = bool(
            subscription.get("active")
            and entitlements.get("features", {}).get("story_server_archive")
        )
        archive_days = int(
            entitlements.get("limits", {}).get(
                "server_story_archive_days",
                0
            )
            or 0
        )
        if archive_enabled and archive_days > 0:
            cursor.execute(
                """
                SELECT story_id,
                       owner_node,
                       story_json
                FROM server_stories
                WHERE owner_login=?
                  AND DATETIME(created_at) >= DATETIME('now', ?)
                ORDER BY created_at DESC
                """,
                (login, f"-{archive_days} days")
            )
            for story_id, owner_node, story_json in cursor.fetchall():
                try:
                    story = json.loads(story_json or "{}")
                except json.JSONDecodeError:
                    continue
                if not isinstance(story, dict):
                    continue
                story["id"] = story.get("id") or story_id
                story["owner_node"] = node_id
                story_archive.append(story)
            self._attach_story_engagement(cursor, story_archive, node_id)

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

        for story in stories:
            profile_nodes.add(story.get("owner_node"))
            for reactor_node in story.get("liked_by_node_ids") or []:
                profile_nodes.add(reactor_node)
            for viewer_node in story.get("viewed_by_node_ids") or []:
                profile_nodes.add(viewer_node)

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
                       a.encryption_public_key,
                       COALESCE(a.profile_background, 'mesh'),
                       COALESCE(a.profile_effect, 'stars'),
                       COALESCE(a.profile_blink_shape, 'auto'),
                       COALESCE(a.avatar_decoration, 'none'),
                       COALESCE(a.profile_glow, 0),
                       COALESCE(a.profile_accent, 4282557941)
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
                       a.encryption_public_key,
                       COALESCE(a.profile_background, 'mesh'),
                       COALESCE(a.profile_effect, 'stars'),
                       COALESCE(a.profile_blink_shape, 'auto'),
                       COALESCE(a.avatar_decoration, 'none'),
                       COALESCE(a.profile_glow, 0),
                       COALESCE(a.profile_accent, 4282557941)
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
                    "avatar_data": row[5],
                    "encryption_public_key": row[6],
                    "node_aliases": self.get_account_node_ids(row[0]),
                    **self._meshpro_public_profile_fields(
                        row[0],
                        row[7],
                        row[8],
                        row[9],
                        row[10],
                        row[11],
                        row[12]
                    )
                }
                for row in cursor.fetchall()
            ]

        cursor.execute(
            """
            SELECT library_json
            FROM server_sticker_libraries
            WHERE login=?
            LIMIT 1
            """,
            (
                login,
            )
        )
        sticker_library = None
        row = cursor.fetchone()
        if row:
            try:
                decoded = json.loads(row[0] or "{}")
                if isinstance(decoded, dict):
                    sticker_library = decoded
            except json.JSONDecodeError:
                sticker_library = None

        schedule_lister = getattr(self, "list_scheduled_messages", None)
        scheduled_messages = (
            schedule_lister(login)
            if callable(schedule_lister)
            else []
        )

        return {
            "type": "server_sync",
            "profile": own_profile,
            "profiles": profiles,
            "direct_messages": direct_messages,
            "groups": groups,
            "group_messages": group_messages,
            "files": files,
            "stories": stories,
            "story_archive": story_archive,
            "chat_preferences": self.get_chat_preferences(login),
            "meshpro_preferences": self.get_meshpro_preferences(login),
            "scheduled_messages": scheduled_messages,
            "sticker_library": sticker_library,
            "reactions": reactions,
            "pins": pins
        }

    async def send_account_sync(
        self,
        websocket,
        login,
        node_id,
        supports_sticker_library_chunks=False
    ):

        packet = self.build_sync_packet(
            login,
            node_id
        )

        file_payloads = []
        sticker_library_payload = ""

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

        sticker_library = packet.get("sticker_library")
        if isinstance(sticker_library, dict):
            encoded_library = json.dumps(
                sticker_library,
                ensure_ascii=False,
                separators=(",", ":")
            )
            if (
                len(encoded_library.encode("utf-8"))
                > SERVER_STICKER_LIBRARY_INLINE_LIMIT
            ):
                packet["sticker_library"] = None
                if supports_sticker_library_chunks:
                    sticker_library_payload = encoded_library
                    packet["sticker_library_chunked"] = True
                else:
                    packet["sticker_library_omitted"] = True

        await websocket.send(
            json.dumps(
                packet,
                ensure_ascii=False
            )
        )

        if sticker_library_payload:
            total_sticker_chunks = max(
                1,
                (
                    len(sticker_library_payload)
                    + SERVER_STICKER_LIBRARY_SYNC_CHUNK_SIZE
                    - 1
                )
                // SERVER_STICKER_LIBRARY_SYNC_CHUNK_SIZE
            )
            for chunk_index in range(total_sticker_chunks):
                start = (
                    chunk_index
                    * SERVER_STICKER_LIBRARY_SYNC_CHUNK_SIZE
                )
                await websocket.send(
                    json.dumps(
                        {
                            "type": "server_sticker_library_sync_chunk",
                            "chunk_index": chunk_index,
                            "total_chunks": total_sticker_chunks,
                            "data": sticker_library_payload[
                                start:
                                start + SERVER_STICKER_LIBRARY_SYNC_CHUNK_SIZE
                            ]
                        },
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
                    "login": profile.get("login"),
                    "username": username,
                    "display_name": profile.get("display_name") or username,
                    "public_username": profile.get("public_username"),
                    "about": profile.get("about"),
                    "avatar_data": profile.get("avatar_data"),
                    "encryption_public_key": profile.get("encryption_public_key"),
                    "meshpro_badge": profile.get("meshpro_badge", False),
                    "profile_background": profile.get(
                        "profile_background",
                        "mesh"
                    ),
                    "profile_effect": profile.get(
                        "profile_effect",
                        "nodes"
                    ),
                    "profile_blink_shape": profile.get(
                        "profile_blink_shape",
                        "auto"
                    ),
                    "avatar_decoration": profile.get(
                        "avatar_decoration",
                        "none"
                    ),
                    "profile_glow": profile.get("profile_glow", False),
                    "profile_accent": profile.get(
                        "profile_accent",
                        4282557941
                    )
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
