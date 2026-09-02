/// In-app log of what went wrong (plan T9).
///
/// Musync's riskiest work — rewriting tags inside the user's own music files —
/// happens on a sideloaded app on a device that is rarely plugged into a
/// laptop. When an embed fails there, the exception goes to logcat and nobody
/// ever sees it. This keeps the last few hundred entries in memory so the
/// Settings screen can show them and hand over a copyable report.
library;

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'package:musync/core/utils/atomic_file.dart';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

enum LogLevel { info, warning, error }

@immutable
class LogEntry {
  final DateTime time;
  final LogLevel level;

  /// Where it came from — 'Id3Writer', 'MediaStore', 'LRCLIB'. Free-form, but
  /// worth keeping to a handful of values so a report can be skimmed.
  final String source;

  final String message;
  final String? details;

  const LogEntry({
    required this.time,
    required this.level,
    required this.source,
    required this.message,
    this.details,
  });

  Map<String, Object?> toJson() => {
    't': time.toIso8601String(),
    'l': level.index,
    's': source,
    'm': message,
    if (details != null) 'd': details,
  };

  /// Null for a record this version can't make sense of, so one bad line
  /// cannot cost the whole log.
  static LogEntry? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final time = DateTime.tryParse('${raw['t']}');
    final level = raw['l'];
    if (time == null || level is! int) return null;
    if (level < 0 || level >= LogLevel.values.length) return null;

    return LogEntry(
      time: time,
      level: LogLevel.values[level],
      source: '${raw['s'] ?? '?'}',
      message: '${raw['m'] ?? ''}',
      details: raw['d'] == null ? null : '${raw['d']}',
    );
  }

  /// One entry as it appears in the copied report.
  String format() {
    final stamp = time.toIso8601String();
    final tag = switch (level) {
      LogLevel.info => 'INFO ',
      LogLevel.warning => 'WARN ',
      LogLevel.error => 'ERROR',
    };
    final head = '$stamp  $tag  [$source]  $message';
    if (details == null || details!.isEmpty) return head;
    // Indented so a stack trace reads as belonging to the line above it.
    return '$head\n${details!.split('\n').map((l) => '    $l').join('\n')}';
  }
}

/// The log itself.
///
/// A bounded queue, not a growing list: this runs for the whole life of the
/// process, and an unbounded buffer behind a UI nobody opens is a slow leak.
/// The oldest entries go first, since a failure is diagnosed from what happened
/// just before it.
class DebugLog extends ChangeNotifier {
  DebugLog._();

  static final DebugLog instance = DebugLog._();

  static const int _capacity = 400;

  /// Kept across launches, which is the only way it is any use.
  ///
  /// The crash worth diagnosing is usually the one that took the app down —
  /// and an in-memory log dies with it, so by the time the user opens the panel
  /// there is nothing left to copy.
  static const String _fileName = 'debug_log.json';

  /// Writes are debounced rather than immediate: a burst of errors is the norm,
  /// not the exception, and rewriting the file on each one would turn a bad
  /// moment into a slow one.
  static const Duration _flushDelay = Duration(seconds: 2);

  final Queue<LogEntry> _entries = Queue<LogEntry>();
  Timer? _flushTimer;

  /// Newest first, which is the order the panel reads in.
  List<LogEntry> get entries => _entries.toList().reversed.toList();

  bool get isEmpty => _entries.isEmpty;

  void add(
    LogLevel level,
    String source,
    String message, {
    Object? error,
    StackTrace? stackTrace,
  }) {
    final details = [
      if (error != null) '$error',
      if (stackTrace != null) '$stackTrace',
    ].join('\n');

    _entries.addLast(
      LogEntry(
        time: DateTime.now(),
        level: level,
        source: source,
        message: message,
        details: details.isEmpty ? null : details,
      ),
    );
    while (_entries.length > _capacity) {
      _entries.removeFirst();
    }

    // Still worth printing in debug: a developer with a cable attached should
    // not have to open the app's own UI to read its errors.
    if (kDebugMode) debugPrint('[$source] $message');

    _scheduleFlush();
    notifyListeners();
  }

  // ── Persistence ──

  Future<File> _file() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}${Platform.pathSeparator}$_fileName');
  }

  void _scheduleFlush() {
    _flushTimer?.cancel();
    _flushTimer = Timer(_flushDelay, flush);
  }

  /// Writes the log out now. Called on a debounce, and worth calling directly
  /// before anything that might not come back.
  Future<void> flush() async {
    _flushTimer?.cancel();
    _flushTimer = null;

    try {
      await AtomicFile.writeString(
        await _file(),
        jsonEncode([for (final entry in _entries) entry.toJson()]),
      );
    } catch (_) {
      // A log that cannot be written must not become a second problem on top of
      // whatever it was recording.
    }
  }

  Future<void> _restore() async {
    try {
      final file = await _file();
      if (!await file.exists()) return;

      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! List) return;

      final restored = decoded
          .map(LogEntry.fromJson)
          .whereType<LogEntry>()
          .toList();
      if (restored.isEmpty) return;

      // In front of anything logged during startup, so the file stays in
      // chronological order even though the restore lands a moment late.
      final current = List<LogEntry>.from(_entries);
      _entries
        ..clear()
        ..addAll(restored)
        ..addAll(current);
      while (_entries.length > _capacity) {
        _entries.removeFirst();
      }

      notifyListeners();
    } catch (_) {
      // Nothing readable on disk: start clean rather than refuse to start.
    }
  }

  void info(String source, String message) =>
      add(LogLevel.info, source, message);

  /// Keys already reported by [once], so a repeat is dropped.
  final Set<String> _reportedOnce = <String>{};

  /// Logs the first occurrence of [key] and ignores the rest.
  ///
  /// For failures that happen per track. Artwork that cannot be decoded is the
  /// case this exists for: a library of 1876 files with a codec Flutter dislikes
  /// would post 1876 identical lines, and since the buffer holds 400 it would
  /// push out every entry that mattered. One line says the same thing, and
  /// leaves room for the errors worth reading.
  ///
  /// The set is per process. A restart reports again, which is right — it is
  /// evidence about *this* run.
  void once(
    String key,
    LogLevel level,
    String source,
    String message, {
    Object? error,
  }) {
    if (!_reportedOnce.add(key)) return;
    add(level, source, message, error: error);
  }

  void warning(String source, String message, {Object? error}) =>
      add(LogLevel.warning, source, message, error: error);

  void error(
    String source,
    String message, {
    Object? error,
    StackTrace? stackTrace,
  }) => add(
    LogLevel.error,
    source,
    message,
    error: error,
    stackTrace: stackTrace,
  );

  void clear() {
    _entries.clear();
    // Otherwise a `once` key already used would never be reported again, and
    // clearing the log to reproduce a problem would hide the very line the user
    // was trying to capture.
    _reportedOnce.clear();
    notifyListeners();
    // Not just the buffer: leaving the file behind would resurrect everything
    // on the next launch, which is not what "vider" means to anyone.
    unawaited(flush());
  }

  /// The whole log as one string, for the Copy button.
  String report() {
    if (_entries.isEmpty) return 'Journal vide.';
    return [
      'Musync — journal de débogage',
      'Généré le ${DateTime.now().toIso8601String()}',
      '${_entries.length} entrée(s)',
      '',
      // Oldest first here, unlike the on-screen list: a report is read as a
      // story, from what happened first.
      for (final entry in _entries) entry.format(),
    ].join('\n');
  }

  /// Routes Flutter's own errors here as well as to the console.
  ///
  /// Called once from `main`. Without it the panel would only ever show what
  /// Musync thought to report, and miss precisely the crashes nobody
  /// anticipated — which are the ones worth having a report for.
  static void install() {
    // Not awaited: startup must not wait on a disk read, and anything logged
    // in the meantime is merged in front of what comes back.
    unawaited(instance._restore());

    final previous = FlutterError.onError;
    FlutterError.onError = (details) {
      instance.error(
        'Flutter',
        details.exceptionAsString(),
        stackTrace: details.stack,
      );
      previous?.call(details);
    };

    PlatformDispatcher.instance.onError = (error, stack) {
      instance.error(
        'Dart',
        'Exception non capturée',
        error: error,
        stackTrace: stack,
      );
      // False: the error is recorded, not handled. Swallowing it here would
      // hide it from anything else watching.
      return false;
    };
  }
}
