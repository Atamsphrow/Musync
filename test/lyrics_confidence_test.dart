// Tests du scoreur de confiance (DESIGN.md §3, FILES.md §4.1–4.2).
import 'package:flutter_test/flutter_test.dart';
import 'package:musync/core/id3/models/lyrics.dart';
import 'package:musync/features/lyrics/data/lyrics_confidence.dart';
import 'package:musync/features/lyrics/data/providers/lyrics_provider_interface.dart';

LyricsSearchResult _hit({
  String title = 'Titre',
  String artist = 'Artiste',
  String? album,
  int? durationMs,
  bool synced = true,
  double confidence = 0.0,
}) => LyricsSearchResult(
  source: 'LRCLIB',
  title: title,
  artist: artist,
  album: album,
  syncedLyrics: synced
      ? SyncedLyrics([
          const LyricLine(timestamp: Duration(seconds: 1), text: 'Une'),
        ])
      : null,
  unsyncedLyrics: synced ? null : const UnsyncedLyrics('Des paroles'),
  confidence: confidence,
  durationMs: durationMs,
);

void main() {
  group('scoreLyricsCandidate', () {
    // Note : les poids du design (§3) totalisent 0,90 sans l'accord nom de
    // fichier (+0,10) — le « 1,0 » de FILES.md §4.1 ne tient qu'avec lui.
    test('match exact titre+artiste+album+durée+synchro = 0,90', () {
      final score = scoreLyricsCandidate(
        candidateTitle: 'Titre',
        candidateArtist: 'Artiste',
        candidateAlbum: 'Album',
        candidateDurationMs: 180000,
        candidateHasSynced: true,
        queryTitle: 'Titre',
        queryArtist: 'Artiste',
        queryAlbum: 'Album',
        queryDurationMs: 180000,
      );
      expect(score.total, closeTo(0.90, 0.001));
      expect(score.title, 0.35);
      expect(score.artist, 0.30);
      expect(score.album, 0.05);
      expect(score.duration, 0.15);
      expect(score.synced, 0.05);
    });

    test('match exact + accord nom de fichier = 1,0', () {
      final score = scoreLyricsCandidate(
        candidateTitle: 'Titre',
        candidateArtist: 'Artiste',
        candidateAlbum: 'Album',
        candidateDurationMs: 180000,
        candidateHasSynced: true,
        queryTitle: 'Titre',
        queryArtist: 'Artiste',
        queryAlbum: 'Album',
        queryDurationMs: 180000,
        filenameGuess: (artist: 'Artiste', title: 'Titre'),
      );
      expect(score.total, closeTo(1.0, 0.001));
      expect(score.filenameAgreement, 0.10);
    });

    test('match exact + mot à mot = 0,95', () {
      final score = scoreLyricsCandidate(
        candidateTitle: 'Titre',
        candidateArtist: 'Artiste',
        candidateAlbum: 'Album',
        candidateDurationMs: 180000,
        candidateHasSynced: true,
        candidateHasWordTimings: true,
        queryTitle: 'Titre',
        queryArtist: 'Artiste',
        queryAlbum: 'Album',
        queryDurationMs: 180000,
      );
      expect(score.total, closeTo(0.95, 0.001));
      expect(score.wordTimings, 0.05);
    });

    test('mot à mot sans synchro = pas de bonus', () {
      final score = scoreLyricsCandidate(
        candidateTitle: 'Titre',
        candidateArtist: 'Artiste',
        candidateDurationMs: 180000,
        candidateHasSynced: false,
        candidateHasWordTimings: true,
        queryTitle: 'Titre',
        queryArtist: 'Artiste',
        queryDurationMs: 180000,
      );
      // 0,35 + 0,30 + 0,15 = 0,80 : le bonus mot à mot ne compte pas
      // sans lignes calées — c'est un raffinement de la synchro.
      expect(score.total, closeTo(0.80, 0.001));
      expect(score.wordTimings, 0.0);
    });

    test('titre seul concordant, artiste différent = sous 0,80', () {
      final score = scoreLyricsCandidate(
        candidateTitle: 'Titre',
        candidateArtist: 'Autre Artiste',
        candidateDurationMs: 180000,
        candidateHasSynced: true,
        queryTitle: 'Titre',
        queryArtist: 'Artiste',
        queryDurationMs: 180000,
      );
      // 0,35 (titre) + 0,15 (artiste partiel : « Autre Artiste » contient
      // « Artiste ») + 0,15 (durée) + 0,05 (synchro) = 0,70 : proposé,
      // jamais intégré seul.
      expect(score.total, closeTo(0.70, 0.001));
      expect(score.autoIntegrate, isFalse);
      expect(score.worthProposing, isTrue);
    });

    test('Beyoncé vs Beyonce = match exact (pliage des accents)', () {
      final score = scoreLyricsCandidate(
        candidateTitle: 'Crazy In Love',
        candidateArtist: 'Beyoncé',
        candidateHasSynced: false,
        queryTitle: 'crazy in love',
        queryArtist: 'Beyonce',
      );
      expect(score.title, 0.35);
      expect(score.artist, 0.30);
    });

    test('durée : ±3 s plein, ±10 s réduit, au-delà 0', () {
      double durationScore(int candidateMs) =>
          scoreLyricsCandidate(
            candidateTitle: 'Titre',
            candidateArtist: 'Artiste',
            candidateDurationMs: candidateMs,
            candidateHasSynced: false,
            queryTitle: 'Titre',
            queryArtist: 'Artiste',
            queryDurationMs: 180000,
          ).duration;
      expect(durationScore(182000), 0.15);
      expect(durationScore(177000), 0.15);
      expect(durationScore(189000), 0.07);
      expect(durationScore(171000), 0.07);
      expect(durationScore(200000), 0.0);
      expect(durationScore(0), 0.0);
    });

    test('hit synchro sans titre ni artiste = 0,05 seulement', () {
      final score = scoreLyricsCandidate(
        candidateTitle: '09',
        candidateArtist: 'Groupe X',
        candidateHasSynced: true,
        queryTitle: 'Vrai Titre',
        queryArtist: 'Vrai Artiste',
      );
      // Fini le 0,35 de l'ancien plancher : synchro seule = 0,05.
      expect(score.total, closeTo(0.05, 0.001));
    });

    test('accord nom de fichier : candidat = devinette → +0,10 plafonné', () {
      final score = scoreLyricsCandidate(
        candidateTitle: 'Vrai Titre',
        candidateArtist: 'Artiste Réel',
        candidateDurationMs: 180000,
        candidateHasSynced: true,
        queryTitle: '09',
        queryArtist: 'Artiste inconnu',
        queryDurationMs: 180000,
        filenameGuess: (artist: 'Artiste Réel', title: 'Vrai Titre'),
      );
      // 0 (titre) + 0 (artiste) + 0,15 (durée) + 0,05 (synchro) +
      // 0,10 (nom de fichier) = 0,30.
      expect(score.filenameAgreement, 0.10);
      expect(score.total, closeTo(0.30, 0.001));
    });

    test('placeholder candidat = −0,30', () {
      final score = scoreLyricsCandidate(
        candidateTitle: 'Track 01',
        candidateArtist: 'Artiste inconnu',
        candidateHasSynced: false,
        queryTitle: 'Track 01',
        queryArtist: 'Artiste inconnu',
      );
      // Titre exact 0,35 + artiste exact 0,30 − 0,30 = 0,35.
      expect(score.placeholderPenalty, -0.30);
      expect(score.total, closeTo(0.35, 0.001));
    });

    test('« A feat. B » accepté quand A correspond', () {
      final score = scoreLyricsCandidate(
        candidateTitle: 'Titre',
        candidateArtist: 'Artiste feat. Invité',
        candidateHasSynced: false,
        queryTitle: 'Titre',
        queryArtist: 'Artiste',
      );
      expect(score.artist, 0.30);
    });

    test('titre partiel : (Remix) retiré, ou l\'un contient l\'autre', () {
      final remix = scoreLyricsCandidate(
        candidateTitle: 'Titre (Remix)',
        candidateArtist: 'Artiste',
        candidateHasSynced: false,
        queryTitle: 'Titre',
        queryArtist: 'Artiste',
      );
      expect(remix.title, 0.15);
      final contains = scoreLyricsCandidate(
        candidateTitle: 'Titre (version longue)',
        candidateArtist: 'Artiste',
        candidateHasSynced: false,
        queryTitle: 'Titre',
        queryArtist: 'Artiste',
      );
      expect(contains.title, 0.15);
    });

    test('album absent des deux côtés = 0, pas de pénalité', () {
      final score = scoreLyricsCandidate(
        candidateTitle: 'Titre',
        candidateArtist: 'Artiste',
        candidateHasSynced: false,
        queryTitle: 'Titre',
        queryArtist: 'Artiste',
      );
      expect(score.album, 0.0);
      expect(score.total, closeTo(0.65, 0.001));
    });

    test('filenameGuessContradictsQuery : devinette différente = vrai', () {
      expect(
        filenameGuessContradictsQuery(
          (artist: 'Artiste Réel', title: 'Vrai Titre'),
          queryTitle: '09',
          queryArtist: 'Artiste inconnu',
        ),
        isTrue,
      );
      expect(
        filenameGuessContradictsQuery(
          (artist: 'Artiste', title: 'Titre'),
          queryTitle: 'Titre',
          queryArtist: 'Artiste',
        ),
        isFalse,
      );
      expect(
        filenameGuessContradictsQuery(
          (artist: '', title: 'Titre'),
          queryTitle: 'Autre',
          queryArtist: 'Artiste',
        ),
        isTrue,
      );
      expect(
        filenameGuessContradictsQuery(
          null,
          queryTitle: 'Titre',
          queryArtist: 'Artiste',
        ),
        isFalse,
      );
    });
  });

  group('bestAutoMatch', () {
    test('synchro 0,85 gagne contre texte seul 1,0', () {
      final best = bestAutoMatch([
        _hit(synced: false, confidence: 1.0),
        _hit(synced: true, confidence: 0.85),
      ]);
      expect(best?.hasSyncedLyrics, isTrue);
      expect(best?.confidence, 0.85);
    });

    test('synchro 0,60 + texte seul 0,90 → texte seul', () {
      final best = bestAutoMatch([
        _hit(synced: true, confidence: 0.60),
        _hit(synced: false, confidence: 0.90),
      ]);
      expect(best?.hasSyncedLyrics, isFalse);
      expect(best?.confidence, 0.90);
    });

    test('aucun hit ≥ 0,80 → null', () {
      expect(
        bestAutoMatch([
          _hit(synced: true, confidence: 0.79),
          _hit(synced: false, confidence: 0.50),
        ]),
        isNull,
      );
    });

    test('liste vide → null', () {
      expect(bestAutoMatch([]), isNull);
    });

    test('seuil personnalisable', () {
      expect(
        bestAutoMatch(
          [_hit(synced: true, confidence: 0.60)],
          minConfidence: 0.50,
        )?.confidence,
        0.60,
      );
    });
  });
}
