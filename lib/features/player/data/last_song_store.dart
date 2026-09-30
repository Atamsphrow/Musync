import 'package:shared_preferences/shared_preferences.dart';

/// Persists the last-played song's file path so the next launch can re-open
/// the same track (#4).
class LastSongStore {
  static const String _key = 'last_song_path';
  static const String _posKey = 'last_song_position_ms';

  Future<void> save(String filePath, Duration position) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, filePath);
    await prefs.setInt(_posKey, position.inMilliseconds);
  }

  Future<({String? path, Duration position})> load() async {
    final prefs = await SharedPreferences.getInstance();
    final path = prefs.getString(_key);
    final pos = prefs.getInt(_posKey) ?? 0;
    return (
      path: path,
      position: Duration(milliseconds: pos),
    );
  }
}
