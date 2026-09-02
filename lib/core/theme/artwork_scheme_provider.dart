/// Derives a Material You color scheme from the current song's artwork.
///
/// This is the second half of the Material You story: the app as a whole
/// follows the system wallpaper palette, while the player screen re-tints
/// itself from the cover art of whatever is playing.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
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

/// Quantizes the song's cover art into a full [ColorScheme].
///
/// Returns null when the track has no embedded artwork, or when the image
/// can't be decoded — callers fall back to the app-wide scheme in that case.
///
/// Kept `autoDispose` on purpose: quantization is expensive, so the result is
/// cached for as long as the player keeps watching this song, and released as
/// soon as the track changes. That bounds memory to the tracks on screen
/// rather than growing with the size of the library.
final artworkSchemeProvider = FutureProvider.autoDispose
    .family<ColorScheme?, ArtworkSchemeRequest>((ref, request) async {
      final scanner = ref.watch(musicScannerProvider);

      final Uint8List? bytes = await scanner.getArtwork(request.songId);
      if (bytes == null || bytes.isEmpty) return null;

      try {
        return await ColorScheme.fromImageProvider(
          provider: MemoryImage(bytes),
          brightness: request.brightness,
        );
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
