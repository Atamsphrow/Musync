// The "Tester la réponse" contract: a ping tells answered / keyRejected /
// rateLimited / noAnswer / unknown apart, and — the point of this file — a
// dead network is "the test could not be made", never "the model is
// silent". A 429 is a limit hit, not a silent model: it is rateLimited,
// so a batch probe can stop instead of burning one call per model into
// the same wall.
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
          {'text': '{"ok": true}'},
        ],
      },
    },
  ],
});

String _openAiOk() => jsonEncode({
  'choices': [
    {
      'message': {'content': '{"ok": true}'},
    },
  ],
});

void main() {
  group('pingModel', () {
    test('gemini answers the JSON object', () async {
      final reader = _reader(() async => http.Response(_geminiOk(), 200));
      expect(
        await reader.pingModel(_provider(AiProviderKind.gemini)),
        AiModelPing.answered,
      );
    });

    test('openai-compatible answers the JSON object', () async {
      final reader = _reader(() async => http.Response(_openAiOk(), 200));
      expect(
        await reader.pingModel(_provider(AiProviderKind.openAiCompatible)),
        AiModelPing.answered,
      );
    });

    test('gemini ping asks for a JSON object, not a bare OK', () async {
      // The regression: the ping used to ask for a bare "OK" while the
      // request forced a JSON response, so the API rejected the call
      // (HTTP 400) and every model looked silent. The instruction must
      // ask for the object the response format requires.
      Map<String, Object?>? sent;
      final reader = AiFilenameReader(
        client: MockClient((request) async {
          sent = jsonDecode(request.body) as Map<String, Object?>;
          return http.Response(_geminiOk(), 200);
        }),
      );
      expect(
        await reader.pingModel(_provider(AiProviderKind.gemini)),
        AiModelPing.answered,
      );
      final parts =
          (sent!['systemInstruction'] as Map)['parts'] as List;
      expect((parts.first as Map)['text'], contains('{"ok": true}'));
    });

    test('openai-compatible ping asks for a JSON object', () async {
      Map<String, Object?>? sent;
      final reader = AiFilenameReader(
        client: MockClient((request) async {
          sent = jsonDecode(request.body) as Map<String, Object?>;
          return http.Response(_openAiOk(), 200);
        }),
      );
      expect(
        await reader.pingModel(_provider(AiProviderKind.openAiCompatible)),
        AiModelPing.answered,
      );
      final messages = sent!['messages'] as List;
      expect(
        (messages.first as Map)['content'],
        contains('{"ok": true}'),
      );
      expect(sent!['response_format'], {'type': 'json_object'});
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
        () async => http.Response(
          jsonEncode({
            'candidates': [
              {
                'content': {
                  'parts': [
                    {'text': '   '},
                  ],
                },
              },
            ],
          }),
          200,
        ),
      );
      expect(
        await reader.pingModel(_provider(AiProviderKind.gemini)),
        AiModelPing.noAnswer,
      );
    });

    test('HTTP 429 is rate limited, not noAnswer', () async {
      final reader = _reader(() async => http.Response('quota', 429));
      expect(
        await reader.pingModel(_provider(AiProviderKind.openAiCompatible)),
        AiModelPing.rateLimited,
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
