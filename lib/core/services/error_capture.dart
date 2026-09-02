/// Everything that goes wrong, into the Journal.
///
/// `DebugLog.install` already catches the two obvious channels: Flutter's own
/// build and layout errors, and uncaught asynchronous Dart errors. This file
/// covers the two that were quietly missing.
///
/// **Providers.** A Riverpod provider that throws does not crash anything — it
/// settles into an error state, and the screen watching it renders the exception
/// as text. That is genuinely the right behaviour for the user, and it is why
/// these never reached the log: nothing was uncaught, so nothing was reported.
/// A library scan that fails, a settings file that will not parse, a status
/// sweep that dies halfway — all of them showed up as a line of text on screen
/// and nowhere else.
///
/// **The platform side.** An uncaught exception in Kotlin takes the process down
/// before Dart gets a turn, so the crash that most needs recording is the one
/// the Dart handlers structurally cannot see. `MainActivity` writes it to a file
/// on its way out and [NativeCrashReport.collect] picks it up on the next
/// launch.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:musync/core/services/debug_log.dart';
import 'package:path_provider/path_provider.dart';

/// Reports every provider failure to [DebugLog].
class LoggingProviderObserver extends ProviderObserver {
  const LoggingProviderObserver();

  /// Thrown while the provider was being built.
  @override
  void providerDidFail(
    ProviderBase<Object?> provider,
    Object error,
    StackTrace stackTrace,
    ProviderContainer container,
  ) {
    DebugLog.instance.error(
      'Provider',
      '${_name(provider)} a échoué',
      error: error,
      stackTrace: stackTrace,
    );
  }

  /// An async provider that resolved to an error.
  ///
  /// Separate from [providerDidFail]: a `FutureProvider` whose future rejects
  /// does not "fail to build" — it builds successfully and produces an
  /// `AsyncError`. That is the shape almost every failure in this app takes,
  /// since the library scan, the status sweep and every settings file are async.
  @override
  void didUpdateProvider(
    ProviderBase<Object?> provider,
    Object? previousValue,
    Object? newValue,
    ProviderContainer container,
  ) {
    if (newValue is! AsyncError) return;
    // Only the transition into the error, not every rebuild that carries it
    // forward — otherwise one failed scan logs again on each dependent change.
    if (previousValue is AsyncError && previousValue.error == newValue.error) {
      return;
    }

    DebugLog.instance.error(
      'Provider',
      '${_name(provider)} est en erreur',
      error: newValue.error,
      stackTrace: newValue.stackTrace,
    );
  }

  /// Providers are mostly unnamed in this project, so the runtime type is what
  /// there is to go on. It is still enough to tell a library scan from a
  /// settings load, which is the question being asked.
  static String _name(ProviderBase<Object?> provider) =>
      provider.name ?? provider.runtimeType.toString();
}

/// A crash on the Android side of the app.
///
/// Written by `MainActivity`'s uncaught-exception handler, read back here on the
/// next launch. The file is deleted once it has been logged, so the same crash
/// is not reported at every start for the rest of the app's life.
abstract final class NativeCrashReport {
  /// Must match the name used in `MainActivity.kt`.
  static const String fileName = 'native_crash.txt';

  /// Where Android's `filesDir` is, as Dart sees it. The Kotlin side writes into
  /// `filesDir` directly; `getApplicationSupportDirectory` is a subdirectory of
  /// it, so the parent is what has to be looked in.
  static Future<File?> _file() async {
    try {
      final support = await getApplicationSupportDirectory();
      final parent = support.parent.path;
      final file = File('$parent${Platform.pathSeparator}$fileName');
      return await file.exists() ? file : null;
    } catch (_) {
      return null;
    }
  }

  /// Logs a crash left behind by the previous run, if there was one.
  static Future<void> collect() async {
    if (!Platform.isAndroid) return;
    try {
      final file = await _file();
      if (file == null) return;

      final text = await file.readAsString();
      // Deleted before logging rather than after: if writing the log entry were
      // itself to fail, a crash file that never goes away would report the same
      // stale crash at every launch from now on.
      await file.delete();

      if (text.trim().isEmpty) return;
      DebugLog.instance.error(
        'Android',
        'La session précédente s\'est arrêtée sur une erreur côté Android',
        error: text.trim(),
      );
    } catch (_) {
      // A crash report that cannot be read is not worth a second failure.
    }
  }
}

/// Runs [body] inside a zone that reports what escapes it.
///
/// `PlatformDispatcher.instance.onError` covers uncaught errors once the app is
/// running. This covers the gap before that: anything thrown during `main`
/// itself — a plugin that will not initialise, a platform channel that answers
/// with a `MissingPluginException` — happens before there is a UI to show it in,
/// and would otherwise be a silent exit.
Future<void> runGuarded(Future<void> Function() body) async {
  await runZonedGuarded(body, (error, stack) {
    DebugLog.instance.error(
      'Démarrage',
      'Erreur non capturée',
      error: error,
      stackTrace: stack,
    );
    // Written out immediately: whatever this was, the process may not be around
    // for the two-second debounce.
    unawaited(DebugLog.instance.flush());
  });
}
