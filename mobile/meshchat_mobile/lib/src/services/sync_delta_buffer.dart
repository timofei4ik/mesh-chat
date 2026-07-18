class SyncDeltaBatch {
  const SyncDeltaBatch({
    required this.syncId,
    required this.sourceCursor,
    required this.targetCursor,
    required this.events,
    required this.livePackets,
  });

  final String syncId;
  final int sourceCursor;
  final int targetCursor;
  final List<Map<String, dynamic>> events;
  final List<Map<String, dynamic>> livePackets;
}

class SyncDeltaBuffer {
  static const maxEvents = 500;

  static const _durableEventTypes = <String>{
    'chat_message',
    'message_edit',
    'message_delete',
    'chat_delete',
    'message_pin',
    'message_reaction',
    'group_message',
    'group_update',
    'group_member_leave',
    'group_delete',
    'group_message_edit',
    'group_message_delete',
    'group_pin',
    'group_reaction',
    'profile_update',
    'story_update',
    'story_reaction',
    'story_delete',
  };

  _SyncDeltaSession? _active;

  bool get isActive => _active != null;

  static bool isDurableEventPacket(Map<String, dynamic> packet) {
    return _durableEventTypes.contains(packet['type']?.toString() ?? '');
  }

  void begin(Map<String, dynamic> packet, {required int localCursor}) {
    if (_active != null) {
      throw const FormatException('a delta sync is already active');
    }
    final version = _readInt(packet['version']);
    final syncId = packet['sync_id']?.toString().trim() ?? '';
    final sourceCursor = _readInt(packet['source_cursor']);
    final targetCursor = _readInt(packet['target_cursor']);
    final retainedFloor = _readInt(packet['retained_floor']);
    final eventCount = _readInt(packet['event_count']);
    if (version != 2 ||
        syncId.isEmpty ||
        sourceCursor == null ||
        targetCursor == null ||
        retainedFloor == null ||
        eventCount == null ||
        sourceCursor != localCursor ||
        sourceCursor < retainedFloor ||
        targetCursor < sourceCursor ||
        eventCount < 0 ||
        eventCount > maxEvents) {
      throw const FormatException('invalid delta sync boundary');
    }
    _active = _SyncDeltaSession(
      syncId: syncId,
      sourceCursor: sourceCursor,
      targetCursor: targetCursor,
      expectedEvents: eventCount,
    );
  }

  void addEvent(Map<String, dynamic> packet) {
    final active = _requireActive();
    if (packet['sync_id']?.toString() != active.syncId) {
      throw const FormatException('delta sync id changed');
    }
    final rawEvent = packet['event'];
    if (rawEvent is! Map) {
      throw const FormatException('delta event envelope is missing');
    }
    final event = Map<String, dynamic>.from(rawEvent);
    final eventId = _readInt(event['event_id'] ?? event['cursor']);
    final packetType = event['packet_type']?.toString() ?? '';
    final operationId = event['operation_id']?.toString().trim() ?? '';
    final rawPayload = event['payload'];
    if (eventId == null ||
        eventId <= active.lastEventId ||
        eventId <= active.sourceCursor ||
        eventId > active.targetCursor ||
        packetType.isEmpty ||
        operationId.isEmpty ||
        event['requires_snapshot'] == true ||
        rawPayload is! Map ||
        active.events.length >= active.expectedEvents) {
      throw const FormatException('invalid delta event');
    }
    final payload = Map<String, dynamic>.from(rawPayload);
    if (payload['type']?.toString() != packetType ||
        !_durableEventTypes.contains(packetType)) {
      throw const FormatException('unsupported delta event payload');
    }
    active.lastEventId = eventId;
    active.events.add(payload);
  }

  bool shouldBufferLivePacket(Map<String, dynamic> packet) {
    return _active != null && isDurableEventPacket(packet);
  }

  void bufferLivePacket(Map<String, dynamic> packet) {
    _requireActive().livePackets.add(Map<String, dynamic>.from(packet));
  }

  SyncDeltaBatch complete(Map<String, dynamic> packet) {
    final active = _requireActive();
    final rawMetadata = packet['sync_v2'];
    if (rawMetadata is! Map) {
      throw const FormatException('delta completion metadata is missing');
    }
    final metadata = Map<String, dynamic>.from(rawMetadata);
    final completedCursor = _readInt(
      metadata['cursor'] ?? packet['sync_cursor'],
    );
    final completedCount = _readInt(metadata['event_count']);
    if (metadata['version'] != 2 ||
        metadata['mode'] != 'delta' ||
        metadata['sync_id']?.toString() != active.syncId ||
        completedCursor != active.targetCursor ||
        completedCount != active.expectedEvents ||
        active.events.length != active.expectedEvents ||
        (active.targetCursor == active.sourceCursor &&
            active.expectedEvents != 0) ||
        (active.targetCursor > active.sourceCursor &&
            (active.events.isEmpty ||
                active.lastEventId != active.targetCursor))) {
      throw const FormatException('incomplete delta sync');
    }

    final batch = SyncDeltaBatch(
      syncId: active.syncId,
      sourceCursor: active.sourceCursor,
      targetCursor: active.targetCursor,
      events: List.unmodifiable(active.events),
      livePackets: List.unmodifiable(active.livePackets),
    );
    _active = null;
    return batch;
  }

  void abort() {
    _active = null;
  }

  _SyncDeltaSession _requireActive() {
    final active = _active;
    if (active == null) {
      throw const FormatException('no delta sync is active');
    }
    return active;
  }

  static int? _readInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '');
  }
}

class _SyncDeltaSession {
  _SyncDeltaSession({
    required this.syncId,
    required this.sourceCursor,
    required this.targetCursor,
    required this.expectedEvents,
  }) : lastEventId = sourceCursor;

  final String syncId;
  final int sourceCursor;
  final int targetCursor;
  final int expectedEvents;
  int lastEventId;
  final List<Map<String, dynamic>> events = [];
  final List<Map<String, dynamic>> livePackets = [];
}
