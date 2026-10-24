import 'dart:collection';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:on_audio_query/on_audio_query.dart';

typedef ArtworkFetcher = Future<Uint8List?> Function(int songId);

/// Bounded LRU of list-thumbnail bytes, keyed by MediaStore song id.
///
/// Holds bytes, not decoded images: handing the *same* Uint8List back makes
/// MemoryImage compare equal, so Flutter's own ImageCache keeps the decoded
/// picture. "No artwork" is remembered too; errors are not, so they retry.
class ThumbnailCache {
  ThumbnailCache({ArtworkFetcher? fetch, this.capacity = 300})
      : _fetch = fetch ?? _queryMediaStore;

  static final ThumbnailCache instance = ThumbnailCache();

  /// Physical pixels: 48 dp rows on 2.6–3.5 DPR screens.
  static const int thumbnailPx = 160;

  final int capacity;
  final ArtworkFetcher _fetch;
  final LinkedHashMap<int, ThumbnailEntry> _entries =
      LinkedHashMap<int, ThumbnailEntry>();

  static final OnAudioQuery _query = OnAudioQuery();

  static Future<Uint8List?> _queryMediaStore(int songId) async {
    final bytes = await _query.queryArtwork(
      songId,
      ArtworkType.AUDIO,
      format: ArtworkFormat.JPEG,
      size: thumbnailPx,
      quality: 85,
    );
    return (bytes == null || bytes.isEmpty) ? null : bytes;
  }

  int get length => _entries.length;

  /// The entry for [songId], fetched once and shared by concurrent callers.
  ThumbnailEntry entryFor(int songId) {
    final hit = _entries.remove(songId);
    if (hit != null) {
      _entries[songId] = hit; // most recently used goes last
      return hit;
    }
    late final ThumbnailEntry entry;
    entry = ThumbnailEntry._(
      _fetch(songId).then<Uint8List?>(
        (bytes) {
          entry
            ..bytes = bytes
            ..isDone = true;
          return bytes;
        },
        onError: (Object _) {
          // Don't pin a failure: the next row to ask will retry.
          if (identical(_entries[songId], entry)) _entries.remove(songId);
          return null;
        },
      ),
    );
    _entries[songId] = entry;
    while (_entries.length > capacity) {
      _entries.remove(_entries.keys.first);
    }
    return entry;
  }

  void evict(int songId) => _entries.remove(songId);

  /// Call on a library rescan: an artwork may have changed under a same id.
  void clear() => _entries.clear();
}

class ThumbnailEntry {
  ThumbnailEntry._(this.future);

  final Future<Uint8List?> future;
  bool isDone = false;
  Uint8List? bytes;
}

/// Square list thumbnail backed by [ThumbnailCache]. A row scrolled back into
/// view paints its artwork on the first frame, without a placeholder flash.
class SongArtwork extends StatefulWidget {
  const SongArtwork({
    super.key,
    required this.songId,
    required this.placeholder,
    this.size = 48,
  });

  final int songId;
  final Widget placeholder;
  final double size;

  @override
  State<SongArtwork> createState() => _SongArtworkState();
}

class _SongArtworkState extends State<SongArtwork> {
  Uint8List? _bytes;

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  @override
  void didUpdateWidget(SongArtwork oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.songId != widget.songId) _resolve();
  }

  void _resolve() {
    final id = widget.songId;
    final entry = ThumbnailCache.instance.entryFor(id);
    if (entry.isDone) {
      _bytes = entry.bytes;
      return;
    }
    _bytes = null;
    entry.future.then((bytes) {
      if (!mounted || widget.songId != id || bytes == null) return;
      setState(() => _bytes = bytes);
    });
  }

  @override
  Widget build(BuildContext context) {
    final bytes = _bytes;
    if (bytes == null) return widget.placeholder;
    return Image.memory(
      bytes,
      width: widget.size,
      height: widget.size,
      fit: BoxFit.cover,
      gaplessPlayback: true,
      filterQuality: FilterQuality.medium,
      errorBuilder: (context, error, stackTrace) => widget.placeholder,
    );
  }
}
