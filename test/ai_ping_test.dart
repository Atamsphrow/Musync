// The "Tester la réponse" contract: a ping tells answered / keyRejected /
// noAnswer / unknown apart, and — the point of this file — a dead network
// is "the test could not be made", never "the model is silent".
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:musync/features/lyrics/data/ai_filename_reader.dart';
import 'package:musync/features/settings/data/ai_provider_config.dart';

AiProviderConfig _provider(AiProviderKind kind) => AiProviderConfig(
  id: 'test',
  name: 'Modèle de test',
  kind: kind,
  baseUrl: defaultBaseUrlFor(kind),
  model: defaultModelFor(kind),
  apiKey: 'secret',
);

AiFilenameReader _reader(Future<http.Response> Function() respond) =>
    AiFilenameReader(client: MockClient((_) => respond()));

String _geminiOk() => jsonEncode({
  'candidates': [
    {
      'content': {
        'parts': [
          {'text': 'OK'},
        ],
      },
    },
  ],
});

String _openAiOk() => jsonEncode({
  'choices': [
    {
      'message': {'content': 'OK'},
    },
  ],
});

void main() {
  group('pingModel', () {
    test('gemini answers OK', () async {
      final reader = _reader(() async => http.Response(_geminiOk(), 200));
      expect(
        await reader.pingModel(_provider(AiProviderKind.gemini)),
        AiModelPing.answered,
      );
    });

    test('openai-compatible answers OK', () async {
      final reader = _reader(() async => http.Response(_openAiOk(), 200));
      expect(
        await reader.pingModel(_provider(AiProviderKind.openAiCompatible)),
        AiModelPing.answered,
      );
    });

    test('401 and 403 mean the key was refused', () async {
      for (final status in [401, 403]) {
        final reader = _reader(() async => http.Response('nope', status));
        expect(
          await reader.pingModel(_provider(AiProviderKind.gemini)),
          AiModelPing.keyRejected,
          reason: 'HTTP $status',
        );
      }
    });

    test('empty candidates mean the model did not answer', () async {
      final reader = _reader(
        () async => http.Response(jsonEncode({'candidates': []}), 200),
      );
      expect(
        await reader.pingModel(_provider(AiProviderKind.gemini)),
        AiModelPing.noAnswer,
      );
    });

    test('whitespace-only reply is no answer', () async {
      final reader = _reader(
        () async => http.Response(_geminiOk().replaceAll('OK', '   '), 200),
      );
      expect(
        await reader.pingModel(_provider(AiProviderKind.gemini)),
        AiModelPing.noAnswer,
      );
    });

    test('HTTP 429 is no answer, not unknown', () async {
      final reader = _reader(() async => http.Response('quota', 429));
      expect(
        await reader.pingModel(_provider(AiProviderKind.openAiCompatible)),
        AiModelPing.noAnswer,
      );
    });

    test('unreachable host is unknown, never noAnswer', () async {
      // The regression this file guards: a phone with no network used to
      // report "the model does not answer".
      final reader = _reader(() => throw http.ClientException('down'));
      expect(
        await reader.pingModel(_provider(AiProviderKind.gemini)),
        AiModelPing.unknown,
      );
      expect(
        await reader.pingModel(_provider(AiProviderKind.openAiCompatible)),
        AiModelPing.unknown,
      );
    });
  });
}
