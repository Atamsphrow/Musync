/// Lyrics appearance settings: font size, alignment, style, italic and colors.
/// Kept as one immutable object so the player screen and the floating bubble
/// read the same source of truth.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:musync/core/services/debug_log.dart';
import 'package:musync/core/utils/atomic_file.dart';
import 'package:path_provider/path_provider.dart';

/// The three sizes from the appearance picker (small / medium / large T).
enum LyricsFontSize { small, medium, large }

/// Line alignment: left, center, right.
enum LyricsTextAlign { left, center, right }

/// The two "Abc" styles: plain, or stylized (serif italic).
enum LyricsFontStyle { normal, stylized }

/// Active-line color: plain white, or follow the Material You dynamic color.
enum LyricsColorMode { white, materialYou }

@immutable
class LyricsAppearance {
  final LyricsFontSize fontSize;
  final LyricsTextAlign textAlign;
  final LyricsFontStyle fontStyle;
  final bool italic;
  final LyricsColorMode colorMode;

  /// The bubble's own color choice, independent from the player screen's.
  final LyricsColorMode bubbleColorMode;

  const LyricsAppearance({
    this.fontSize = LyricsFontSize.medium,
    this.textAlign = LyricsTextAlign.center,
    this.fontStyle = LyricsFontStyle.stylized,
    this.italic = true,
    this.colorMode = LyricsColorMode.white,
    this.bubbleColorMode = LyricsColorMode.white,
  });

  /// Font scale applied on top of the theme size and the system text scale.
  double get fontScale => switch (fontSize) {
        LyricsFontSize.small => 0.85,
        LyricsFontSize.medium => 1.0,
        LyricsFontSize.large => 1.2,
      };

  LyricsAppearance copyWith({
    LyricsFontSize? fontSize,
    LyricsTextAlign? textAlign,
    LyricsFontStyle? fontStyle,
    bool? italic,
    LyricsColorMode? colorMode,
    LyricsColorMode? bubbleColorMode,
  }) =>
      LyricsAppearance(
        fontSize: fontSize ?? this.fontSize,
        textAlign: textAlign ?? this.textAlign,
        fontStyle: fontStyle ?? this.fontStyle,
        italic: italic ?? this.italic,
        colorMode: colorMode ?? this.colorMode,
        bubbleColorMode: bubbleColorMode ?? this.bubbleColorMode,
      );

  Map<String, Object?> toJson() => {
        'fontSize': fontSize.name,
        'textAlign': textAlign.name,
        'fontStyle': fontStyle.name,
        'italic': italic,
        'colorMode': colorMode.name,
        'bubbleColorMode': bubbleColorMode.name,
      };

  static T _enumOf<T>(List<T> values, Object? raw, T fallback) {
    if (raw is String) {
      for (final v in values) {
        if ((v as Enum).name == raw) return v;
      }
    }
    return fallback;
  }

  static LyricsAppearance fromJson(Object? raw) {
    if (raw is! Map) return const LyricsAppearance();
    final m = raw.cast<String, Object?>();
    return LyricsAppearance(
      fontSize: _enumOf(
          LyricsFontSize.values, m['fontSize'], LyricsFontSize.medium),
      textAlign: _enumOf(
          LyricsTextAlign.values, m['textAlign'], LyricsTextAlign.center),
      fontStyle: _enumOf(
          LyricsFontStyle.values, m['fontStyle'], LyricsFontStyle.stylized),
      italic: m['italic'] is bool ? m['italic'] as bool : true,
      colorMode: _enumOf(
          LyricsColorMode.values, m['colorMode'], LyricsColorMode.white),
      bubbleColorMode: _enumOf(
          LyricsColorMode.values, m['bubbleColorMode'], LyricsColorMode.white),
    );
  }
}

class LyricsAppearanceStore {
  /// Overridable so tests need no `path_provider`.
  final Directory? root;

  const LyricsAppearanceStore({this.root});

  static const String _fileName = 'lyrics_appearance.json';

  Future<File> _file() async {
    final dir = root ?? await getApplicationSupportDirectory();
    return File('${dir.path}${Platform.pathSeparator}$_fileName');
  }

  /// Defaults on any failure. A setting that cannot be read must not stop
  /// playback, and the default is the neutral value anyway.
  Future<LyricsAppearance> load() async {
    try {
      final file = await _file();
      if (!await file.exists()) return const LyricsAppearance();
      return LyricsAppearance.fromJson(jsonDecode(await file.readAsString()));
    } catch (error, stack) {
      DebugLog.instance.error(
        'Réglages',
        'Apparence des paroles illisible : valeurs par défaut appliquées',
        error: error,
        stackTrace: stack,
      );
      return const LyricsAppearance();
    }
  }

  Future<void> save(LyricsAppearance appearance) async =>
      AtomicFile.writeString(await _file(), jsonEncode(appearance.toJson()));
}
