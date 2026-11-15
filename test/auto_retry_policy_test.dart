import 'package:flutter_test/flutter_test.dart';
import 'package:musync/features/lyrics/ui/lyrics_search_screen.dart';

/// Le 2e essai automatique de l'écran de recherche : la décision pure.
bool _decide({
  bool cancelled = false,
  bool loading = false,
  bool hasError = false,
  bool hasResults = false,
  bool hasSyncedResult = false,
  bool fieldsChanged = false,
}) => shouldAutoRetryWithGuess(
  cancelled: cancelled,
  loading: loading,
  hasError: hasError,
  hasResults: hasResults,
  hasSyncedResult: hasSyncedResult,
  fieldsChanged: fieldsChanged,
);

void main() {
  group('shouldAutoRetryWithGuess', () {
    test('zéro résultat : 2e essai (comportement conservé)', () {
      expect(_decide(), isTrue);
    });

    test('résultats partiels sans aucune synchro : 2e essai', () {
      expect(_decide(hasResults: true, hasSyncedResult: false), isTrue);
    });

    test('au moins une parole synchronisée : pas de 2e essai', () {
      expect(_decide(hasResults: true, hasSyncedResult: true), isFalse);
    });

    test('annulation par le × : pas de 2e essai, même sans résultat', () {
      expect(_decide(cancelled: true), isFalse);
      expect(_decide(cancelled: true, hasResults: true), isFalse);
    });

    test('correction manuelle entre-temps : pas de 2e essai', () {
      expect(_decide(fieldsChanged: true), isFalse);
      expect(_decide(fieldsChanged: true, hasResults: true), isFalse);
    });

    test('recherche en cours : pas de 2e essai', () {
      expect(_decide(loading: true), isFalse);
      expect(_decide(loading: true, hasResults: true), isFalse);
    });

    test('erreur de recherche : pas de 2e essai', () {
      expect(_decide(hasError: true), isFalse);
      expect(_decide(hasError: true, hasResults: true), isFalse);
    });

    test('une garde bloquante l\'emporte sur le critère de résultats', () {
      expect(
        _decide(
          cancelled: true,
          hasResults: true,
          hasSyncedResult: false,
          fieldsChanged: true,
        ),
        isFalse,
      );
    });
  });
}
