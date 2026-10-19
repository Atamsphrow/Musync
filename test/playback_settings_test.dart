// The lyrics display offset, and the interval that made it necessary.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:musync/features/player/providers/lyrics_provider.dart';
import 'package:musync/features/settings/data/playback_settings.dart';

void main() {
  group('the line refresh interval', () {
    test('is one frame, because that is the whole of T22', () {
      // This constant *is* the fix. just_audio's positionStream clamps its
      // period to 200 ms for any track over 160 seconds, which lit every line
      // up to 200 ms late — the constant lag reported against Musicolet and
      // attributed to the encoder delay. Raising this number back up would
      // reintroduce the bug with nothing else looking wrong, so it is pinned.
      expect(lineRefreshInterval.inMilliseconds, lessThanOrEqualTo(16));
      expect(lineRefreshInterval.inMilliseconds, greaterThan(0));
    });
  });

  group('the offset model', () {
    test('defaults to no compensation at all', () {
      // A non-zero default would be a guess applied to every file in the
      // library, which is exactly what T20 asked not to do.
      expect(const PlaybackSettings().lyricsOffsetMs, 0);
      expect(const PlaybackSettings().lyricsOffset, Duration.zero);
    });

    test('survives a round trip', () {
      final json = const PlaybackSettings(lyricsOffsetMs: -250).toJson();
      expect(
        PlaybackSettings.fromJson(jsonDecode(jsonEncode(json))),
        const PlaybackSettings(lyricsOffsetMs: -250),
      );
    });

    test('a hand-edited file cannot push the display a minute out', () {
      expect(
        PlaybackSettings.fromJson({'lyricsOffsetMs': 90000}).lyricsOffsetMs,
        PlaybackSettings.maxOffsetMs,
      );
      expect(
        PlaybackSettings.fromJson({'lyricsOffsetMs': -90000}).lyricsOffsetMs,
        -PlaybackSettings.maxOffsetMs,
      );
    });

    test('nonsense reads as the default rather than throwing', () {
      for (final raw in <Object?>[
        null,
        'not a map',
        <String, Object?>{},
        {'lyricsOffsetMs': 'later'},
        {'lyricsOffsetMs': 1.5},
      ]) {
        expect(PlaybackSettings.fromJson(raw), const PlaybackSettings());
      }
    });
  });

  group('alarm fade-in and auto-resume', () {
    test('defaults: fade on at 90 s, auto-resume on', () {
      const s = PlaybackSettings();
      expect(s.alarmFadeIn, isTrue);
      expect(s.alarmFadeInSeconds, 90);
      expect(s.alarmFadeInDuration, const Duration(seconds: 90));
      expect(s.autoResumeAfterCall, isTrue);
    });

    test('survives a round trip', () {
      const original = PlaybackSettings(
        alarmFadeIn: false,
        alarmFadeInSeconds: 45,
        autoResumeAfterCall: false,
      );
      final json = original.toJson();
      expect(
        PlaybackSettings.fromJson(jsonDecode(jsonEncode(json))),
        original,
      );
    });

    test('fade duration is clamped on the way in', () {
      expect(
        PlaybackSettings.fromJson({'lyricsOffsetMs': 0, 'alarmFadeInSeconds': 5})
            .alarmFadeInSeconds,
        PlaybackSettings.minFadeInSeconds,
      );
      expect(
        PlaybackSettings.fromJson(
            {'lyricsOffsetMs': 0, 'alarmFadeInSeconds': 9000})
            .alarmFadeInSeconds,
        PlaybackSettings.maxFadeInSeconds,
      );
    });

    test('missing keys fall back to the defaults, not to false', () {
      // Un fichier écrit par une ancienne version ne doit pas couper le
      // fondu ni la reprise auto par surprise.
      final s = PlaybackSettings.fromJson({'lyricsOffsetMs': 0});
      expect(s.alarmFadeIn, isTrue);
      expect(s.alarmFadeInSeconds, 90);
      expect(s.autoResumeAfterCall, isTrue);
    });

    test('copyWith changes only what it is told to', () {
      const base = PlaybackSettings();
      final next = base.copyWith(alarmFadeInSeconds: 120);
      expect(next.alarmFadeInSeconds, 120);
      expect(next.alarmFadeIn, isTrue);
      expect(next.autoResumeAfterCall, isTrue);
      expect(next.lyricsOffsetMs, 0);
    });
  });
  group('the store', () {
    late Directory dir;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('musync_playback_test');
    });

    tearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    test('no file yet means no compensation', () async {
      expect(
        await PlaybackSettingsStore(root: dir).load(),
        const PlaybackSettings(),
      );
    });

    test('what is saved is what comes back', () async {
      final store = PlaybackSettingsStore(root: dir);
      await store.save(const PlaybackSettings(lyricsOffsetMs: 150));
      expect(await store.load(), const PlaybackSettings(lyricsOffsetMs: 150));
    });

    test('a truncated write reads as the default, not as an exception', () async {
      // The setting must never be able to stop playback: it decides when a line
      // lights up, not whether the track plays.
      await File(
        '${dir.path}${Platform.pathSeparator}playback_settings.json',
      ).writeAsString('{"lyricsOffsetMs":');
      expect(
        await PlaybackSettingsStore(root: dir).load(),
        const PlaybackSettings(),
      );
    });
  });
}
