/// Tests du pont LLM de l'assistant IA (T2) : prompt système, mémoire courte,
/// parse strict, protocole HTTP avec réponses enregistrées.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:musync/features/ai_assistant/data/assistant_bridge.dart';
import 'package:musync/features/ai_assistant/data/assistant_controller.dart';
import 'package:musync/features/lyrics/data/ai_filename_reader.dart';
import 'package:musync/features/settings/data/ai_provider_config.dart';

AiProviderConfig _provider({String baseUrl = 'https://test.local/v1'}) =>
    AiProviderConfig(
      id: 't',
      name: 'Test',
      kind: AiProviderKind.openAiCompatible,
      baseUrl: baseUrl,
      model: 'modele-test',
      apiKey: 'cle-test',
    );

String _chatResponse(String content) => jsonEncode({
      'choices': [
        {
          'message': {'content': content},
        },
      ],
    });

/// Client HTTP factice : rejoue des réponses enregistrées.
class _FakeClient extends http.BaseClient {
  final http.Response Function(http.BaseRequest request) onRequest;
  http.BaseRequest? lastRequest;
  String? lastBody;

  _FakeClient(this.onRequest);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    lastRequest = request;
    if (request is http.Request) lastBody = request.body;
    final r = onRequest(request);
    return http.StreamedResponse(
      Stream.value(r.bodyBytes),
      r.statusCode,
      headers: r.headers,
    );
  }
}

final _refProbe = Provider<Ref>((ref) => ref);

AssistantController _controller() {
  final container = ProviderContainer();
  return AssistantController(container.read(_refProbe));
}

void main() {
  group('prompt système', () {
    test('contient les outils, l\u2019heure et la consigne JSON', () {
      final prompt = AssistantBridge.systemPrompt(
        '- pause: Met la lecture en pause.\n  Args: {}',
        now: DateTime(2026, 10, 8, 6, 12),
      );
      expect(prompt, contains('pause'));
      expect(prompt, contains('JSON'));
      expect(prompt, contains('jeudi 8 octobre 2026, 06:12'));
      expect(prompt, contains('{"tool"'));
      expect(prompt, contains('{"answer"'));
      expect(prompt, isNot(contains('cle-test')));
    });

    test('ne fuit jamais la clé', () {
      final prompt = AssistantBridge.systemPrompt('', now: DateTime.now());
      expect(prompt, isNot(contains('Bearer')));
      expect(prompt, isNot(contains('apiKey')));
    });
  });

  group('mémoire courte', () {
    test('garde les 6 derniers échanges', () {
      final history = AssistantHistory();
      for (var i = 0; i < 10; i++) {
        history.add('q$i', 'r$i');
      }
      final messages = history.messages;
      expect(messages.length, 12);
      expect(messages.first.content, 'q4');
      expect(messages.last.content, 'r9');
    });

    test('ordre user puis assistant', () {
      final history = AssistantHistory();
      history.add('bonjour', '{"answer": "salut"}');
      expect(history.messages[0].role, 'user');
      expect(history.messages[1].role, 'assistant');
    });
  });

  group('parse strict', () {
    test('appel d\u2019outil valide', () {
      final plan =
          _controller().parsePlan('{"tool": "pause", "args": {}}');
      expect(plan, isA<AssistantToolCall>());
      final call = plan as AssistantToolCall;
      expect(call.tool, 'pause');
      expect(call.args, isEmpty);
    });

    test('réponse texte', () {
      final plan = _controller()
          .parsePlan('{"answer": "42 morceaux sans paroles."}');
      expect(plan, isA<AssistantAnswer>());
      expect((plan as AssistantAnswer).text, contains('42'));
    });

    test('étapes multiples', () {
      final plan = _controller().parsePlan(
        '{"steps": [{"tool": "pause", "args": {}}, '
        '{"tool": "sleep_timer", "args": {"minutes": 20}}]}',
      );
      expect(plan, isA<AssistantSteps>());
      final steps = (plan as AssistantSteps).steps;
      expect(steps.length, 2);
      expect(steps[1].args['minutes'], 20);
    });

    test('pas du JSON : erreur claire', () {
      expect(
        () => _controller().parsePlan('Mets en pause s\u2019il te plaît'),
        throwsA(isA<AssistantParseError>()),
      );
    });

    test('outil inconnu : jamais d\u2019exécution aveugle', () {
      expect(
        () => _controller()
            .parsePlan('{"tool": "lance_des_missiles", "args": {}}'),
        throwsA(
          predicate(
            (e) =>
                e is AssistantParseError &&
                e.message.contains('Outil inconnu'),
          ),
        ),
      );
    });

    test('argument halluciné : refusé', () {
      expect(
        () => _controller()
            .parsePlan('{"tool": "pause", "args": {"vitesse": 2}}'),
        throwsA(
          predicate(
            (e) =>
                e is AssistantParseError &&
                e.message.contains('Argument inconnu'),
          ),
        ),
      );
    });

    test('answer déguisé en outil : intercepté avant la résolution', () {
      // Bug appareil : le modèle a renvoyé {"tool": "answer", ...} et la
      // snackbar a affiché « Outil inconnu : « answer » ». Le texte doit
      // sortir en réponse, sans qu'aucun outil soit cherché ni exécuté.
      final plan = _controller().parsePlan(
        '{"tool": "answer", "args": {"text": "Je ne peux pas créer de file synchronisée."}}',
      );
      expect(plan, isA<AssistantAnswer>());
      expect(
        (plan as AssistantAnswer).text,
        'Je ne peux pas créer de file synchronisée.',
      );
    });

    test('answer déguisé : autres clés de texte acceptées', () {
      final plan = _controller().parsePlan(
        '{"tool": "answer", "args": {"message": "voilà"}}',
      );
      expect((plan as AssistantAnswer).text, 'voilà');
    });

    test('answer déguisé sans texte : refusé', () {
      expect(
        () => _controller().parsePlan('{"tool": "answer", "args": {}}'),
        throwsA(isA<AssistantParseError>()),
      );
    });

    test('forme inconnue : refusée', () {
      expect(
        () => _controller().parsePlan('{"blabla": 1}'),
        throwsA(isA<AssistantParseError>()),
      );
    });

    test('answer vide : refusée', () {
      expect(
        () => _controller().parsePlan('{"answer": "  "}'),
        throwsA(isA<AssistantParseError>()),
      );
    });
  });

  group('protocole HTTP', () {
    test('POST /chat/completions avec le bon corps', () async {
      final fake = _FakeClient(
        (_) => http.Response(_chatResponse('{"tool":"pause","args":{}}'), 200),
      );
      final bridge = AssistantBridge(client: fake);
      final raw = await bridge.complete(
        provider: _provider(),
        system: 'sys',
        history: const [
          AssistantExchange(role: 'user', content: 'q'),
          AssistantExchange(role: 'assistant', content: 'r'),
        ],
        userText: 'mets en pause',
      );
      expect(raw, contains('pause'));
      expect(fake.lastRequest!.url.toString(),
          'https://test.local/v1/chat/completions');
      final body = jsonDecode(fake.lastBody!) as Map<String, Object?>;
      expect(body['model'], 'modele-test');
      expect(
        (body['response_format'] as Map)['type'],
        'json_object',
      );
      final messages = body['messages'] as List;
      expect(messages.length, 4); // system + 2 historique + user
      expect((messages.first as Map)['role'], 'system');
      expect(fake.lastRequest!.headers['Authorization'], 'Bearer cle-test');
    });

    test('baseUrl avec slash final : pas de double slash', () async {
      final fake = _FakeClient(
        (_) => http.Response(_chatResponse('{}'), 200),
      );
      await AssistantBridge(client: fake).complete(
        provider: _provider(baseUrl: 'https://test.local/v1/'),
        system: 'sys',
        history: const [],
        userText: 'x',
      );
      expect(fake.lastRequest!.url.toString(),
          'https://test.local/v1/chat/completions');
    });

    test('401 : clé refusée, en français', () async {
      final fake = _FakeClient((_) => http.Response('nope', 401));
      await expectLater(
        AssistantBridge(client: fake).complete(
          provider: _provider(),
          system: 'sys',
          history: const [],
          userText: 'x',
        ),
        throwsA(
          predicate(
            (e) =>
                e is AiReaderException &&
                e.statusCode == 401 &&
                e.message.contains('Clé refusée'),
          ),
        ),
      );
    });

    test('404 : modèle inconnu', () async {
      final fake = _FakeClient((_) => http.Response('nope', 404));
      await expectLater(
        AssistantBridge(client: fake).complete(
          provider: _provider(),
          system: 'sys',
          history: const [],
          userText: 'x',
        ),
        throwsA(
          predicate(
            (e) =>
                e is AiReaderException &&
                e.statusCode == 404 &&
                e.message.contains('Paramètres › IA'),
          ),
        ),
      );
    });

    test('réseau coupé : injoignable, sans fuite', () async {
      final fake = _FakeClient((_) => throw const SocketExceptionFake());
      await expectLater(
        AssistantBridge(client: fake).complete(
          provider: _provider(),
          system: 'sys',
          history: const [],
          userText: 'x',
        ),
        throwsA(
          predicate(
            (e) =>
                e is AiReaderException &&
                e.message.contains('injoignable') &&
                !e.message.contains('cle-test'),
          ),
        ),
      );
    });

    test('réponse sans choices : modèle muet', () async {
      final fake = _FakeClient((_) => http.Response('{"x": 1}', 200));
      await expectLater(
        AssistantBridge(client: fake).complete(
          provider: _provider(),
          system: 'sys',
          history: const [],
          userText: 'x',
        ),
        throwsA(
          predicate((e) => e is AiReaderException && e.noAnswer),
        ),
      );
    });
  });
}

/// SocketException ne se construit pas avec un const simple en test pur ;
/// un leurre qui joue le même rôle (exception synchrone du client).
class SocketExceptionFake implements Exception {
  const SocketExceptionFake();
}
