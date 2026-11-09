/// Runs the real Id3Writer against real MP3s, tagged by real taggers.
///
/// The rest of the suite builds its fixtures byte by byte, which is the right
/// way to test a parser but says nothing about the shapes actually found in the
/// wild: 3 MB cover art, `TXXX` frames nobody documents, lyrics already in the
/// file. This fills that gap.
///
/// Skipped unless the fixtures are present, so a normal `flutter test` is
/// unaffected. To run it alone:
///
///     flutter test --tags probe
///
/// The invariants are the ones that matter for a program that edits the user's
/// own music in place: the audio must come out byte-identical, and no frame it
/// doesn't understand may be lost.
@Tags(['probe'])
library;

// Printing is the point here: this probe is read by a human comparing a file
// before and after a write, not by CI.
// ignore_for_file: avoid_print

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:musync/core/audio/mp3_gapless.dart';
import 'package:musync/core/id3/id3_reader.dart';
import 'package:musync/core/id3/id3_tag.dart';
import 'package:musync/core/id3/id3_writer.dart';
import 'package:musync/core/id3/models/lyrics.dart';

/// Dossier des MP3 réels à sonder. Surchargeable par la variable
/// d'environnement `MUSYNC_PROBE_EVIDENCE` (ex. `D:\musync-diag\evidence`
/// sous Windows) ; par défaut un dossier sous le temp système, portable
/// — l'ancien chemin Windows en dur faisait skipper le test partout
/// ailleurs sans qu'on sache pourquoi.
final String _evidence = Platform.environment['MUSYNC_PROBE_EVIDENCE'] ??
    '${Directory.systemTemp.path}${Platform.pathSeparator}musync-diag'
        '${Platform.pathSeparator}evidence';

/// Offset of the first MPEG frame, found by its sync word rather than by
/// trusting the tag — the point is to catch a tag that lies about its size.
///
/// A sync word alone is not a header: eleven bits of sync appear often
/// enough in arbitrary data to fake one, so the version, layer, bitrate
/// and sample-rate fields are validated too. A reserved or illegal value
/// means this is not a frame, and the scan moves on.
int _audioStart(Uint8List data, int from) {
  for (var i = from < 0 ? 0 : from; i + 2 < data.length; i++) {
    if (data[i] != 0xFF || (data[i + 1] & 0xE0) != 0xE0) continue;
    final second = data[i + 1];
    final third = data[i + 2];
    // MPEG version, bits 4-3 of the second byte: 01 is reserved.
    if ((second >> 3 & 0x03) == 0x01) continue;
    // Layer, bits 2-1: 00 is reserved.
    if ((second >> 1 & 0x03) == 0x00) continue;
    // Bitrate index, bits 7-4 of the third byte: 0 (free) and 15 (bad).
    final bitrateIndex = third >> 4 & 0x0F;
    if (bitrateIndex == 0 || bitrateIndex == 0x0F) continue;
    // Sample-rate index, bits 3-2: 3 is reserved.
    if ((third >> 2 & 0x03) == 0x03) continue;
    return i;
  }
  return -1;
}

Map<String, int> _frameSizes(Uint8List bytes) {
  final tag = Id3Tag.parse(bytes);
  if (tag == null) return const {};
  return {for (final frame in tag.frames) frame.id: frame.body.length};
}

Future<void> _probe(String name, SyncedLyrics lyrics) async {
  final source = File('$_evidence${Platform.pathSeparator}$name');
  if (!source.existsSync()) {
    markTestSkipped('$name absent de $_evidence');
    return;
  }

  // Always on a copy. This probe reads the user's own music, and a bug in the
  // code under test must not be able to damage it.
  final before = await source.readAsBytes();
  final work = File(
    '${Directory.systemTemp.path}${Platform.pathSeparator}probe_$name',
  );
  try {
    // Dans le `try` : si la copie échoue (disque plein, droits), le
    // `finally` nettoie quand même — avant, l'échec laissait le fichier
    // de travail derrière lui.
    await work.writeAsBytes(before);
    final parsedBefore = Id3Tag.parse(before);
    expect(
      parsedBefore,
      isNotNull,
      reason: 'tag illisible avant écriture : $name',
    );
    final beforeTag = parsedBefore!;
    final beforeFrames = _frameSizes(before);
    final beforeAudioAt = _audioStart(before, beforeTag.audioOffset - 4);
    // A tag lying about its size can leave no valid sync after it:
    // fail here with a message instead of a `sublist(-1)` RangeError.
    expect(
      beforeAudioAt,
      greaterThanOrEqualTo(0),
      reason: 'aucun sync MPEG valide avant l\'audio de $name',
    );
    final beforeAudio = before.sublist(beforeAudioAt);

    await Id3Writer.writeLyrics(
      work.path,
      synced: lyrics,
      unsynced: UnsyncedLyrics(lyrics.toPlainText()),
    );

    final after = await work.readAsBytes();
    final parsedAfter = Id3Tag.parse(after);
    expect(
      parsedAfter,
      isNotNull,
      reason: 'tag illisible après écriture : $name',
    );
    final afterTag = parsedAfter!;
    final afterFrames = _frameSizes(after);
    final afterAudioAt = _audioStart(after, afterTag.audioOffset - 4);
    expect(
      afterAudioAt,
      greaterThanOrEqualTo(0),
      reason: 'aucun sync MPEG valide avant l\'audio de $name après écriture',
    );
    final afterAudio = after.sublist(afterAudioAt);

    print('\n--- $name ---');
    print(
      '  avant : ID3v2.${beforeTag.majorVersion}, '
      '${before.length ~/ 1024} Ko, ${beforeFrames.length} frames, '
      'audio à $beforeAudioAt',
    );
    print(
      '  après : ID3v2.${afterTag.majorVersion}, '
      '${after.length ~/ 1024} Ko, ${afterFrames.length} frames, '
      'audio à $afterAudioAt',
    );
    print('  frames avant : ${beforeFrames.keys.join(" ")}');
    print('  frames après : ${afterFrames.keys.join(" ")}');

    // 1. The audio must be untouched, byte for byte. Everything else this app
    //    does is worth less than not corrupting the music.
    expect(
      afterAudio.length,
      beforeAudio.length,
      reason: 'longueur du flux audio',
    );
    var firstDiff = -1;
    for (var i = 0; i < beforeAudio.length; i++) {
      if (beforeAudio[i] != afterAudio[i]) {
        firstDiff = i;
        break;
      }
    }
    expect(firstDiff, -1, reason: 'audio modifié à l\'offset $firstDiff');

    // 2. The tag keeps its major version. Re-stamping v2.3 as v2.4 silently
    //    destroys every frame over 127 bytes — the artwork, above all.
    expect(
      afterTag.majorVersion,
      beforeTag.majorVersion,
      reason: 'version du tag',
    );

    // 3. Everything that isn't lyrics survives at the same size, including the
    //    frames Musync has no idea how to read.
    for (final entry in beforeFrames.entries) {
      if (entry.key == 'SYLT' || entry.key == 'USLT') continue;
      expect(
        afterFrames[entry.key],
        entry.value,
        reason: 'frame ${entry.key} perdue ou altérée',
      );
    }

    // 4. The tag has to declare where the audio really begins.
    expect(
      afterTag.audioOffset,
      afterAudioAt,
      reason: 'offset audio déclaré ≠ position réelle du sync MPEG',
    );

    // 5. Musync must read back exactly what it wrote — text included, which is
    //    what would catch the SYLT newline separator leaking into a lyric.
    final reread = Id3Reader.readLyricsFromBytes(after);
    expect(
      reread.synced?.lines.map((l) => l.text).toList(),
      lyrics.lines.map((l) => l.text).toList(),
      reason: 'texte relu',
    );
    expect(
      reread.synced?.lines.map((l) => l.timestamp).toList(),
      lyrics.lines.map((l) => l.timestamp).toList(),
      reason: 'horodatages relus',
    );

    // 6. T3: the plain frame carries the timings too, for the players that
    //    ignore SYLT.
    // encoding byte + 3-byte language + a descriptor terminator whose width
    // depends on the encoding — one byte for latin-1/UTF-8, two for UTF-16.
    // Slicing at a fixed 5 read v2.3's text half a code unit out of phase,
    // which is why it came back as mojibake.
    final usltFrame = afterTag.frameById('USLT');
    expect(usltFrame, isNotNull, reason: 'USLT absente après écriture');
    final uslt = usltFrame!.decodedBody;
    final encoding = uslt[0];
    final textStart = 4 + Id3Encoding.terminatorLength(encoding);
    final plainText = Id3Tag.decodeText(uslt.sublist(textStart), encoding);
    expect(
      plainText,
      contains('['),
      reason: 'USLT doit contenir du LRC pour Musicolet',
    );

    // 7. The fast reader must agree with the slow one on a real tag. It skips
    //    frame bodies by arithmetic, and a real 3 MB APIC is where an
    //    off-by-anything would show.
    final fast = await Id3Reader.readLyricsFrames(work.path);
    final full = await Id3Reader.readLyrics(work.path);
    expect(fast.synced?.lines, full.synced?.lines, reason: 'lecteur rapide');
    expect(fast.unsynced?.text, full.unsynced?.text, reason: 'lecteur rapide');
  } finally {
    if (await work.exists()) await work.delete();
  }
}

void main() {
  group('_audioStart valide le header MPEG, pas juste le sync', () {
    test('un vrai header MPEG Layer III est trouve', () {
      // 0xFF 0xFB: MPEG-1, Layer III; 0x90: bitrate 128k, 44,1 kHz.
      final data = Uint8List.fromList([0x00, 0x11, 0xFF, 0xFB, 0x90, 0x00]);
      expect(_audioStart(data, 0), 2);
    });

    test('un sync avec version reservee est ignore', () {
      // 0xFF 0xE9: sync + version 01 (reservee) -> pas un frame.
      // Le vrai header suit a l'offset 4.
      final data = Uint8List.fromList([
        0xFF, 0xE9, 0x90, 0x00,
        0xFF, 0xFB, 0x90, 0x00,
      ]);
      expect(_audioStart(data, 0), 4);
    });

    test('un sync avec bitrate interdit est ignore', () {
      // 0xFF 0xFB 0xF0: bitrate index 15 (bad) -> pas un frame.
      final data = Uint8List.fromList([
        0xFF, 0xFB, 0xF0, 0x00,
        0xFF, 0xFB, 0x90, 0x00,
      ]);
      expect(_audioStart(data, 0), 4);
    });

    test('aucun header valide retourne -1, pas une fausse position', () {
      final data = Uint8List.fromList([0xFF, 0xE0, 0x00, 0xFF, 0xFB, 0xF0]);
      expect(_audioStart(data, 0), -1);
    });
  });

  _gaplessProbe();
  final lyrics = SyncedLyrics([
    const LyricLine(
      timestamp: Duration(milliseconds: 500),
      text: 'Première ligne',
    ),
    const LyricLine(
      timestamp: Duration(seconds: 3, milliseconds: 250),
      text: 'Deuxième, accentuée : été où çà',
    ),
    const LyricLine(timestamp: Duration(seconds: 7), text: 'Troisième'),
  ]);

  test(
    'v2.3 avec USLT préexistant et pochette (Panda)',
    () => _probe('v23_uslt_artwork.mp3', lyrics),
  );

  test(
    'v2.3 avec pochette de 3,6 Mo — le cas extrême du lecteur rapide',
    () => _probe('v23_huge_artwork.mp3', lyrics),
  );

  test('v2.4 avec pochette de 1 Mo', () => _probe('v24_artwork.mp3', lyrics));

  test(
    'v2.3 avec frames TXXX non standard, que Musync doit recopier à l\'aveugle',
    () => _probe('v23_txxx_uslt.mp3', lyrics),
  );
}

// -- The Xing/LAME reader on real files (T20) ---------------------------------

void _gaplessProbe() {
  group('Xing/LAME sur de vrais fichiers', () {
    final dir = Directory(_evidence);
    if (!dir.existsSync()) return;

    final files = dir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.toLowerCase().endsWith('.mp3'))
        .toList();

    for (final file in files) {
      final name = file.uri.pathSegments.last;

      test('$name : ce que son premier frame annonce', () async {
        final info = await Mp3GaplessReader.read(file.path);
        print('$name : ${info?.describe() ?? "aucun frame MPEG lisible"}');

        // Null is a legitimate answer, and this is the fixture that proves it:
        // `v23_uslt_artwork.mp3` carries no run of consecutive MPEG frames at
        // any layer, anywhere in its 1.8 MB of payload. Before the second-frame
        // check it was reported as "12.0 kHz" — eleven bits of sync appear
        // often enough in arbitrary data to fake a header, and 12 kHz is a rate
        // no music file in this library uses. Saying nothing is the correct
        // answer there; saying 12 kHz was a confident wrong one.
        if (info == null) return;

        expect(const [
          8000,
          11025,
          12000,
          16000,
          22050,
          24000,
          32000,
          44100,
          48000,
        ], contains(info.sampleRate));

        // These are real music files. A rate this low means the scan locked on
        // to noise, which is the failure this check exists to catch.
        expect(
          info.sampleRate,
          greaterThanOrEqualTo(22050),
          reason:
              'sync probablement trouve dans des donnees qui ne sont pas '
              'un frame MPEG',
        );

        // The claim T20 rests on. Whatever delay these files declare, it is
        // nowhere near the 200 ms lag that was reported against Musicolet. If
        // this ever fails, the original hypothesis deserves another look.
        final delay = info.encoderDelayDuration;
        if (delay != null) expect(delay.inMilliseconds, lessThan(100));
      });
    }
  });
}
