// Widget tests for the long-press nudge sheet on the now-playing screen:
// the play button (listen from this line) and the delete button, which only
// ever appears for an empty line.
//
// File IO lives in setUp (real async) and in tester.runAsync — never awaited
// straight inside a testWidgets body, where the fake-async zone never lets
// real IO complete. The path_provider channel is mocked to the temp dir, like
// deepseek_fixes_hijkm_test.dart does, so the backup store and the debug log
// flush write somewhere real.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musync/core/id3/id3_reader.dart';
import 'package:musync/core/id3/id3_writer.dart';
import 'package:musync/core/id3/models/lyrics.dart';
import 'package:musync/core/services/debug_log.dart';
import 'package:musync/features/player/data/audio_player_service.dart';
import 'package:musync/features/player/providers/player_provider.dart';
import 'package:musync/features/player/ui/widgets/nudge_line_sheet.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakePlayer extends AudioPlayerService {
  bool isPlayingOverride = false;
  final seekPositions = <Duration>[];
  int playCalls = 0;

  @override
  bool get isPlaying => isPlayingOverride;

  @override
  Future<void> seekTo(Duration position) async {
    seekPositions.add(position);
  }

  @override
  Future<void> play({Duration? fadeIn}) async {
    playCalls++;
  }
}

class _Opener extends ConsumerWidget {
  const _Opener({
    required this.filePath,
    required this.synced,
    required this.index,
  });

  final String filePath;
  final SyncedLyrics synced;
  final int index;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return FilledButton(
      onPressed: () => showNudgeLineSheet(
        context,
        ref,
        filePath: filePath,
        synced: synced,
        unsynced: null,
        index: index,
      ),
      child: const Text('Ouvrir'),
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late String filePath;

  final synced = SyncedLyrics([
    LyricLine(timestamp: Duration(seconds: 10), text: 'Yeah'),
    LyricLine(timestamp: Duration(seconds: 20), text: ''),
    LyricLine(timestamp: Duration(seconds: 30), text: 'Trois'),
  ]);

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tempDir = await Directory.systemTemp.createTemp('musync_nudge_sheet_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async {
        if (call.method == 'getTemporaryDirectory' ||
            call.method == 'getApplicationSupportDirectory') {
          return tempDir.path;
        }
        return null;
      },
    );
    final file = File('${tempDir.path}${Platform.pathSeparator}track.mp3');
    await file.writeAsBytes(
      Uint8List.fromList(List<int>.generate(4096, (i) => (i * 13) % 256)),
    );
    await Id3Writer.writeLyrics(file.path, synced: synced);
    filePath = file.path;
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      null,
    );
    DebugLog.instance.clear();
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  Future<void> openSheet(
    WidgetTester tester, {
    required _FakePlayer player,
    required int index,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [audioPlayerServiceProvider.overrideWithValue(player)],
        child: MaterialApp(
          home: Scaffold(
            body: _Opener(filePath: filePath, synced: synced, index: index),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Ouvrir'));
    await tester.pumpAndSettle();
  }

  testWidgets('play seeks to the line and resumes when paused',
      (tester) async {
    final player = _FakePlayer();
    await openSheet(tester, player: player, index: 0);

    await tester.tap(find.text("Écouter à partir d'ici"));
    await tester.pumpAndSettle();

    expect(player.seekPositions, [const Duration(seconds: 10)]);
    expect(player.playCalls, 1);
  });

  testWidgets('play seeks but does not resume when already playing',
      (tester) async {
    final player = _FakePlayer()..isPlayingOverride = true;
    await openSheet(tester, player: player, index: 2);

    await tester.tap(find.text("Écouter à partir d'ici"));
    await tester.pumpAndSettle();

    expect(player.seekPositions, [const Duration(seconds: 30)]);
    expect(player.playCalls, 0);
  });

  testWidgets('no delete button on a line with words', (tester) async {
    final player = _FakePlayer();
    await openSheet(tester, player: player, index: 0);

    expect(find.text("Écouter à partir d'ici"), findsOneWidget);
    expect(find.text('Supprimer la ligne'), findsNothing);
  });

  testWidgets('delete on an empty line removes it from the file',
      (tester) async {
    final player = _FakePlayer();
    await openSheet(tester, player: player, index: 1);

    expect(find.text('Supprimer la ligne'), findsOneWidget);
    await tester.tap(find.text('Supprimer la ligne'));
    // The write runs after the sheet closes, and its real IO only progresses
    // when the real loop runs (runAsync) and the fake microtasks are flushed
    // (pump): alternate both until the snackbar lands. Plain pumpAndSettle
    // settles at once — a pending write schedules no frames — and awaiting
    // real IO straight in the body never completes under fake async.
    for (var i = 0; i < 60; i++) {
      await tester.runAsync(() async {
        await Future.delayed(const Duration(milliseconds: 100));
      });
      await tester.pump(const Duration(milliseconds: 100));
      if (find.text('Ligne vide supprimée.').evaluate().isNotEmpty) break;
    }

    // The sheet closed, and the write landed with the adapted message.
    expect(find.text('Supprimer la ligne'), findsNothing);
    expect(find.text('Ligne vide supprimée.'), findsOneWidget);

    // Drain the pending fake timers (snackbar dismissal, debug-log flush)
    // or the teardown invariant fails on them.
    await tester.pump(const Duration(seconds: 7));

    late LyricsPair pair;
    await tester.runAsync(() async {
      pair = await Id3Reader.readLyrics(filePath);
    });
    final lines = pair.synced!.lines;
    expect(lines.map((l) => l.text), ['Yeah', 'Trois']);
    expect(
      lines.map((l) => l.timestamp),
      const [Duration(seconds: 10), Duration(seconds: 30)],
    );
  });
}
