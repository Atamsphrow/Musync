// The fallback chain between configured models (T30).
//
// The behaviour worth pinning down is not "it retries" — it is *when* it does
// not. A provider that answers ends the chain even when the answer is empty,
// because "this file name does not say" is a result and asking a second model
// the same unanswerable question buys nothing.
import 'package:flutter_test/flutter_test.dart';
import 'package:musync/features/lyrics/data/ai_filename_reader.dart';
import 'package:musync/features/lyrics/data/ai_filename_resolver.dart';
import 'package:musync/features/lyrics/data/filename_guess.dart';
import 'package:musync/features/settings/data/ai_provider_config.dart';

/// A reader driven by a table: provider id → what it does when asked.
class _ScriptedReader extends AiFilenameReader {
  /// Either a [FilenameGuess] to return or an [AiReaderException] to throw.
  final Map<String, Object> script;

  /// Every provider id asked, in order.
  final List<String> asked = [];

  _ScriptedReader(this.script);

  @override
  Future<FilenameGuess> read({
    required AiProviderConfig provider,
    required String instruction,
    required String fileName,
  }) async {
    asked.add(provider.id);
    final outcome = script[provider.id];
    if (outcome is AiReaderException) throw outcome;
    if (outcome is FilenameGuess) return outcome;
    throw const AiReaderException('rien de prévu pour ce fournisseur');
  }
}

AiProviderConfig _provider(
  String id, {
  bool enabled = true,
  String key = 'k',
}) => AiProviderConfig(
  id: id,
  name: 'Modèle $id',
  kind: AiProviderKind.gemini,
  baseUrl: 'https://exemple.test/v1',
  model: 'modele-$id',
  apiKey: key,
  enabled: enabled,
);

const FilenameGuess _found = (artist: 'Stromae', title: 'Papaoutai');
const FilenameGuess _nothing = (artist: '', title: '');

void main() {
  group('the chain', () {
    test('the first that answers ends it', () async {
      final reader = _ScriptedReader({'a': _found, 'b': _found});
      final settings = AiSettings(providers: [_provider('a'), _provider('b')]);

      final result = await AiFilenameResolver(
        reader,
      ).resolve(settings: settings, fileName: 'x.mp3');

      expect(reader.asked, ['a'], reason: 'b ne doit pas être sollicité');
      expect(result.guess, _found);
      expect(result.providerName, 'Modèle a');
    });

    test('a technical failure moves on to the next', () async {
      // The T28 situation: Gemini 404, and a working key underneath it that the
      // old code never reached.
      final reader = _ScriptedReader({
        'a': const AiReaderException('modèle retiré', statusCode: 404),
        'b': _found,
      });

      final result = await AiFilenameResolver(reader).resolve(
        settings: AiSettings(providers: [_provider('a'), _provider('b')]),
        fileName: 'x.mp3',
      );

      expect(reader.asked, ['a', 'b']);
      expect(result.answered, isTrue);
      expect(result.providerName, 'Modèle b');
    });

    test('it walks the whole chain if it has to', () async {
      final reader = _ScriptedReader({
        'a': const AiReaderException('quota', statusCode: 429),
        'b': const AiReaderException('clé refusée', statusCode: 401),
        'c': _found,
      });

      final result = await AiFilenameResolver(reader).resolve(
        settings: AiSettings(
          providers: [_provider('a'), _provider('b'), _provider('c')],
        ),
        fileName: 'x.mp3',
      );

      expect(reader.asked, ['a', 'b', 'c']);
      expect(result.answered, isTrue);
    });

    test('an empty answer is an answer, and stops the chain', () async {
      // The architectural point of the ticket. A model that read the name and
      // found nothing in it has done its job; the next model would read the
      // same name and find the same nothing.
      final reader = _ScriptedReader({'a': _nothing, 'b': _found});

      final result = await AiFilenameResolver(reader).resolve(
        settings: AiSettings(providers: [_provider('a'), _provider('b')]),
        fileName: 'xyz.mp3',
      );

      expect(reader.asked, ['a']);
      expect(result.answered, isTrue);
      expect(result.guess, _nothing);
    });
  });

  group('when nothing works', () {
    test('it reports once, naming each provider and its own reason', () async {
      final reader = _ScriptedReader({
        'a': const AiReaderException(
          'Modèle inconnu.',
          statusCode: 404,
          model: 'modele-a',
        ),
        'b': const AiReaderException('Quota atteint.', statusCode: 429),
      });

      final result = await AiFilenameResolver(reader).resolve(
        settings: AiSettings(providers: [_provider('a'), _provider('b')]),
        fileName: 'x.mp3',
      );

      expect(result.answered, isFalse);
      expect(result.allFailed, isTrue);
      // Three different causes must not collapse into "l'IA a échoué".
      expect(result.failureSummary, contains('Modèle a'));
      expect(result.failureSummary, contains('404'));
      expect(result.failureSummary, contains('Modèle b'));
      expect(result.failureSummary, contains('429'));
    });

    test('every attempt is recorded, in order', () async {
      // This list is what feeds the per-provider indicators of T28.
      final reader = _ScriptedReader({
        'a': const AiReaderException('non', statusCode: 500),
        'b': _found,
      });

      final result = await AiFilenameResolver(reader).resolve(
        settings: AiSettings(providers: [_provider('a'), _provider('b')]),
        fileName: 'x.mp3',
      );

      expect(result.attempts.map((a) => a.providerId), ['a', 'b']);
      expect(result.attempts.first.ok, isFalse);
      expect(result.attempts.last.ok, isTrue);
      expect(result.attempts.first.model, 'modele-a');
    });
  });

  group('what is not in the chain', () {
    test('no provider configured is not a failure', () async {
      final reader = _ScriptedReader(const {});

      final result = await AiFilenameResolver(
        reader,
      ).resolve(settings: const AiSettings(), fileName: 'x.mp3');

      // Nothing was tried, so there is nothing to report — the caller falls
      // back to the local heuristic silently, which is the normal state for
      // someone who never configured a model.
      expect(result.allFailed, isFalse);
      expect(result.answered, isFalse);
      expect(result.attempts, isEmpty);
    });

    test('a disabled provider is skipped', () async {
      final reader = _ScriptedReader({'a': _found, 'b': _found});

      await AiFilenameResolver(reader).resolve(
        settings: AiSettings(
          providers: [_provider('a', enabled: false), _provider('b')],
        ),
        fileName: 'x.mp3',
      );

      expect(reader.asked, ['b']);
    });

    test('a provider with no key is skipped', () async {
      final reader = _ScriptedReader({'a': _found, 'b': _found});

      await AiFilenameResolver(reader).resolve(
        settings: AiSettings(
          providers: [
            _provider('a', key: '   '),
            _provider('b'),
          ],
        ),
        fileName: 'x.mp3',
      );

      expect(reader.asked, ['b']);
    });

    test('usable keeps the user\'s order', () async {
      final settings = AiSettings(
        providers: [
          _provider('a', enabled: false),
          _provider('b'),
          _provider('c'),
        ],
      );

      // The order is the fallback order, so it has to be the one on screen.
      expect(settings.usable.map((p) => p.id), ['b', 'c']);
      expect(settings.active?.id, 'b');
    });
  });
}
