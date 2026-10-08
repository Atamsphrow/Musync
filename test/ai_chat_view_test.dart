/// Widget test d'AiChatView : bulles utilisateur/assistant, indicateur de
/// frappe, état vide.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musync/features/ai_assistant/ui/ai_chat_view.dart';

Widget _wrap(Widget child) => MaterialApp(
      home: Scaffold(
        body: SizedBox(
          height: 600,
          child: child,
        ),
      ),
    );

AiChatView _view({
  List<ChatMessage> messages = const [],
  bool thinking = false,
}) =>
    AiChatView(
      messages: messages,
      thinking: thinking,
      scrollController: ScrollController(),
    );

void main() {
  testWidgets('état vide : aide affichée', (tester) async {
    await tester.pumpWidget(_wrap(_view()));
    expect(find.textContaining('Tape ta commande'), findsOneWidget);
  });

  testWidgets('bulle utilisateur à droite, bulle IA à gauche', (tester) async {
    await tester.pumpWidget(_wrap(_view(messages: const [
      ChatMessage(role: ChatRole.user, text: 'mets en pause'),
      ChatMessage(role: ChatRole.assistant, text: 'En pause.'),
    ])));
    await tester.pumpAndSettle();

    final userBubble = find.ancestor(
      of: find.text('mets en pause'),
      matching: find.byType(Align),
    );
    expect(
      tester.widget<Align>(userBubble).alignment,
      Alignment.centerRight,
    );

    final aiBubble = find.ancestor(
      of: find.text('En pause.'),
      matching: find.byType(Align),
    );
    expect(
      tester.widget<Align>(aiBubble).alignment,
      Alignment.centerLeft,
    );
  });

  testWidgets('indicateur de frappe affiché quand thinking', (tester) async {
    await tester.pumpWidget(_wrap(_view(
      messages: const [ChatMessage(role: ChatRole.user, text: 'pause')],
      thinking: true,
    )));
    await tester.pump();
    expect(find.text('L’IA réfléchit…'), findsOneWidget);
  });

  testWidgets('pas d’indicateur quand la réponse est arrivée', (tester) async {
    await tester.pumpWidget(_wrap(_view(
      messages: const [
        ChatMessage(role: ChatRole.user, text: 'pause'),
        ChatMessage(role: ChatRole.assistant, text: 'En pause.'),
      ],
    )));
    await tester.pumpAndSettle();
    expect(find.text('L’IA réfléchit…'), findsNothing);
    expect(find.text('En pause.'), findsOneWidget);
  });
}
