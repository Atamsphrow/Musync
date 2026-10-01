// The app is foregrounded at startup; the bubble visibility rules build on it.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musync/features/player/providers/player_provider.dart';

void main() {
  test('the app starts foregrounded', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    expect(container.read(appForegroundProvider), isTrue);
  });

  test('the foreground flag can be flipped both ways', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(appForegroundProvider.notifier).state = false;
    expect(container.read(appForegroundProvider), isFalse);
    container.read(appForegroundProvider.notifier).state = true;
    expect(container.read(appForegroundProvider), isTrue);
  });
}
