// Reading an artist and a title out of a file name with a language model.
//
// Driven through a MockClient: no key, no network, no cost. What is asserted is
// the contract — the two API shapes, the tolerance for a model that talks
// around its JSON, and above all that a secret never leaves this layer.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:musync/features/lyrics/data/ai_filename_reader.dart';
import 'package:musync/features/settings/data/ai_provider_config.dart';

const String _secret = 'sk-super-secret-key-1234';

AiProviderConfig _provider(AiProviderKind kind) => AiProviderConfig(
  id: 'test',
  name: 'Modèle de test',
  kind: kind,
  baseUrl: defaultBaseUrlFor(kind),
  model: defaultModelFor(kind),
  apiKey: _secret,
);

/// A client answering [body] with [status], recording what it was asked.
({AiFilenameReader reader, List<http.Request> sent}) _reader(
  String body, {
  int status = 200,
}) {
  final sent = <http.Request>[];
  return (
    reader: AiFilenameReader(
      client: MockClient((request) async {
        sent.add(request);
        return http.Response.bytes(utf8.encode(body), status, headers: {});
      }),
    ),
    sent: sent,
  );
}

String _geminiBody(String text) => jsonEncode({
  'candidates': [
    {
      'content': {
        'parts': [
          {'text': text},
        ],
      },
    },
  ],
});

String _openAiBody(String text) => jsonEncode({
  'choices': [
    {
      'message': {'content': text},
    },
  ],
});

void main() {
  group('Gemini', () {
    test('reads the answer out of the response', () async {
      final h = _reader(
        _geminiBody('{"artist": "Maître GIMS", "title": "Corazon"}'),
      );

      final guess = await h.reader.read(
        provider: _provider(AiProviderKind.gemini),
        instruction: defaultAiInstruction,
        fileName: 'whatever.mp3',
      );

      expect(guess.artist, 'Maître GIMS');
      expect(guess.title, 'Corazon');
    });

    test('sends the key as a header, never in the URL', () async {
      // A URL is the single most likely thing to be logged, by us or by anyone
      // in between.
      final h = _reader(_geminiBody('{"artist":"a","title":"t"}'));

      await h.reader.read(
        provider: _provider(AiProviderKind.gemini),
        instruction: 'x',
        fileName: 'f.mp3',
      );

      expect(h.sent.single.url.toString(), isNot(contains(_secret)));
      expect(h.sent.single.headers['x-goog-api-key'], _secret);
    });
  });

  group('compatible OpenAI', () {
    test('reads the answer out of the response', () async {
      final h = _reader(_openAiBody('{"artist": "ALG", "title": "Biloo"}'));

      final guess = await h.reader.read(
        provider: _provider(AiProviderKind.openAiCompatible),
        instruction: defaultAiInstruction,
        fileName: 'ALG - Biloo.mp3',
      );

      expect(guess.artist, 'ALG');
      expect(guess.title, 'Biloo');
    });

    test('authenticates with a bearer token', () async {
      final h = _reader(_openAiBody('{"artist":"a","title":"t"}'));

      await h.reader.read(
        provider: _provider(AiProviderKind.openAiCompatible),
        instruction: 'x',
        fileName: 'f.mp3',
      );

      expect(h.sent.single.headers['Authorization'], 'Bearer $_secret');
      expect(h.sent.single.url.toString(), endsWith('/chat/completions'));
    });
  });

  group('a model that does not answer cleanly', () {
    test('survives a fence and a sentence of preamble', () async {
      // Models are asked for bare JSON and mostly comply. "Mostly" is not
      // "always", and the alternative is failing over a stray backtick.
      final h = _reader(
        _openAiBody(
          'Voici le résultat :\n```json\n'
          '{"artist": "Stromae", "title": "Formidable"}\n```',
        ),
      );

      final guess = await h.reader.read(
        provider: _provider(AiProviderKind.openAiCompatible),
        instruction: 'x',
        fileName: 'f.mp3',
      );

      expect(guess.artist, 'Stromae');
      expect(guess.title, 'Formidable');
    });

    test('an empty field comes back empty, not invented', () async {
      final h = _reader(_geminiBody('{"artist": "", "title": "JANGOBO"}'));

      final guess = await h.reader.read(
        provider: _provider(AiProviderKind.gemini),
        instruction: 'x',
        fileName: 'f.mp3',
      );

      expect(guess.artist, isEmpty);
      expect(guess.title, 'JANGOBO');
    });

    test('prose with no JSON in it is an error', () async {
      final h = _reader(_openAiBody('Je ne sais pas trop.'));

      expect(
        () => h.reader.read(
          provider: _provider(AiProviderKind.openAiCompatible),
          instruction: 'x',
          fileName: 'f.mp3',
        ),
        throwsA(isA<AiReaderException>()),
      );
    });
  });

  group('the key never escapes', () {
    Future<String> messageFor(int status) async {
      final h = _reader('{"error":"nope"}', status: status);
      try {
        await h.reader.read(
          provider: _provider(AiProviderKind.gemini),
          instruction: 'x',
          fileName: 'f.mp3',
        );
      } on AiReaderException catch (e) {
        return e.message;
      }
      return '';
    }

    test('not in any error message', () async {
      // These messages reach the debug panel, which has a Copy button and is
      // meant to be pasted into a conversation.
      for (final status in [401, 403, 429, 500]) {
        expect(await messageFor(status), isNot(contains(_secret)));
      }
    });

    test('a refused key says so plainly', () async {
      expect(await messageFor(401), contains('refusée'));
      expect(await messageFor(429), contains('Quota'));
    });

    test('not in the config toString either', () {
      final config = _provider(AiProviderKind.gemini);
      expect(config.toString(), isNot(contains(_secret)));
      expect(config.redactedKey, isNot(contains(_secret)));
      // Enough to recognise which key it is, never enough to use it.
      expect(config.redactedKey, endsWith('1234'));
    });
  });

  group('AiSettings', () {
    test('the active model is the first switched on with a key', () {
      final settings = AiSettings(
        providers: [
          _provider(AiProviderKind.gemini).copyWith(enabled: false),
          _provider(AiProviderKind.openAiCompatible).copyWith(apiKey: ''),
          _provider(AiProviderKind.gemini).copyWith(name: 'Celui-ci'),
        ],
      );

      expect(settings.active?.name, 'Celui-ci');
    });

    test('no usable model means none', () {
      final settings = AiSettings(
        providers: [_provider(AiProviderKind.gemini).copyWith(apiKey: '  ')],
      );
      expect(settings.active, isNull);
      expect(const AiSettings().active, isNull);
    });

    test('a record survives a JSON round trip, key included', () {
      final decoded = AiProviderConfig.fromJson(
        jsonDecode(jsonEncode(_provider(AiProviderKind.gemini).toJson())),
      );
      expect(decoded, _provider(AiProviderKind.gemini));
    });

    test('an unknown kind is dropped rather than guessed', () {
      expect(
        AiProviderConfig.fromJson({'id': 'x', 'name': 'n', 'kind': 'martien'}),
        isNull,
      );
    });
  });

  // T29: a failure has to say which of the two settings is wrong. "Gemini a
  // répondu 404" sent the user checking their key; the model name is what
  // actually points at the fault.
  group('what a failure says', () {
    test('a 404 names the model, and says it is probably retired', () async {
      final h = _reader('{"error": {}}', status: 404);

      try {
        await h.reader.read(
          provider: _provider(AiProviderKind.gemini),
          instruction: 'lis',
          fileName: 'a.mp3',
        );
        fail('devrait échouer');
      } on AiReaderException catch (e) {
        expect(e.statusCode, 404);
        expect(e.model, defaultModelFor(AiProviderKind.gemini));
        expect(e.detail, contains('404'));
        expect(e.detail, contains(defaultModelFor(AiProviderKind.gemini)));
      }
    });

    test('a refused key is 401 and still names the model', () async {
      final h = _reader('{}', status: 401);

      try {
        await h.reader.read(
          provider: _provider(AiProviderKind.openAiCompatible),
          instruction: 'lis',
          fileName: 'a.mp3',
        );
        fail('devrait échouer');
      } on AiReaderException catch (e) {
        expect(e.statusCode, 401);
        // The distinction the ticket asks for: the caller can tell a dead key
        // from a dead model without matching on the wording.
        expect(e.message, contains('Clé refusée'));
        expect(e.model, isNotNull);
      }
    });

    test('an unreachable provider has no status code to report', () async {
      final reader = AiFilenameReader(
        client: MockClient((_) async => throw const SocketExceptionStub()),
      );

      try {
        await reader.read(
          provider: _provider(AiProviderKind.gemini),
          instruction: 'lis',
          fileName: 'a.mp3',
        );
        fail('devrait échouer');
      } on AiReaderException catch (e) {
        expect(e.statusCode, isNull);
        expect(e.detail, isNot(contains('HTTP')));
      }
    });

    test('no failure message ever carries the key', () async {
      for (final status in [401, 403, 404, 429, 500]) {
        final h = _reader('{}', status: status);
        try {
          await h.reader.read(
            provider: _provider(AiProviderKind.gemini),
            instruction: 'lis',
            fileName: 'a.mp3',
          );
          fail('devrait échouer');
        } on AiReaderException catch (e) {
          expect(e.detail, isNot(contains(_secret)));
          expect(e.toString(), isNot(contains(_secret)));
        }
      }
    });
  });

  // T27: a retired model identifier produced nothing but repeated 404s at the
  // moment of use. The provider can simply be asked.
  group('checking the model exists', () {
    test('Gemini strips the models/ prefix it reports', () async {
      final h = _reader(
        jsonEncode({
          'models': [
            {'name': 'models/gemini-3.6-flash'},
            {'name': 'models/gemini-3.5-flash-lite'},
          ],
        }),
      );

      final models = await h.reader.listModels(
        _provider(AiProviderKind.gemini),
      );
      // Sorted: the API's own order is neither stable nor meaningful, and
      // the picker built on this is only usable alphabetically.
      expect(models, ['gemini-3.5-flash-lite', 'gemini-3.6-flash']);
    });

    test('the OpenAI shape is read from `data` and `id`', () async {
      final h = _reader(
        jsonEncode({
          'data': [
            {'id': 'gpt-4o-mini'},
            {'id': 'llama-3.1-8b'},
          ],
        }),
      );

      final models = await h.reader.listModels(
        _provider(AiProviderKind.openAiCompatible),
      );
      expect(models, ['gpt-4o-mini', 'llama-3.1-8b']);
    });

    test('a model that cannot generate is left out of the list', () async {
      // Gemini lists everything it serves, embeddings included. Offering
      // `embedding-001` in a picker is offering a 400.
      final h = _reader(
        jsonEncode({
          'models': [
            {
              'name': 'models/gemini-3.6-flash',
              'supportedGenerationMethods': ['generateContent', 'countTokens'],
            },
            {
              'name': 'models/embedding-001',
              'supportedGenerationMethods': ['embedContent'],
            },
          ],
        }),
      );

      expect(await h.reader.listModels(_provider(AiProviderKind.gemini)), [
        'gemini-3.6-flash',
      ]);
    });

    test('a provider publishing no methods has everything offered', () async {
      // The OpenAI shape has no such field, so there is nothing to filter on
      // and filtering it all out would be worse than not filtering.
      final h = _reader(
        jsonEncode({
          'data': [
            {'id': 'gpt-4o-mini'},
            {'id': 'whisper-1'},
          ],
        }),
      );

      expect(
        await h.reader.listModels(_provider(AiProviderKind.openAiCompatible)),
        ['gpt-4o-mini', 'whisper-1'],
      );
    });
    test(
      'OpenRouter publishes both fields, and `id` is the identifier',
      () async {
        // Real payload shape: `id` is `meta/muse-spark-1.2-contributor` while
        // `name` is the display label "Meta: Muse Spark 1.2 Contributor".
        // Preferring whichever field is present filled the picker with labels
        // that are not model identifiers, so choosing one could only ever 404.
        final h = _reader(
          jsonEncode({
            'data': [
              {'id': 'meta/muse-spark-1.2', 'name': 'Meta: Muse Spark 1.2'},
              {'id': 'openai/gpt-4o', 'name': 'OpenAI: GPT-4o'},
            ],
          }),
        );

        expect(
          await h.reader.listModels(_provider(AiProviderKind.openAiCompatible)),
          ['meta/muse-spark-1.2', 'openai/gpt-4o'],
        );
      },
    );

    test('a bare array is a list, not a provider without a listing', () async {
      // Some self-hosted OpenAI-compatible servers answer with the array
      // itself. That used to fall through to an empty list, which the form
      // reported as "ce fournisseur ne publie pas la liste de ses modeles" — a
      // false statement about the provider caused by an unknown shape.
      final h = _reader(
        jsonEncode([
          {'id': 'local-llama'},
          {'id': 'local-mistral'},
        ]),
      );

      expect(
        await h.reader.listModels(_provider(AiProviderKind.openAiCompatible)),
        ['local-llama', 'local-mistral'],
      );
    });

    test('a refused key says so, with its code', () async {
      // "Liste des modeles indisponible" and nothing else left no way to tell a
      // rejected key from a wrong address.
      final h = _reader('{"error":{"message":"Invalid API Key"}}', status: 401);

      await expectLater(
        h.reader.listModels(_provider(AiProviderKind.openAiCompatible)),
        throwsA(
          isA<AiReaderException>()
              .having((e) => e.statusCode, 'statusCode', 401)
              .having((e) => e.message, 'message', contains('401')),
        ),
      );
    });

    test('a 404 points at the base URL, which is what is wrong', () async {
      final h = _reader('not found', status: 404);

      await expectLater(
        h.reader.listModels(_provider(AiProviderKind.openAiCompatible)),
        throwsA(
          isA<AiReaderException>().having(
            (e) => e.message,
            'message',
            contains('URL de base'),
          ),
        ),
      );
    });

    test('no message ever carries the key', () async {
      // The scan sends the key in a header; a message that echoed it would put
      // it in the debug log, which has a Copy button.
      for (final status in [401, 403, 404, 429, 500]) {
        final h = _reader('{}', status: status);
        try {
          await h.reader.listModels(_provider(AiProviderKind.openAiCompatible));
          fail('expected a throw for $status');
        } on AiReaderException catch (e) {
          expect(e.message, isNot(contains(_secret)));
        }
      }
    });

    test('a listed model is present', () async {
      final h = _reader(
        jsonEncode({
          'models': [
            {'name': 'models/${defaultModelFor(AiProviderKind.gemini)}'},
          ],
        }),
      );

      expect(
        await h.reader.checkModel(_provider(AiProviderKind.gemini)),
        AiModelCheck.present,
      );
    });

    test('a model absent from a real listing is missing', () async {
      // The T27 case: the provider answers, and the configured id is not there.
      final h = _reader(
        jsonEncode({
          'models': [
            {'name': 'models/un-autre-modele'},
          ],
        }),
      );

      expect(
        await h.reader.checkModel(_provider(AiProviderKind.gemini)),
        AiModelCheck.missing,
      );
    });

    test('a refused key says so instead of blaming the model', () async {
      final h = _reader('{}', status: 401);

      expect(
        await h.reader.checkModel(_provider(AiProviderKind.gemini)),
        AiModelCheck.keyRejected,
      );
    });

    test(
      'a provider with no listing endpoint is unknown, not missing',
      () async {
        // A locally served model usually has no /models. Reporting "your model
        // does not exist" here would send the user editing a correct setting.
        final h = _reader('Not Found', status: 404);

        expect(
          await h.reader.checkModel(_provider(AiProviderKind.openAiCompatible)),
          AiModelCheck.unknown,
        );
      },
    );

    test('an empty listing is unknown, not missing', () async {
      final h = _reader(jsonEncode({'models': []}));

      expect(
        await h.reader.checkModel(_provider(AiProviderKind.gemini)),
        AiModelCheck.unknown,
      );
    });

    test('the check never throws, whatever comes back', () async {
      for (final body in ['', 'pas du json', '[]', '{"models": 3}']) {
        final h = _reader(body);
        expect(
          await h.reader.checkModel(_provider(AiProviderKind.gemini)),
          anyOf(AiModelCheck.unknown, AiModelCheck.missing),
        );
      }
    });
  });
}

/// Stands in for a network failure. `MockClient` needs something to throw, and
/// the reader deliberately does not care what it was.
class SocketExceptionStub implements Exception {
  const SocketExceptionStub();
}
