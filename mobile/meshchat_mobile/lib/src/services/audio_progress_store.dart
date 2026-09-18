import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

class AudioProgressStore {
  AudioProgressStore(String account, String message)
    : key =
          'audio_progress_v1:${base64Url.encode(utf8.encode(jsonEncode([account, message])))}';
  final String key;
  static final Map<String, Future<void>> _writes = {};
  static final Map<String, AudioProgressStore> _owners = {};
  void activate() => _owners[key] = this;

  Future<Duration> load() async {
    await (_writes[key] ?? Future.value());
    final value = (await SharedPreferences.getInstance()).getInt(key) ?? 0;
    return Duration(milliseconds: value < 0 ? 0 : value);
  }

  Future<void> save(Duration position) {
    if (_owners.containsKey(key) && _owners[key] != this) return Future.value();
    _owners[key] = this;
    final write = (_writes[key] ?? Future<void>.value())
        .catchError((Object _) {})
        .then((_) async {
          final prefs = await SharedPreferences.getInstance();
          if (position <= Duration.zero) {
            await prefs.remove(key);
          } else {
            await prefs.setInt(key, position.inMilliseconds);
          }
        });
    _writes[key] = write;
    return write;
  }
}
