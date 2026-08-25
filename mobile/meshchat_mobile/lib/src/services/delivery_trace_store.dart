import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/session.dart';

class DeliveryTraceEvent {
  const DeliveryTraceEvent({
    required this.operationId,
    required this.packetId,
    required this.stage,
    required this.time,
    this.detail = '',
  });

  final String operationId;
  final String packetId;
  final String stage;
  final DateTime time;
  final String detail;

  factory DeliveryTraceEvent.fromJson(Map<String, dynamic> json) =>
      DeliveryTraceEvent(
        operationId: json['operation_id']?.toString() ?? '',
        packetId: json['packet_id']?.toString() ?? '',
        stage: json['stage']?.toString() ?? '',
        time:
            DateTime.tryParse(json['time']?.toString() ?? '')?.toUtc() ??
            DateTime.now().toUtc(),
        detail: json['detail']?.toString() ?? '',
      );

  Map<String, dynamic> toJson() => {
    'operation_id': operationId,
    'packet_id': packetId,
    'stage': stage,
    'time': time.toUtc().toIso8601String(),
    'detail': detail,
  };
}

class DeliveryTraceStore {
  static const _prefix = 'meshchat_delivery_trace_v1:';
  static const _maximumEvents = 240;
  Future<void> _serial = Future<void>.value();

  Future<List<DeliveryTraceEvent>> load(Session session) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key(session));
    if (raw == null || raw.isEmpty) return const <DeliveryTraceEvent>[];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const <DeliveryTraceEvent>[];
      return decoded
          .whereType<Map>()
          .map(
            (item) =>
                DeliveryTraceEvent.fromJson(Map<String, dynamic>.from(item)),
          )
          .where((event) => event.operationId.isNotEmpty)
          .toList();
    } catch (_) {
      await prefs.remove(_key(session));
      return const <DeliveryTraceEvent>[];
    }
  }

  Future<void> record(Session session, DeliveryTraceEvent event) {
    final result = _serial.then((_) async {
      if (event.operationId.isEmpty || event.stage.isEmpty) return;
      final events = <DeliveryTraceEvent>[...await load(session)];
      events.insert(0, event);
      if (events.length > _maximumEvents) {
        events.removeRange(_maximumEvents, events.length);
      }
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _key(session),
        jsonEncode(events.map((item) => item.toJson()).toList()),
      );
    });
    _serial = result.catchError((Object _) {});
    return result;
  }

  static String _key(Session session) =>
      '$_prefix${base64Url.encode(utf8.encode('${session.serverUrl.trim().toLowerCase()}|${session.login.trim().toLowerCase()}'))}';
}
