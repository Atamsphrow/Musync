/// Full-size cover bytes for the player screen, kept in memory.
///
/// The big pane used to render through on_audio_query's
/// `QueryArtworkWidget`, which is a plain FutureBuilder: every build fires
/// a fresh MediaStore query, and the 1024 px / quality-100 request is the
/// expensive one (~300 ms on device). Nothing was cached between opens,
/// so expanding the mini player — whose own small cover was already on
/// screen — showed the placeholder, then a blank, then the cover popping
/// in a beat later.
///
/// This cache asks MediaStore once per track per session. Playback
/// prefetches (see `AudioPlayerService._warmArtwork`), so by the time the
/// player opens, [peek] answers synchronously and the cover is there on
/// the first frame. Memory cost is bounded by the tracks actually played
/// or opened, a few hundred KB each at 1024 px.
library;

import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:musync/core/services/debug_log.dart';
import 'package:musync/features/library/data/models/song.dart';
import 'package:on_audio_query/on_audio_query.dart';

class ArtworkBytesCache {
  ArtworkBytesCache({OnAudioQuery? query}) : _query = query ?? OnAudioQuery();

  final OnAudioQuery _query;

  /// Settled answers, including nulls: a track with no cover must not be
  /// re-queried on every open either.
  final Map<int, Uint8List?> _resolved = {};

  /// One in-flight query per track, shared by every caller that asks
  /// while it runs.
  final Map<int, Future<Uint8List?>> _pending = {};

  /// The request the player pane has always made (see the note there
  /// about why 1024/100: the plugin default is a 200 px thumbnail, which
  /// looked soft stretched across a full-width pane).
  static const int requestSize = 1024;
  static const int requestQuality = 100;

  /// Session cap on settled answers. Each entry is a 1024 px JPEG —
  /// a few hundred KB — and a long shuffled session touches hundreds
  /// of tracks; uncapped, the cache grew with all of them. Forty is
  /// far beyond any back-and-forth a listener actually does; the
  /// oldest answer is dropped (a re-open simply re-queries).
  static const int _maxResolved = 40;

  /// Whether [song]'s cover question has a settled answer.
  bool isResolved(Song song) => _resolved.containsKey(song.id);

  /// The settled bytes, or null for "no cover" — only meaningful when
  /// [isResolved] is true.
  Uint8List? peek(Song song) => _resolved[song.id];

  /// Loads [song]'s cover, sharing the in-flight query if there is one.
  ///
  /// Never throws: a failed query settles as "no cover" for the session
  /// rather than hammering MediaStore on every open.
  Future<Uint8List?> load(Song song) {
    // Settled answers are served from [_resolved]; [_pending] only holds the
    // queries still in flight (see below).
    if (_resolved.containsKey(song.id)) {
      return Future<Uint8List?>.value(_resolved[song.id]);
    }
    final existing = _pending[song.id];
    if (existing != null) return existing;
    // Chrono « Perf » : une requête n'a lieu que sur un cache froid
    // (réouverture après plus de 40 morceaux, ou pochette modifiée). Une
    // ligne ici à la réouverture dit que le cache n'a pas servi.
    final sw = Stopwatch()..start();
    final future = _query
        .queryArtwork(
          song.id,
          ArtworkType.AUDIO,
          size: requestSize,
          quality: requestQuality,
        )
        .then((bytes) {
          _resolved[song.id] = bytes;
          _trimResolved();
          DebugLog.instance.info(
            'Perf',
            'pochette (morceau ${song.id}) : requête MediaStore '
            '${sw.elapsedMilliseconds}ms, ${bytes?.length ?? 0} o',
          );
          return bytes;
        })
        .onError((_, _) {
          _resolved[song.id] = null;
          _trimResolved();
          return null;
        });
    _pending[song.id] = future;
    // The in-flight entry goes once the answer is settled. Kept, a completed
    // future still holds its bytes: [_pending] grew with every track ever
    // opened and silently defeated the [_maxResolved] cap — a 1024 px cover
    // per played track, for the whole session. `identical`: a forget() and
    // a fresh load may have replaced this entry meanwhile.
    future.whenComplete(() {
      if (identical(_pending[song.id], future)) _pending.remove(song.id);
    }).ignore();
    return future;
  }

  /// Drops the oldest settled answers past [_maxResolved]. The map
  /// keeps insertion order, so the first keys are the stalest.
  void _trimResolved() {
    while (_resolved.length > _maxResolved) {
      _resolved.remove(_resolved.keys.first);
    }
  }

  /// Warms the cache for [song] without waiting for the answer.
  void prefetch(Song song) {
    if (isResolved(song)) return;
    load(song).ignore();
  }

  /// Bumped by [forget]: a cover on screen listens, so a cover edited
  /// under an open player is redrawn at once — not at the next track.
  final ValueNotifier<int> revision = ValueNotifier<int>(0);

  /// Drops [song]'s settled answer (cover edited): the next [load]
  /// re-queries MediaStore.
  void forget(Song song) {
    _resolved.remove(song.id);
    _pending.remove(song.id);
    revision.value++;
  }
}
