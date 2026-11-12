// Tests du partage de texte (MethodChannel media_store).
//
// Les tests tournent sur l'hôte (Linux), pas sur Android : le garde
// `Platform.isAndroid` de MediaStore renvoie `failed` sans jamais
// appeler le canal. Le test le constate, et vérifie qu'aucun appel
// n'a eu lieu. Le format du texte partagé est testé, lui, dans
// nudge_line_sheet_test.dart (`shareQuote`, pur).
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musync/core/services/media_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('com.atamsphrow.musync/media_store');
  final calls = <MethodCall>[];

  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return true;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('hors Android : failed, sans appel au canal', () async {
    final outcome = await MediaStore.shareText(
      text: '« Yeah » — The Weeknd – Blinding Lights',
      title: 'Blinding Lights',
    );
    expect(outcome, ShareOutcome.failed);
    expect(calls, isEmpty);
  });
}
