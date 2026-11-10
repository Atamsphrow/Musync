/// Tests de la bascule entre fournisseurs IA dans la conversation :
/// quand le premier ne répond pas, le suivant est essayé, et l'erreur
/// n'est montrée que si plus aucun ne répond.
///
/// Même cascade que la recherche de paroles (AiFilenameResolver), mais pour
/// l'appel modèle de la conversation (AssistantController._handleCommand),
/// qui n'utilisait que le premier fournisseur utilisable.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:musync/core/services/shared_http_client.dart';
import 'package:musync/features/ai_assistant/data/assistant_controller.dart';
import 'package:musync/features/settings/data/ai_provider_config.dart';
import 'package:musync/features/settings/providers/ai_settings_provider.dart';

final _refProbe = Provider<Ref>((ref) => ref);

/// Réglages figés : pas de fichier, pas de coffre.
class _FakeSettingsStore extends AiSettingsStore {
  final AiSettings _settings;
  _FakeSettingsStore(this._settings);

  @override
  Future<AiSettings> load() async => _settings;
}

/// Client HTTP qui répond par hôte (un fournisseur = un hôte).
class _RoutingClient extends http.BaseClient {
  final Map<String, Object Function()> _byHost;
  final List<String> calledHosts = [];

  _RoutingClient(this._byHost);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    calledHosts.add(request.url.host);
    final fn = _byHost[request.url.host];
    final Object out = fn == null ? http.Response('nope', 404) : fn();
    final r = out as http.Response;
    return http.StreamedResponse(
      Stream.value(r.bodyBytes),
      r.statusCode,
      headers: r.headers,
    );
  }
}

AiProviderConfig _gemini() => AiProviderConfig(
      id: 'gemini',
      name: 'Google Gemini',
      kind: AiProviderKind.gemini,
      baseUrl: 'https://generativelanguage.googleapis.com/v1beta',
      model: 'gemini-2.5-pro',
      apiKey: 'cle-gemini',
    );

AiProviderConfig _openRouter() => AiProviderConfig(
      id: 'openrouter',
      name: 'OpenRouter',
      kind: AiProviderKind.openAiCompatible,
      baseUrl: 'https://openrouter.ai/api/v1',
      model: 'openai/gpt-oss-120b:free',
      apiKey: 'cle-openrouter',
    );

String _chatAnswer(String text) => jsonEncode({
      'choices': [
        {
          'message': {'content': '{"answer": "$text"}'},
        },
      ],
    });

AssistantController _controllerWith({
  required AiSettings settings,
  required http.Client client,
}) {
  final container = ProviderContainer(
    overrides: [
      aiSettingsStoreProvider.overrideWithValue(
        _FakeSettingsStore(settings),
      ),
      sharedHttpClientProvider.overrideWithValue(client),
    ],
  );
  addTearDown(container.dispose);
  return AssistantController(container.read(_refProbe));
}

void main() {
  group('bascule entre fournisseurs', () {
    test('Gemini 404, OpenRouter répond : la commande aboutit', () async {
      final client = _RoutingClient({
        'generativelanguage.googleapis.com':
            () => http.Response('nope', 404),
        'openrouter.ai': () => http.Response(_chatAnswer('42 morceaux.'), 200),
      });
      final controller = _controllerWith(
        settings: AiSettings(providers: [_gemini(), _openRouter()]),
        client: client,
      );

      final outcome = await controller.handleCommand('combien de morceaux ?');

      expect(outcome, isA<AssistantDone>());
      expect((outcome as AssistantDone).message, '42 morceaux.');
      expect(client.calledHosts, [
        'generativelanguage.googleapis.com',
        'openrouter.ai',
      ]);
    });

    test('tous échouent : message combiné nommant les deux', () async {
      final client = _RoutingClient({
        'generativelanguage.googleapis.com':
            () => http.Response('nope', 404),
        'openrouter.ai': () => http.Response('nope', 402),
      });
      final controller = _controllerWith(
        settings: AiSettings(providers: [_gemini(), _openRouter()]),
        client: client,
      );

      final outcome = await controller.handleCommand('combien de morceaux ?');

      expect(outcome, isA<AssistantFailed>());
      final message = (outcome as AssistantFailed).message;
      expect(message, contains('Google Gemini'));
      expect(message, contains('OpenRouter'));
      expect(message, contains(' · '));
      expect(message, contains('404'));
      expect(message, contains('402'));
      expect(client.calledHosts, [
        'generativelanguage.googleapis.com',
        'openrouter.ai',
      ]);
    });

    test('aucun fournisseur utilisable : message existant', () async {
      final client = _RoutingClient({});
      final controller = _controllerWith(
        settings: AiSettings(
          providers: [
            _gemini().copyWith(enabled: false),
            _openRouter().copyWith(apiKey: ''),
          ],
        ),
        client: client,
      );

      final outcome = await controller.handleCommand('combien de morceaux ?');

      expect(outcome, isA<AssistantFailed>());
      expect(
        (outcome as AssistantFailed).message,
        'Aucune clé IA configurée. Ajoutez-en une dans Paramètres › IA.',
      );
      expect(client.calledHosts, isEmpty);
    });

    test('un seul fournisseur en échec : son message nommé', () async {
      final client = _RoutingClient({
        'generativelanguage.googleapis.com':
            () => http.Response('nope', 404),
      });
      final controller = _controllerWith(
        settings: AiSettings(providers: [_gemini()]),
        client: client,
      );

      final outcome = await controller.handleCommand('combien de morceaux ?');

      expect(outcome, isA<AssistantFailed>());
      final message = (outcome as AssistantFailed).message;
      expect(message, contains('Google Gemini'));
      expect(message, contains('ne connaît pas ce modèle'));
      expect(client.calledHosts, ['generativelanguage.googleapis.com']);
    });

    test('Exception générique : enregistrée, le suivant est essayé',
        () async {
      final client = _RoutingClient({
        'generativelanguage.googleapis.com':
            () => throw const FormatException('json cassé'),
        'openrouter.ai': () => http.Response(_chatAnswer('42 morceaux.'), 200),
      });
      final controller = _controllerWith(
        settings: AiSettings(providers: [_gemini(), _openRouter()]),
        client: client,
      );

      final outcome = await controller.handleCommand('combien de morceaux ?');

      expect(outcome, isA<AssistantDone>());
      expect((outcome as AssistantDone).message, '42 morceaux.');
    });

    test('une Error se propage, pas déguisée en « modèle muet »', () async {
      final client = _RoutingClient({
        'generativelanguage.googleapis.com':
            () => throw StateError('plantage interne'),
      });
      final controller = _controllerWith(
        settings: AiSettings(providers: [_gemini(), _openRouter()]),
        client: client,
      );

      await expectLater(
        controller.handleCommand('combien de morceaux ?'),
        throwsA(isA<StateError>()),
      );
    });
  });
}
