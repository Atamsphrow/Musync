/// Correctifs des lots I/J (basses confirmées, automatisation / sauvegarde) :
/// - E5  : `drainAndRun` vide toute la file native (boucle), pas un seul id.
///         Non testable ici : `takeScheduledAction` rend null hors Android
///         (`Platform.isAndroid`), la boucle est vérifiée par lecture.
/// - I7  : `fromJson` matérialise `args` (`Map.of`, pas `cast` paresseux).
/// - I8  : les deux `fromJson` journalisent avant de retourner null.
/// - I9  : copie défensive de `args` dans `scheduleOnce` / `scheduleDaily` /
///         `setHeadphoneTrigger`.
/// - I10 : ids uniques (suffixe compteur, pas seulement l'horloge).
/// - I12 : `AutomationStore.save()` en échec : journalisé ET propagé.
/// - I20 : `ExcludedDirsStore.save()` aller-retour (même garde que `load`).
/// - I21 : exclure la racine `/` exclut bien tout.
library;

import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musync/features/ai_assistant/data/automation.dart';
import 'package:musync/features/ai_assistant/data/automation_store.dart';
import 'package:musync/features/ai_assistant/providers/automation_provider.dart';
import 'package:musync/features/library/data/excluded_dirs_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('I7 fromJson matérialise args', () {
    Map<String, Object?> actionJson(Object? args) => {
          'id': 'x',
          'daily': false,
          'fireAtMillis': 999,
          'hour': 7,
          'minute': 0,
          'toolName': 'play',
          'args': args,
          'label': 'Réveil',
          'enabled': true,
        };

    test('clé non-String dans args → null, pas d’action à moitié construite',
        () {
      // Avec `cast` (vue paresseuse), l'erreur ne sortait qu'à l'accès,
      // hors du try : l'action était construite avec des args piégés.
      expect(ScheduledAction.fromJson(actionJson({1: 'a'})), isNull);
      expect(
        HeadphoneTrigger.fromJson({
          'toolName': 'play',
          'args': {
            1: 'a',
          },
          'label': 'Casque',
        }),
        isNull,
      );
    });

    test('les args parsés sont une copie, pas la Map source', () {
      final rawArgs = <Object?, Object?>{'query': 'Nuit'};
      final action = ScheduledAction.fromJson(actionJson(rawArgs));
      expect(action, isNotNull);
      rawArgs['query'] = 'Jour';
      expect(action!.args['query'], 'Nuit');
    });

    test('args valides : aller-retour inchangé', () {
      final action =
          ScheduledAction.fromJson(actionJson({'minutes': 30}));
      expect(action!.args['minutes'], 30);
    });
  });

  group('I8 fromJson malformé → null sans lever', () {
    test('action sans id', () {
      expect(ScheduledAction.fromJson({'toolName': 'play'}), isNull);
    });

    test('déclencheur sans label', () {
      expect(HeadphoneTrigger.fromJson({'toolName': 'play'}), isNull);
    });
  });

  group('I9/I10 provider', () {
    late _MemoryStore store;

    setUp(() {
      store = _MemoryStore();
    });

    Future<ProviderContainer> container() async {
      final container = ProviderContainer(
        overrides: [automationStoreProvider.overrideWithValue(store)],
      );
      addTearDown(container.dispose);
      await container.read(automationsProvider.future);
      return container;
    }

    test('I9 scheduleOnce : la Map appelante ne modifie plus l’action',
        () async {
      final c = await container();
      final args = <String, Object?>{'query': 'Nuit'};
      await c.read(automationsProvider.notifier).scheduleOnce(
            at: DateTime.now().add(const Duration(hours: 1)),
            tool: 'play',
            args: args,
            label: 'Réveil',
          );
      args['query'] = 'Jour';
      args['extra'] = true;
      final stored =
          c.read(automationsProvider).value!.actions.single;
      expect(stored.args, {'query': 'Nuit'});
    });

    test('I9 scheduleDaily + setHeadphoneTrigger : même copie', () async {
      final c = await container();
      final args = <String, Object?>{'minutes': 30};
      await c.read(automationsProvider.notifier).scheduleDaily(
            hour: 22,
            minute: 0,
            tool: 'sleep_timer',
            args: args,
            label: 'Minuteur',
          );
      final triggerArgs = <String, Object?>{'query': 'Nuit'};
      await c.read(automationsProvider.notifier).setHeadphoneTrigger(
            tool: 'play',
            args: triggerArgs,
            label: 'Casque',
          );
      args['minutes'] = 5;
      triggerArgs['query'] = 'Jour';
      final doc = c.read(automationsProvider).value!;
      expect(doc.actions.single.args, {'minutes': 30});
      expect(doc.headphoneTrigger!.args, {'query': 'Nuit'});
    });

    test('I10 deux scheduleOnce rapprochés : ids distincts', () async {
      final c = await container();
      final at = DateTime.now().add(const Duration(hours: 1));
      final a = await c.read(automationsProvider.notifier).scheduleOnce(
            at: at,
            tool: 'play',
            label: 'Un',
          );
      final b = await c.read(automationsProvider.notifier).scheduleOnce(
            at: at,
            tool: 'play',
            label: 'Deux',
          );
      expect(a.id, isNot(b.id));
    });

    test('I10 deux scheduleDaily rapprochés : ids distincts', () async {
      final c = await container();
      final notifier = c.read(automationsProvider.notifier);
      final a = await notifier.scheduleDaily(
        hour: 22,
        minute: 0,
        tool: 'sleep_timer',
        label: 'Un',
      );
      final b = await notifier.scheduleDaily(
        hour: 22,
        minute: 0,
        tool: 'sleep_timer',
        label: 'Deux',
      );
      expect(a.id, isNot(b.id));
    });
  });

  group('I12 AutomationStore.save', () {
    test('échec d’écriture : propage, load reste protégé', () async {
      final dir = Directory.systemTemp.createTempSync('musync_auto_ij');
      addTearDown(() => dir.deleteSync(recursive: true));
      // Le parent est un fichier, pas un dossier : la création du
      // répertoire parent échoue, donc l'écriture aussi.
      final blocker = File('${dir.path}/blocker')..writeAsStringSync('x');
      final store = AutomationStore(
        fileLocator: () async => File('${blocker.path}/automations.json'),
      );
      await expectLater(
        store.save(const AutomationsDoc()),
        throwsA(isA<FileSystemException>()),
      );
      expect((await store.load()).actions, isEmpty);
    });
  });

  group('I20/I21 ExcludedDirsStore', () {
    test('I20 save/load aller-retour', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final store = ExcludedDirsStore(prefsOverride: prefs);
      await store.save(['/Musique', '/Podcasts/']);
      expect(await store.load(), ['/Musique', '/Podcasts']);
    });

    test('I21 la racine / exclut tout', () {
      expect(ExcludedDirsStore.isExcluded('/a.mp3', ['/']), isTrue);
      expect(
        ExcludedDirsStore.isExcluded('/sdcard/Musique/a.mp3', ['/']),
        isTrue,
      );
      expect(ExcludedDirsStore.normalise('/'), '/');
    });

    test('I21 hors racine : préfixe à la frontière de segment', () {
      expect(
        ExcludedDirsStore.isExcluded(
          '/sdcard/Musique/a.mp3',
          ['/sdcard/Musique'],
        ),
        isTrue,
      );
      expect(
        ExcludedDirsStore.isExcluded(
          '/sdcard/Musique2/a.mp3',
          ['/sdcard/Musique'],
        ),
        isFalse,
      );
    });
  });
}

class _MemoryStore extends AutomationStore {
  AutomationsDoc doc = const AutomationsDoc();

  @override
  Future<AutomationsDoc> load() async => doc;

  @override
  Future<void> save(AutomationsDoc next) async {
    doc = next;
  }
}
