/// Tests de searchFilterFor : une commande IA (`!...`) ne doit pas filtrer la
/// bibliothèque pendant la frappe — seul le submit la déclenche.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:musync/features/library/ui/library_screen.dart';

void main() {
  group('searchFilterFor', () {
    test('une commande ! ne filtre pas', () {
      expect(searchFilterFor('!mets en pause'), '');
      expect(searchFilterFor('!'), '');
      expect(searchFilterFor('  !joue du juice  '), '');
    });

    test('une recherche normale filtre', () {
      expect(searchFilterFor('juice'), 'juice');
      expect(searchFilterFor('  juice  '), '  juice  ');
      expect(searchFilterFor(''), '');
    });

    test('! au milieu du texte : c’est une recherche', () {
      expect(searchFilterFor('rock ! live'), 'rock ! live');
    });
  });
}
