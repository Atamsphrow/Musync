/// Provenance des paroles écrites : qui a écrit quoi, avec quelle
/// confiance, sur quelle requête (DESIGN.md §6).
///
/// Un fichier `lyrics_provenance.json` (support dir, versionné) : une
/// entrée par chemin de fichier. C'est ce qui permet au vérificateur et
/// au balayage de distinguer une parole écrite par l'app à 0,40 d'une
/// parole collée par l'utilisateur — et, plus tard, de lister les
/// erreurs de l'app pour les corriger en lot.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:musync/core/utils/atomic_file.dart';
import 'package:path_provider/path_provider.dart';

/// D'où viennent les paroles d'un fichier.
enum LyricsProvenanceOrigin {
  /// Écriture automatique par l'assistant IA (seuil 0,80).
  autoAi,

  /// Écriture automatique par le fond / balayage.
  autoBackground,

  /// Écriture par le lot (revue en deux phases).
  batch,

  /// Choix explicite de l'utilisateur sur l'écran de recherche.
  manual,

  /// Paroles collées par l'utilisateur.
  pasted,

  /// Paroles éditées / calées par l'utilisateur dans l'éditeur.
  editor,
}

/// Une entrée de provenance.
class LyricsProvenance {
  /// La source (nom affiché : « LRCLIB »), ou « utilisateur ».
  final String source;

  /// L'id du morceau chez la source (LRCLIB track id), null quand la
  /// source n'en donne pas ou quand les paroles viennent de l'utilisateur.
  final int? trackId;

  final String title;
  final String artist;

  /// La confiance du candidat écrit (0..1).
  final double confidence;

  /// La requête qui a produit le candidat.
  final String queryTitle;
  final String queryArtist;

  /// Vrai quand le candidat venait de la devinette nom de fichier.
  final bool viaFilename;

  final LyricsProvenanceOrigin origin;

  final DateTime embeddedAt;

  const LyricsProvenance({
    required this.source,
    this.trackId,
    required this.title,
    required this.artist,
    required this.confidence,
    required this.queryTitle,
    required this.queryArtist,
    required this.viaFilename,
    required this.origin,
    required this.embeddedAt,
  });

  /// Paroles de l'utilisateur (collées, éditées, calées, ou choisies
  /// explicitement) : l'IA propose, ne remplace jamais seule.
  bool get isUserOrigin =>
      origin == LyricsProvenanceOrigin.pasted ||
      origin == LyricsProvenanceOrigin.editor ||
      origin == LyricsProvenanceOrigin.manual;

  /// Une écriture automatique à basse confiance : à revérifier.
  bool get isLowConfidenceAuto =>
      !isUserOrigin && confidence < 0.80;

  Map<String, Object?> toJson() => {
    'source': source,
    'trackId': trackId,
    'title': title,
    'artist': artist,
    'confidence': confidence,
    'queryTitle': queryTitle,
    'queryArtist': queryArtist,
    'viaFilename': viaFilename,
    'origin': origin.name,
    'embeddedAt': embeddedAt.millisecondsSinceEpoch,
  };

  static LyricsProvenance? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final source = raw['source'];
    final title = raw['title'];
    final artist = raw['artist'];
    final confidence = raw['confidence'];
    final queryTitle = raw['queryTitle'];
    final queryArtist = raw['queryArtist'];
    final embeddedAt = raw['embeddedAt'];
    if (source is! String ||
        title is! String ||
        artist is! String ||
        confidence is! num ||
        queryTitle is! String ||
        queryArtist is! String ||
        embeddedAt is! int) {
      return null;
    }
    final origin = LyricsProvenanceOrigin.values
        .where((o) => o.name == raw['origin'])
        .firstOrNull;
    if (origin == null) return null;
    return LyricsProvenance(
      source: source,
      trackId: raw['trackId'] is int ? raw['trackId'] as int : null,
      title: title,
      artist: artist,
      confidence: confidence.toDouble(),
      queryTitle: queryTitle,
      queryArtist: queryArtist,
      viaFilename: raw['viaFilename'] == true,
      origin: origin,
      embeddedAt: DateTime.fromMillisecondsSinceEpoch(embeddedAt),
    );
  }
}

/// Le store. Une entrée par chemin ; les chemins disparus sont purgés
/// au chargement.
class LyricsProvenanceStore {
  /// Overridable so tests do not need `path_provider`.
  final Directory? root;

  LyricsProvenanceStore({this.root});

  static const String _fileName = 'lyrics_provenance.json';
  static const int _schemaVersion = 1;

  Map<String, LyricsProvenance>? _entries;
  bool _dirty = false;

  Future<File> _file() async {
    final dir = root ?? await getApplicationSupportDirectory();
    return File('${dir.path}${Platform.pathSeparator}$_fileName');
  }

  Future<Map<String, LyricsProvenance>> _load() async {
    final cached = _entries;
    if (cached != null) return cached;
    final loaded = <String, LyricsProvenance>{};
    try {
      final file = await _file();
      if (await file.exists()) {
        final decoded = jsonDecode(await file.readAsString());
        if (decoded is Map && decoded['version'] == _schemaVersion) {
          final entries = decoded['entries'];
          if (entries is Map) {
            for (final e in entries.entries) {
              final provenance = LyricsProvenance.fromJson(e.value);
              if (provenance != null) loaded['${e.key}'] = provenance;
            }
          }
        }
      }
    } catch (_) {
      // Illisible = on repart de zéro ; les écritures suivantes
      // réenregistrent leur provenance.
    }
    // Purge des chemins disparus : un morceau supprimé ne doit pas
    // rester « à vérifier » pour toujours.
    final gone = <String>[];
    for (final path in loaded.keys) {
      if (!await File(path).exists()) gone.add(path);
    }
    for (final path in gone) {
      loaded.remove(path);
    }
    if (gone.isNotEmpty) _dirty = true;
    return _entries = loaded;
  }

  /// La provenance des paroles de [filePath], ou null (écrites avant ce
  /// système, ou jamais écrites par l'app).
  Future<LyricsProvenance?> forPath(String filePath) async =>
      (await _load())[filePath];

  /// Enregistre la provenance d'une écriture. Persistée par [save].
  Future<void> record(
    String filePath,
    LyricsProvenance provenance,
  ) async {
    (await _load())[filePath] = provenance;
    _dirty = true;
  }

  /// Oublie la provenance de [filePath] (paroles supprimées, par ex.).
  Future<void> forget(String filePath) async {
    if ((await _load()).remove(filePath) != null) _dirty = true;
  }

  /// Écrit le store (atomiquement) s'il a changé.
  Future<void> save() async {
    if (!_dirty) return;
    _dirty = false;
    try {
      await AtomicFile.writeString(
        await _file(),
        jsonEncode({
          'version': _schemaVersion,
          'entries': {
            for (final e in (await _load()).entries) e.key: e.value.toJson(),
          },
        }),
      );
    } catch (_) {
      // Best effort : la prochaine écriture réessaiera.
      _dirty = true;
    }
  }
}

/// Le store partagé, injecté dans le finder et les chemins d'écriture.
final lyricsProvenanceStoreProvider = Provider<LyricsProvenanceStore>(
  (ref) => LyricsProvenanceStore(),
);
