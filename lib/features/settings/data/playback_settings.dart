/// Playback settings the user can adjust, and where they are kept.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:musync/core/utils/atomic_file.dart';
import 'package:musync/core/services/debug_log.dart';
import 'package:path_provider/path_provider.dart';

@immutable
class PlaybackSettings {
  /// Shifts the lyrics display against the audio, in milliseconds.
  ///
  /// Positive means the lines light up later. **Display only** — it never
  /// reaches a tag, so it cannot be confused with the per-track offset the sync
  /// editor writes (Décaler), and it cannot corrupt anything.
  ///
  /// The residual safety net for T20: after the line-transition fix there
  /// should be nothing left to compensate, but a file whose encoder wrote a
  /// non-standard header, or a device with unusual audio output latency, is not
  /// something the app can measure for itself. Zero by default, because a
  /// non-zero default would be a guess applied to every file.
  final int lyricsOffsetMs;

  const PlaybackSettings({this.lyricsOffsetMs = 0});

  /// The bound is not arbitrary: beyond a second the lines have moved past the
  /// neighbouring ones, so a larger value could only ever be a mistake — and a
  /// slider that could produce one would hide the real problem.
  static const int maxOffsetMs = 1000;

  Duration get lyricsOffset => Duration(milliseconds: lyricsOffsetMs);

  PlaybackSettings copyWith({int? lyricsOffsetMs}) =>
      PlaybackSettings(lyricsOffsetMs: lyricsOffsetMs ?? this.lyricsOffsetMs);

  Map<String, Object?> toJson() => {'lyricsOffsetMs': lyricsOffsetMs};

  /// Clamped on the way in, not only in the UI: a hand-edited or truncated file
  /// must not be able to push the display a minute out.
  static PlaybackSettings fromJson(Object? raw) {
    if (raw is! Map) return const PlaybackSettings();
    final offset = raw['lyricsOffsetMs'];
    if (offset is! int) return const PlaybackSettings();
    return PlaybackSettings(
      lyricsOffsetMs: offset.clamp(-maxOffsetMs, maxOffsetMs),
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PlaybackSettings && other.lyricsOffsetMs == lyricsOffsetMs;

  @override
  int get hashCode => lyricsOffsetMs.hashCode;
}

class PlaybackSettingsStore {
  /// Overridable so tests need no `path_provider`.
  final Directory? root;

  const PlaybackSettingsStore({this.root});

  static const String _fileName = 'playback_settings.json';

  Future<File> _file() async {
    final dir = root ?? await getApplicationSupportDirectory();
    return File('${dir.path}${Platform.pathSeparator}$_fileName');
  }

  /// Defaults on any failure. A setting that cannot be read must not stop
  /// playback, and the default is the neutral value anyway.
  Future<PlaybackSettings> load() async {
    try {
      final file = await _file();
      if (!await file.exists()) return const PlaybackSettings();
      return PlaybackSettings.fromJson(jsonDecode(await file.readAsString()));
    } catch (error, stack) {
      DebugLog.instance.error(
        'Réglages',
        'Réglages de lecture illisibles : valeurs par défaut appliquées',
        error: error,
        stackTrace: stack,
      );
      return const PlaybackSettings();
    }
  }

  Future<void> save(PlaybackSettings settings) async =>
      AtomicFile.writeString(await _file(), jsonEncode(settings.toJson()));
}
