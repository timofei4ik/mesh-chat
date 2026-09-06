"""Authoritative, expiring admission for LiveKit group-call rooms."""

import time


SESSION_SECONDS = 12 * 60 * 60
MAX_PARTICIPANTS = 32


def _members(value):
    if not isinstance(value, list):
        return []
    return list(dict.fromkeys(
        str(item or "").strip()[:256]
        for item in value
        if str(item or "").strip()
    ))


def prune_sfu_sessions(server, now=None):
    now = int(time.time() if now is None else now)
    server.db.execute(
        "DELETE FROM call_sfu_sessions WHERE expires_at<=?",
        (now,),
    )
    server.db.commit()


def start_sfu_session(server, *, call_id, owner_node, group_id, members, now=None):
    now = int(time.time() if now is None else now)
    invited = _members(members)
    if owner_node not in invited:
        invited.insert(0, owner_node)
    if not 2 <= len(invited) <= MAX_PARTICIPANTS:
        return False, "invalid_members"
    allowed = set(server.get_group_delivery_nodes(group_id))
    if not set(invited).issubset(allowed):
        return False, "group_membership_changed"
    existing = server.db.execute(
        "SELECT owner_node, group_id FROM call_sfu_sessions WHERE call_id=?",
        (call_id,),
    ).fetchone()
    if existing and (existing[0] != owner_node or existing[1] != group_id):
        return False, "call_id_conflict"
    expires = now + SESSION_SECONDS
    server.db.execute(
        "INSERT INTO call_sfu_sessions(call_id,owner_node,group_id,expires_at) "
        "VALUES(?,?,?,?) ON CONFLICT(call_id) DO UPDATE SET expires_at=excluded.expires_at",
        (call_id, owner_node, group_id, expires),
    )
    server.db.execute(
        "DELETE FROM call_sfu_members WHERE call_id=?",
        (call_id,),
    )
    server.db.executemany(
        "INSERT INTO call_sfu_members(call_id,node_id) VALUES(?,?) "
        "ON CONFLICT(call_id,node_id) DO NOTHING",
        ((call_id, node_id) for node_id in invited),
    )
    server.db.commit()
    return True, expires


def authorize_sfu_member(server, *, call_id, node_id, group_id, now=None):
    now = int(time.time() if now is None else now)
    row = server.db.execute(
        "SELECT s.group_id,s.expires_at FROM call_sfu_sessions s "
        "JOIN call_sfu_members m ON m.call_id=s.call_id "
        "WHERE s.call_id=? AND m.node_id=?",
        (call_id, node_id),
    ).fetchone()
    if not row or row[0] != group_id or row[1] <= now:
        return False, "not_invited"
    if node_id not in set(server.get_group_delivery_nodes(group_id)):
        return False, "group_membership_changed"
    server.db.execute(
        "UPDATE call_sfu_sessions SET expires_at=? WHERE call_id=?",
        (now + SESSION_SECONDS, call_id),
    )
    server.db.commit()
    return True, now + SESSION_SECONDS
