/// Tests de finition de l'assistant IA (T4) : commandes multi-étapes et
/// erreurs propres en français.
///
/// Les outils sont des faux : on teste l'orchestration, pas les providers.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:musync/features/ai_assistant/data/ai_tool.dart';
import 'package:musync/features/ai_assistant/data/ai_tool_registry.dart';
import 'package:musync/features/ai_assistant/data/assistant_bridge.dart';
import 'package:musync/features/ai_assistant/data/assistant_controller.dart';
import 'package:musync/features/lyrics/data/ai_filename_reader.dart';
import 'package:musync/features/settings/data/ai_provider_config.dart';

class _FakeTool extends AiTool {
  @override
  final String name;
  final bool confirm;
  final AiToolResult Function(Map<String, Object?> args) onExecute;
  final List<Map<String, Object?>> calls = [];

  _FakeTool(this.name, {this.confirm = false, required this.onExecute});

  @override
  String get description => 'faux outil de test';

  @override
  Map<String, Object?> get parametersSchema =>
      {'type': 'object', 'properties': const {}};

  @override
  bool get requiresConfirmation => confirm;

  @override
  Future<String> describeAction(
    AiToolContext ctx,
    Map<String, Object?> args,
  ) async =>
      'faux $name';

  @override
  Future<AiToolResult> execute(
    AiToolContext ctx,
    Map<String, Object?> args,
  ) async {
    calls.add(args);
    return onExecute(args);
  }
}

final _refProbe = Provider<Ref>((ref) => ref);

AssistantController _controllerWith(List<AiTool> tools) {
  final container = ProviderContainer();
  addTearDown(container.dispose);
  return AssistantController(
    container.read(_refProbe),
    registry: AiToolRegistry(tools),
  );
}

void main() {
  group('multi-étapes', () {
    test('exécute en séquence et joint les messages', () async {
      final a = _FakeTool('a', onExecute: (_) => AiToolResult.ok('A fait'));
      final b = _FakeTool('b', onExecute: (_) => AiToolResult.ok('B fait'));
      final controller = _controllerWith([a, b]);

      final outcome = await controller.executePlan(
        const AssistantSteps([
          AssistantToolCall('a'),
          AssistantToolCall('b', {'x': 1}),
        ]),
      );

      expect(outcome, isA<AssistantDone>());
      expect((outcome as AssistantDone).message, 'A fait\nB fait');
      expect(a.calls.length, 1);
      expect(b.calls.single, {'x': 1});
    });

    test('arrêt à la première étape en échec', () async {
      final a = _FakeTool(
        'a',
        onExecute: (_) => AiToolResult.fail('A raté'),
      );
      final b = _FakeTool('b', onExecute: (_) => AiToolResult.ok('B fait'));
      final controller = _controllerWith([a, b]);

      final outcome = await controller.executePlan(
        const AssistantSteps([
          AssistantToolCall('a'),
          AssistantToolCall('b'),
        ]),
      );

      expect(outcome, isA<AssistantDone>());
      expect((outcome as AssistantDone).message, 'A raté');
      expect(b.calls, isEmpty);
    });

    test('une étape à confirmation est refusée d’emblée', () async {
      final a = _FakeTool('a', onExecute: (_) => AiToolResult.ok('A fait'));
      final boom = _FakeTool(
        'boom',
        confirm: true,
        onExecute: (_) => AiToolResult.ok('jamais'),
      );
      final controller = _controllerWith([a, boom]);

      final outcome = await controller.executePlan(
        const AssistantSteps([
          AssistantToolCall('a'),
          AssistantToolCall('boom'),
        ]),
      );

      expect(outcome, isA<AssistantFailed>());
      expect(
        (outcome as AssistantFailed).message,
        contains('multi-étapes'),
      );
      expect(a.calls, isEmpty);
      expect(boom.calls, isEmpty);
    });

    test('la navigation de la dernière étape est propagée', () async {
      final a = _FakeTool(
        'a',
        onExecute: (_) => AiToolResult.ok(
          'prêt',
          navigateTo: '/sync',
          navigateArgs: 'args',
        ),
      );
      final controller = _controllerWith([a]);

      final outcome = await controller
          .executePlan(const AssistantSteps([AssistantToolCall('a')]));

      expect(outcome, isA<AssistantDone>());
      final done = outcome as AssistantDone;
      expect(done.navigateTo, '/sync');
      expect(done.navigateArgs, 'args');
    });

    test('outil inconnu dans les étapes : échec avant exécution', () async {
      final a = _FakeTool('a', onExecute: (_) => AiToolResult.ok('A fait'));
      final controller = _controllerWith([a]);
      final outcome = await controller.executePlan(
        const AssistantSteps([
          AssistantToolCall('a'),
          AssistantToolCall('nope'),
        ]),
      );
      expect(outcome, isA<AssistantFailed>());
      expect(
        (outcome as AssistantFailed).message,
        contains('Outil inconnu'),
      );
      // Rien ne s'exécute quand le plan est invalide.
      expect(a.calls, isEmpty);
    });
  });

  group('erreurs propres', () {
    test('answer : texte tel quel', () async {
      final controller = _controllerWith([]);
      final outcome = await controller
          .executePlan(const AssistantAnswer('42 morceaux.'));
      expect((outcome as AssistantDone).message, '42 morceaux.');
    });

    test('serveur en panne (503) : message en français', () async {
      final fake = _FakeClient((_) => http.Response('ko', 503));
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
                e.statusCode == 503 &&
                e.message.contains('en panne'),
          ),
        ),
      );
    });
  });
}

AiProviderConfig _provider() => AiProviderConfig(
      id: 't',
      name: 'Test',
      kind: AiProviderKind.openAiCompatible,
      baseUrl: 'https://test.local/v1',
      model: 'modele-test',
      apiKey: 'cle-test',
    );

class _FakeClient extends http.BaseClient {
  final http.Response Function(http.BaseRequest request) onRequest;
  _FakeClient(this.onRequest);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final r = onRequest(request);
    return http.StreamedResponse(
      Stream.value(r.bodyBytes),
      r.statusCode,
      headers: r.headers,
    );
  }
}
