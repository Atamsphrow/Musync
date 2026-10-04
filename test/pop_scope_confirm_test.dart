// Verifies the exact PopScope discard-confirmation pattern used by
// TagEditorScreen: back with changes shows the dialog, "Continuer" stays,
// "Abandonner" pops. Written against a minimal widget with the same PopScope
// shape because the real editor's async file load cannot run under
// FakeAsync.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Mirrors TagEditorScreen's PopScope block 1:1.
class _ConfirmingPage extends StatefulWidget {
  const _ConfirmingPage();

  @override
  State<_ConfirmingPage> createState() => _ConfirmingPageState();
}

class _ConfirmingPageState extends State<_ConfirmingPage> {
  bool _hasChanges = false;

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_hasChanges,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final leave = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Abandonner les modifications ?'),
            content: const Text(
              'Les tags modifiés ne seront pas enregistrés.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Continuer'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Abandonner'),
              ),
            ],
          ),
        );
        if (leave == true && context.mounted) {
          Navigator.pop(context);
        }
      },
      child: Scaffold(
        appBar: AppBar(title: const Text('Page')),
        body: TextButton(
          onPressed: () => setState(() => _hasChanges = true),
          child: const Text('modifier'),
        ),
      ),
    );
  }
}

void main() {
  testWidgets('discard confirmation pops only on Abandonner', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: Text('derrière')),
      ),
    );
    // Push the confirming page on top.
    final context = tester.element(find.text('derrière'));
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const _ConfirmingPage()),
    );
    await tester.pumpAndSettle();
    expect(find.text('Page'), findsOneWidget);

    // Back with no changes: leaves immediately, no dialog.
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.text('Abandonner les modifications ?'), findsNothing);
    expect(find.text('derrière'), findsOneWidget);

    // Push again, make a change.
    Navigator.of(tester.element(find.text('derrière'))).push(
      MaterialPageRoute(builder: (_) => const _ConfirmingPage()),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('modifier'));
    await tester.pump();

    // Back with changes: dialog appears.
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.text('Abandonner les modifications ?'), findsOneWidget);

    // "Continuer" stays.
    await tester.tap(find.text('Continuer'));
    await tester.pumpAndSettle();
    expect(find.text('Page'), findsOneWidget);

    // "Abandonner" pops the page.
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Abandonner'));
    await tester.pumpAndSettle();
    expect(find.text('Page'), findsNothing);
    expect(find.text('derrière'), findsOneWidget);
  });
}
