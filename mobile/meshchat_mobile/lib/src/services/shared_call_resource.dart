import 'dart:async';

/// One microphone per local group room, independently leased by peer links.
class SharedCallResource<T> {
  final Map<String, _ResourceEntry<T>> _entries = {};

  Future<CallResourceLease<T>> acquire(
    String key,
    Future<T> Function() create,
    Future<void> Function(T) dispose,
  ) async {
    final entry = _entries.putIfAbsent(
      key,
      () => _ResourceEntry(Future.sync(create)),
    );
    entry.references++;
    try {
      final value = await entry.future;
      return CallResourceLease(value, () async {
        if (--entry.references != 0) return;
        if (identical(_entries[key], entry)) _entries.remove(key);
        await dispose(value);
      });
    } catch (_) {
      if (--entry.references == 0 && identical(_entries[key], entry)) {
        _entries.remove(key);
      }
      rethrow;
    }
  }
}

class _ResourceEntry<T> {
  _ResourceEntry(this.future);
  final Future<T> future;
  int references = 0;
}

class CallResourceLease<T> {
  CallResourceLease(this.value, this._release);
  final T value;
  final Future<void> Function() _release;
  bool _closed = false;

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _release();
  }
}
