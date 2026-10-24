/// Derives a Material You color scheme from the current song's artwork.
///
/// This is the second half of the Material You story: the app as a whole
/// follows the system wallpaper palette, while the player screen re-tints
/// itself from the cover art of whatever is playing.
library;

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_color_utilities/material_color_utilities.dart'
    show QuantizerCelebi, Score;
import 'package:musync/core/services/debug_log.dart';
import 'package:musync/features/library/providers/library_provider.dart';

/// Key for [artworkSchemeProvider] — a scheme depends on both the artwork and
/// the brightness it will be rendered at.
@immutable
class ArtworkSchemeRequest {
  final int songId;
  final Brightness brightness;

  const ArtworkSchemeRequest({required this.songId, required this.brightness});

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ArtworkSchemeRequest &&
          other.songId == songId &&
          other.brightness == brightness;

  @override
  int get hashCode => Object.hash(songId, brightness);
}

/// Same bound as `ColorScheme.fromImageProvider`: the artwork is shrunk so
/// its longest side is at most this many pixels before quantization.
const double _maxDimension = 112.0;

/// Same result as `ColorScheme.fromImageProvider(MemoryImage(bytes))`, minus
/// the jank.
///
/// Flutter's version runs the quantizer (pure Dart, tens of milliseconds on a
/// phone) on the main isolate, in one uninterrupted microtask chain — a
/// dropped burst of frames on every track change. Here the decode and the
/// downscale stay where they already were (engine threads, async), only the
/// pixels go to a background isolate, and the seed comes back as one int.
/// `fromSeed` then builds the scheme through the same dynamic-scheme path
/// `fromImageProvider` uses, so the tint is identical (pinned by a test).
///
/// Decoding through a codec rather than a [MemoryImage] also keeps every
/// track's full-size cover out of the [ImageCache].
Future<ColorScheme> artworkSchemeFromBytes(
  Uint8List bytes,
  Brightness brightness,
) async {
  final Uint32List pixels = await _scaledAbgrPixels(bytes);
  final int seed = await compute(_seedFromAbgrPixels, pixels);
  return ColorScheme.fromSeed(seedColor: Color(seed), brightness: brightness);
}

/// Decode, shrink to [_maxDimension] the way Flutter does (nearest neighbour,
/// aspect ratio kept, never enlarged), and read back raw RGBA — which, read
/// as little-endian 32-bit words, is ABGR.
Future<Uint32List> _scaledAbgrPixels(Uint8List bytes) async {
  final ui.Codec codec = await ui.instantiateImageCodec(bytes);
  final ui.FrameInfo frame = await codec.getNextFrame().whenComplete(
    codec.dispose,
  );
  final ui.Image image = frame.image;
  ui.Image? scaled;
  try {
    final int width = image.width;
    final int height = image.height;
    double paintWidth = width.toDouble();
    double paintHeight = height.toDouble();
    if (width > _maxDimension || height > _maxDimension) {
      paintWidth =
          (width > height) ? _maxDimension : (_maxDimension / height) * width;
      paintHeight =
          (height > width) ? _maxDimension : (_maxDimension / width) * height;
    }
    final ui.PictureRecorder recorder = ui.PictureRecorder();
    paintImage(
      canvas: ui.Canvas(recorder),
      rect: Rect.fromLTRB(0, 0, paintWidth, paintHeight),
      image: image,
      filterQuality: ui.FilterQuality.none,
    );
    final ui.Picture picture = recorder.endRecording();
    try {
      scaled = await picture.toImage(paintWidth.toInt(), paintHeight.toInt());
    } finally {
      picture.dispose();
    }
    final ByteData? data = await scaled.toByteData();
    if (data == null) {
      throw StateError('Pochette illisible après réduction');
    }
    return data.buffer.asUint32List();
  } finally {
    image.dispose();
    scaled?.dispose();
  }
}

/// Runs in a background isolate (top-level, as `compute` requires).
///
/// Mirrors `fromImageProvider` step for step: quantize the ABGR words as-is,
/// convert the cluster colours to ARGB, keep the single best-scored one.
Future<int> _seedFromAbgrPixels(Uint32List abgrPixels) async {
  final result = await QuantizerCelebi().quantize(
    abgrPixels,
    128,
    returnInputPixelToClusterPixel: true,
  );
  final Map<int, int> colorToCount = result.colorToCount.map(
    (int key, int value) => MapEntry<int, int>(_argbFromAbgr(key), value),
  );
  return Score.score(colorToCount, desired: 1).first;
}

/// Swaps the red and blue bytes; alpha and green stay put.
int _argbFromAbgr(int abgr) {
  final int r = (abgr >> 16) & 0xFF;
  final int b = abgr & 0xFF;
  return (abgr & 0xFF00FF00) | (b << 16) | r;
}

/// Quantizes the song's cover art into a full [ColorScheme].
///
/// Returns null when the track has no embedded artwork, or when the image
/// can't be decoded — callers fall back to the app-wide scheme in that case.
///
/// NOT autoDispose, deliberately: a [ColorScheme] is a few dozen colour
/// values — nothing — while computing one costs a MediaStore round-trip
/// plus a decode and a quantization. When this was autoDispose, every
/// opening of the player recomputed it from scratch, and the result landed
/// mid-transition: the whole screen re-themed itself while it was still
/// sliding up, which read as the expansion freezing halfway. Cached for
/// the session instead, and prewarmed on every track change (see
/// `main.dart`), so the player opens with its tint already known. The
/// quantization itself runs off the main isolate (see
/// [artworkSchemeFromBytes]), so that prewarm costs no frames.
final artworkSchemeProvider =
    FutureProvider.family<ColorScheme?, ArtworkSchemeRequest>((
      ref,
      request,
    ) async {
      final scanner = ref.watch(musicScannerProvider);

      final Uint8List? bytes = await scanner.getArtwork(request.songId);
      if (bytes == null || bytes.isEmpty) return null;

      try {
        // TEMPORARY timing (the lag hunt): wall time from artwork bytes to
        // scheme. The quantization now runs in a background isolate, so this
        // no longer measures main-isolate blocking at all — it says how long
        // after a track change the player's tint is ready. FrameProbe gaps
        // around these lines should now be flat.
        final schemeSw = Stopwatch()..start();
        final scheme = await artworkSchemeFromBytes(bytes, request.brightness);
        DebugLog.instance.info(
          'Perf',
          'schéma pochette (morceau ${request.songId}) : '
          '${schemeSw.elapsedMilliseconds}ms (quantification hors UI)',
        );
        return scheme;
      } catch (error) {
        // Corrupt or unsupported artwork — fall back to the app-wide scheme.
        //
        // Once per session, and this one is not optional: this runs for every
        // track the player opens. A codec Flutter dislikes across the library
        // would post a line per track, and the buffer holds 400 — the flood
        // would push out every entry worth reading, which is the opposite of
        // capturing everything.
        DebugLog.instance.once(
          'artwork-decode',
          LogLevel.info,
          'Thème',
          'Pochette non décodable : le thème gardera la palette de l\'app',
          error: error,
        );
        return null;
      }
    });
