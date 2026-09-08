/// Short-lived control packets only. Never persist call setup or audio.
class CallSignalBuffer {
  CallSignalBuffer({DateTime Function()? now}) : _now = now ?? DateTime.now;
  final DateTime Function() _now;
  static const lifetime = Duration(seconds: 10);
  static const capacity = 256;
  final _pending = <({Map<String, dynamic> packet, DateTime expires})>[];
  final _ended = <String, DateTime>{};

  static bool handles(Map<String, dynamic> packet) {
    final type = packet['type']?.toString() ?? '';
    return type.startsWith('call_') &&
        !type.startsWith('call_caption') &&
        (packet['call_id']?.toString().isNotEmpty ?? false);
  }

  String _key(Map<String, dynamic> packet) =>
      '${packet['call_id']}:${packet['destination_node']}';

  void add(Map<String, dynamic> packet) {
    _prune();
    final key = _key(packet);
    if (packet['type'] == 'call_end') {
      _pending.removeWhere((entry) => _key(entry.packet) == key);
      if (_ended.length >= capacity) _ended.remove(_ended.keys.first);
      _ended[key] = _now().add(lifetime);
    } else if (_ended.containsKey(key)) {
      return;
    }
    final id = packet['packet_id'];
    if (id != null &&
        _pending.any((entry) => entry.packet['packet_id'] == id)) {
      return;
    }
    if (_pending.length >= capacity) {
      // Drop an ICE update before dropping an offer or answer.
      final ice = _pending.indexWhere(
        (entry) => entry.packet['type'] == 'call_ice',
      );
      if (ice >= 0) {
        _pending.removeAt(ice);
      } else {
        return;
      }
    }
    _pending.add((
      packet: Map<String, dynamic>.from(packet),
      expires: _now().add(lifetime),
    ));
  }

  void flush(bool Function(Map<String, dynamic>) send) {
    _prune();
    while (_pending.isNotEmpty) {
      if (!send(_pending.first.packet)) return;
      _pending.removeAt(0);
    }
  }

  void _prune() {
    final now = _now();
    _pending.removeWhere((entry) => !entry.expires.isAfter(now));
    _ended.removeWhere((_, until) => !until.isAfter(now));
  }

  void clear() {
    _pending.clear();
    _ended.clear();
  }
}
