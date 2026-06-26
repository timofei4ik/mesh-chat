import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';

import '../models/profile.dart';
import '../models/session.dart';

typedef PacketHandler = FutureOr<void> Function(Map<String, dynamic> packet);
typedef StatusHandler = void Function(String status);

class MeshSocket {
  static const protocolVersion = 5;
  static const minProtocolVersion = 5;
  static const appVersion = '0.1.0-mobile';

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _subscription;
  Timer? _reconnectTimer;
  bool _closed = false;
  bool _connected = false;

  bool get isConnected => _connected;

  Future<void> connect({
    required Session session,
    required String publicKey,
    required Profile profile,
    required PacketHandler onPacket,
    required StatusHandler onStatus,
  }) async {
    _closed = false;
    await _subscription?.cancel();
    await _channel?.sink.close();

    onStatus('Connecting...');
    final channel = WebSocketChannel.connect(Uri.parse(session.serverUrl));
    _channel = channel;
    await channel.ready.timeout(const Duration(seconds: 10));
    _connected = true;

    channel.sink.add(jsonEncode(_helloPacket(session, publicKey, profile)));

    _subscription = channel.stream.listen(
      (raw) async {
        final decoded = jsonDecode(raw.toString());
        if (decoded is Map<String, dynamic>) {
          await onPacket(decoded);
        }
      },
      onError: (Object error) {
        _connected = false;
        onStatus('Connection error');
        _scheduleReconnect(session, publicKey, profile, onPacket, onStatus);
      },
      onDone: () {
        _connected = false;
        onStatus('Offline');
        _scheduleReconnect(session, publicKey, profile, onPacket, onStatus);
      },
      cancelOnError: false,
    );
  }

  Future<String?> check(Session session, String publicKey) async {
    final result = await diagnose(session, publicKey);
    return result.ok ? null : result.message;
  }

  Future<ConnectionDiagnostics> diagnose(
    Session session,
    String publicKey,
  ) async {
    final channel = WebSocketChannel.connect(Uri.parse(session.serverUrl));
    final startedAt = DateTime.now();
    try {
      await channel.ready.timeout(const Duration(seconds: 10));
      channel.sink.add(
        jsonEncode({
          ..._helloPacket(session, publicKey, null),
          'node_id': 'login-check-${session.login}',
          'auth_check': true,
        }),
      );
      final raw = await channel.stream.first.timeout(
        const Duration(seconds: 10),
      );
      final latency = DateTime.now().difference(startedAt);
      final packet = jsonDecode(raw.toString()) as Map<String, dynamic>;
      if (packet['type'] == 'server_error') {
        final message = packet['code'] == 'incompatible_protocol'
            ? protocolError(packet)
            : packet['message']?.toString() ??
                  packet['reason']?.toString() ??
                  'Server error';
        return ConnectionDiagnostics(
          ok: false,
          message: message,
          latency: latency,
          serverVersion: packet['server_version']?.toString() ?? 'unknown',
          serverProtocolRange: serverProtocolRange(packet),
        );
      }
      if (packet['type'] != 'server_welcome') {
        return ConnectionDiagnostics(
          ok: false,
          message: 'Unexpected server response',
          latency: latency,
        );
      }
      if (!isProtocolCompatible(packet)) {
        return ConnectionDiagnostics(
          ok: false,
          message: protocolError(packet),
          latency: latency,
          serverVersion: packet['server_version']?.toString() ?? 'unknown',
          serverProtocolRange: serverProtocolRange(packet),
        );
      }
      return ConnectionDiagnostics(
        ok: true,
        message: 'Connection OK',
        latency: latency,
        serverVersion: packet['server_version']?.toString() ?? 'unknown',
        serverProtocolRange: serverProtocolRange(packet),
      );
    } catch (error) {
      return ConnectionDiagnostics(
        ok: false,
        message: 'Could not connect: $error',
        latency: DateTime.now().difference(startedAt),
      );
    } finally {
      await channel.sink.close();
    }
  }

  void send(Map<String, dynamic> packet) {
    _channel?.sink.add(jsonEncode(packet));
  }

  Map<String, dynamic> _helloPacket(
    Session session,
    String publicKey,
    Profile? profile,
  ) {
    final displayName = profile?.displayName.trim().isNotEmpty == true
        ? profile!.displayName
        : session.login;
    return {
      'type': 'server_hello',
      'node_id': session.nodeId,
      'username': session.login,
      'server_token': session.serverToken,
      'login': session.login,
      'password': session.password,
      'display_name': displayName,
      'public_username': session.publicUsername,
      'about': profile?.about,
      'avatar_data': profile?.avatarData,
      'encryption_public_key': publicKey,
      'app_version': appVersion,
      'protocol_version': protocolVersion,
      'min_protocol_version': minProtocolVersion,
    };
  }

  static bool isProtocolCompatible(Map<String, dynamic> packet) {
    final serverProtocol = _asInt(packet['protocol_version']);
    final serverMinProtocol = _asInt(
      packet['min_protocol_version'] ?? packet['protocol_min_version'],
    );
    if (serverProtocol == null) return true;
    final serverMin = serverMinProtocol ?? serverProtocol;
    return serverMin <= protocolVersion && serverProtocol >= minProtocolVersion;
  }

  static String protocolRange() {
    return '$minProtocolVersion..$protocolVersion';
  }

  static String serverProtocolRange(Map<String, dynamic> packet) {
    final serverProtocol = packet['protocol_version']?.toString() ?? '?';
    final serverMin =
        packet['min_protocol_version']?.toString() ??
        packet['protocol_min_version']?.toString() ??
        serverProtocol;
    return '$serverMin..$serverProtocol';
  }

  static String protocolError(Map<String, dynamic> packet) {
    return 'Incompatible protocol: client ${protocolRange()}, server ${serverProtocolRange(packet)}. Update MeshChat.';
  }

  static int? _asInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value);
    return null;
  }

  void _scheduleReconnect(
    Session session,
    String publicKey,
    Profile profile,
    PacketHandler onPacket,
    StatusHandler onStatus,
  ) {
    if (_closed || _reconnectTimer?.isActive == true) return;
    _reconnectTimer = Timer(const Duration(seconds: 4), () {
      connect(
        session: session,
        publicKey: publicKey,
        profile: profile,
        onPacket: onPacket,
        onStatus: onStatus,
      ).catchError((_) {
        _scheduleReconnect(session, publicKey, profile, onPacket, onStatus);
      });
    });
  }

  Future<void> close() async {
    _closed = true;
    _reconnectTimer?.cancel();
    await _subscription?.cancel();
    await _channel?.sink.close();
    _channel = null;
    _connected = false;
  }
}

class ConnectionDiagnostics {
  const ConnectionDiagnostics({
    required this.ok,
    required this.message,
    required this.latency,
    this.serverVersion = 'unknown',
    this.serverProtocolRange = '?',
  });

  final bool ok;
  final String message;
  final Duration latency;
  final String serverVersion;
  final String serverProtocolRange;
}
