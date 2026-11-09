/// F37/F38/F39 : le flush du journal — debounce, sérialisation, course avec
/// la restauration au démarrage.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musync/core/services/debug_log.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('musync_debuglog_');
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
    // Partir d'un journal vide, en mémoire et sur disque.
    DebugLog.instance.clear();
    await DebugLog.instance.flush();
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      null,
    );
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  File logFile() => File('${tempDir.path}/debug_log.json');

  Future<List<Object?>> readEntries() async {
    if (!await logFile().exists()) return const [];
    final decoded = jsonDecode(await logFile().readAsString());
    return decoded is List ? decoded : const [];
  }

  test('un flux continu n’empêche plus le flush (F37)', () async {
    // 13 ajouts à 200 ms d'intervalle : sans le correctif, chaque ajout
    // réarmait le timer (2 s) et aucun flush n'avait lieu avant 4,4 s ;
    // avec le correctif, le timer du premier ajout sonne à 2 s.
    for (var i = 0; i < 13; i++) {
      DebugLog.instance.error('Test', 'erreur $i');
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    // 2,6 s après le premier ajout : le flush a eu lieu (10 premières
    // entrées — les ajouts à 0, 0,2, …, 1,8 s) ; les suivantes attendent le
    // timer suivant.
    final entries = await readEntries();
    expect(entries.length, greaterThanOrEqualTo(10));
  });

  test('un flush démarré avant clear() ne ressuscite rien (F38)', () async {
    DebugLog.instance.error('Test', 'avant');
    // Démarre le flush, puis efface avant qu'il ait fini d'écrire.
    unawaited(DebugLog.instance.flush());
    await Future<void>.delayed(Duration.zero);
    DebugLog.instance.clear();
    await DebugLog.instance.flush();
    expect(await readEntries(), isEmpty);
  });

  test('flush() attend la restauration du démarrage (F39)', () async {
    // Une entrée déjà sur disque, comme après un redémarrage.
    await logFile().writeAsString(jsonEncode([
      {
        't': '2026-11-09T00:00:00.000',
        'l': 2,
        's': 'Test',
        'm': 'ancienne',
      },
    ]));
    final previousOnError = FlutterError.onError;
    final previousDispatcher = ui.PlatformDispatcher.instance.onError;
    DebugLog.install();
    addTearDown(() {
      FlutterError.onError = previousOnError;
      ui.PlatformDispatcher.instance.onError = previousDispatcher;
    });

    DebugLog.instance.error('Test', 'nouvelle');
    await DebugLog.instance.flush();

    final messages = [
      for (final e in await readEntries()) (e as Map)['m'],
    ];
    expect(messages, contains('ancienne'));
    expect(messages, contains('nouvelle'));
  });
}
