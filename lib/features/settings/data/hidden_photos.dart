/// The pictures behind the twelve taps, their order, and where the cycle stands.
///
/// Discovered from the asset bundle rather than listed here, so adding one is
/// dropping `tatiana13.jpg` next to the others and rebuilding — no code change,
/// no list to keep in step with the folder. `pubspec.yaml` already declares
/// `assets/images/` as a directory, so a new file is picked up on its own.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:musync/core/utils/atomic_file.dart';
import 'package:path_provider/path_provider.dart';

/// Remembers how far through the cycle the last session got.
///
/// The file is named for what it is — a scrap of interface state — and nothing
/// else. It sits in the app's private storage, where no other app can read it,
/// but a name that announced what it counted would defeat the point of a feature
/// whose whole design is that nobody notices it.
class PhotoCursorStore {
  /// Overridable so tests need no `path_provider`.
  final Directory? root;

  const PhotoCursorStore({this.root});

  static const String _fileName = 'ui_state.json';
  static const String _key = 'viewerCursor';

  Future<File> _file() async {
    final dir = root ?? await getApplicationSupportDirectory();
    return File('${dir.path}${Platform.pathSeparator}$_fileName');
  }

  /// The stored position, or zero when there is none.
  ///
  /// Every failure reads as zero. An unreadable scrap of interface state must
  /// never be the reason the About box refuses to open.
  Future<int> read() async {
    try {
      final file = await _file();
      if (!await file.exists()) return 0;

      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) return 0;
      final value = decoded[_key];
      return value is int && value >= 0 ? value : 0;
    } catch (_) {
      return 0;
    }
  }

  /// Records [cursor], keeping whatever else the file holds.
  ///
  /// Read-modify-write rather than overwrite: this file is the obvious home for
  /// the next small piece of interface state, and clobbering a sibling key would
  /// be a trap laid for later.
  Future<void> write(int cursor) async {
    try {
      final file = await _file();

      var state = <String, Object?>{};
      if (await file.exists()) {
        final decoded = jsonDecode(await file.readAsString());
        if (decoded is Map) state = Map<String, Object?>.from(decoded);
      }
      state[_key] = cursor;

      await AtomicFile.writeString(file, jsonEncode(state));
    } catch (_) {
      // Losing the position costs one repeat of the first picture. Not worth a
      // log line, and certainly not worth an exception reaching the caller.
    }
  }
}

abstract final class HiddenPhotos {
  /// `tatiana1.jpg`, `tatiana2.png`, … and a bare `tatiana.jpg` for good
  /// measure. Case-insensitive: a file copied off a phone can arrive as
  /// `Tatiana2.JPG`.
  static final RegExp _pattern = RegExp(
    r'^assets/images/tatiana(\d*)\.(jpg|jpeg|png|webp)$',
    caseSensitive: false,
  );

  /// Resolved once per run. The bundle cannot change under a running app.
  static List<String>? _cached;

  /// Where the cycle stands, or null before it has been read from disk.
  static int? _next;

  /// Replaceable for tests.
  @visibleForTesting
  static PhotoCursorStore store = const PhotoCursorStore();

  /// Every hidden picture, in order.
  static Future<List<String>> all() async {
    final cached = _cached;
    if (cached != null) return cached;

    try {
      final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
      final found = manifest.listAssets().where(_pattern.hasMatch).toList()
        ..sort(compareByNumber);
      return _cached = found;
    } catch (_) {
      // No manifest to read is not a failure worth reporting: it only means
      // there is nothing to find.
      return _cached = const [];
    }
  }

  /// The next picture in the cycle, or null when there are none.
  ///
  /// The position survives the app closing: stopping at the third picture and
  /// coming back tomorrow gives the fourth, not the first. It is written after
  /// each one is handed out, so even a process killed outright resumes where it
  /// was rather than at the beginning.
  ///
  /// Advances only when actually handing one out, so a view opened and closed
  /// without reaching twelve does not consume a turn.
  static Future<String?> next() async => advanceThrough(await all());

  /// The cycle itself, over a list handed in.
  ///
  /// Split from [next] so the part with the logic — resume, advance, wrap — can
  /// be tested against a known list. Asset discovery needs a real bundle; this
  /// does not, and this is where the mistakes would be.
  @visibleForTesting
  static Future<String?> advanceThrough(List<String> photos) async {
    if (photos.isEmpty) return null;

    // Modulo the count *now*: a stored position can outlive the list it was
    // recorded against, and adding or removing a picture must not leave the
    // cycle pointing past the end.
    final at = (_next ??= await store.read()) % photos.length;
    final photo = photos[at];

    _next = (at + 1) % photos.length;
    await store.write(_next!);
    return photo;
  }

  /// Forgets the in-memory position, so the next call re-reads it.
  @visibleForTesting
  static void resetForTest() {
    _cached = null;
    _next = null;
  }

  /// Orders `tatiana2` before `tatiana10`.
  ///
  /// A plain string sort puts 10 before 2, which would make the cycle jump
  /// about for no reason anyone could see. Visible for testing because the
  /// ordering is the part worth pinning down.
  static int compareByNumber(String a, String b) {
    int number(String key) {
      final digits = _pattern.firstMatch(key)?.group(1) ?? '';
      // A bare `tatiana.jpg` sorts first: it is the one that existed before
      // anybody thought to number them.
      return digits.isEmpty ? 0 : int.tryParse(digits) ?? 0;
    }

    final byNumber = number(a).compareTo(number(b));
    return byNumber != 0 ? byNumber : a.compareTo(b);
  }
}
