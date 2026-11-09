// Tests for AudioBackendCheck.ensureIntercepted.
//
// The old boolean collapsed two opposite outcomes into one `false`:
// "already intercepted, nothing to do" and "no wrapper to restore,
// unfixable". The restore is also verified after the fact now: assigning
// the wrapper back is not proof the interception is in place.
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';
import 'package:musync/core/services/audio_backend_check.dart';

/// A stand-in platform whose name says "background", like the real wrapper's.
class _FakeBackgroundPlatform extends JustAudioPlatform {}

/// A stand-in platform with a plain name.
class _FakePlainPlatform extends JustAudioPlatform {}

void main() {
  final original = JustAudioPlatform.instance;

  tearDown(() {
    JustAudioPlatform.instance = original;
  });

  test('F35: no wrapper captured returns noWrapper, not a silent false', () {
    // Fresh state: nothing captured, plain platform in place.
    expect(AudioBackendCheck.isIntercepted, isFalse);
    expect(
      AudioBackendCheck.ensureIntercepted(),
      AudioBackendRestore.noWrapper,
    );
  });

  test('F35: already intercepted returns alreadyIntercepted', () {
    JustAudioPlatform.instance = _FakeBackgroundPlatform();
    expect(AudioBackendCheck.isIntercepted, isTrue);
    expect(
      AudioBackendCheck.ensureIntercepted(),
      AudioBackendRestore.alreadyIntercepted,
    );
  });

  test('F36: wrapper captured then replaced is restored and verified', () {
    JustAudioPlatform.instance = _FakeBackgroundPlatform();
    AudioBackendCheck.capture();
    JustAudioPlatform.instance = _FakePlainPlatform();
    expect(AudioBackendCheck.isIntercepted, isFalse);

    expect(
      AudioBackendCheck.ensureIntercepted(),
      AudioBackendRestore.restored,
    );
    expect(AudioBackendCheck.isIntercepted, isTrue);
  });
}
