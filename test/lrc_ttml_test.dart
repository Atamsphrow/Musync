// Tests for the lrc.red TTML parser (step 2 of the myspoti plan).
//
// The Juice WRLD and Tsota payloads below are the real answers captured
// live on 2026-11-12 (search + TTML fetch, no key): Juice is line-timed
// (59 lines, no spans), Tsota is text only (`lrc:timing="None"`, no `begin`
// anywhere). The word-timed cases are synthetic — neither live track had
// word timings — built from the `<span>` shape the myspoti report documents.
import 'package:flutter_test/flutter_test.dart';
import 'package:musync/features/lyrics/data/providers/lrc_ttml.dart';

/// Juice WRLD « Scared of Love », TTML as served by lrc.red (abridged to
/// the first two `<div>` groups — the rest is the same shape).
const juiceTtml = r'''<tt xmlns="http://www.w3.org/ns/ttml" xmlns:lrc="http://lrc.red/lyric-ttml-internal" lrc:timing="Line" xml:lang="en"><head><metadata><sourceMetadata xmlns="http://lrc.red/lyric-ttml-internal" leadingSilence="0.020"><translations/><songwriters><songwriter>Ghost Loft</songwriter><songwriter>Jarad Higgins</songwriter></songwriters></sourceMetadata></metadata></head><body dur="2:50.539"><div begin="4.008" end="22.846" lrc:songPart="Verse"><p begin="4.008" end="8.526" lrc:key="L750">Ooh, ooh, whoa</p><p begin="9.946" end="11.928" lrc:key="L751">I never been scared</p><p begin="14.070" end="16.018" lrc:key="L752">I tell you that I don't care</p></div><div begin="23.619" end="48.608" lrc:songPart="Verse"><p begin="23.619" end="27.303" lrc:key="L756">I never been scared of love, scared to love</p><p begin="1:00.682" end="1:03.753" lrc:key="L768">All I ever do is get **** up</p></div></body></tt>''';

/// Tsota « Mahazo Tsirony », TTML as served by lrc.red (abridged to the
/// first `<div>` group — the rest is the same shape: no timings at all).
const tsotaTtml = r'''<tt xmlns="http://www.w3.org/ns/ttml" xmlns:lrc="http://lrc.red/lyric-ttml-internal" lrc:timing="None" xml:lang="tl"><head><metadata><sourceMetadata xmlns="http://lrc.red/lyric-ttml-internal"><translations/><songwriters><songwriter>Andriniaina Randriakoto</songwriter></songwriters></sourceMetadata></metadata></head><body><div><p>Aieyii ...aieyaa...aieyii..</p></div><div><p>Ny Olombelona oa samy misy maso</p><p>Fa vao ny anao no mijery anah tonga dia misy raha</p></div></body></tt>''';

void main() {
  group('parseTtmlTime', () {
    test('secondes décimales', () {
      expect(parseTtmlTime('4.008'), 4008);
      expect(parseTtmlTime('0'), 0);
      expect(parseTtmlTime('170.539'), 170539);
    });

    test('m:ss.mmm', () {
      expect(parseTtmlTime('1:00.672'), 60672);
      expect(parseTtmlTime('2:50.539'), 170539);
    });

    test('h:mm:ss.mmm', () {
      expect(parseTtmlTime('01:04:08.500'), 3848500);
    });

    test('invalide = null', () {
      expect(parseTtmlTime(''), isNull);
      expect(parseTtmlTime('abc'), isNull);
      expect(parseTtmlTime('-1'), isNull);
      expect(parseTtmlTime('1:2:3:4'), isNull);
      expect(parseTtmlTime('1:xx'), isNull);
    });
  });

  group('parseTtmlLyrics', () {
    test('Juice réel : lignes calées, textes exacts, pas de mots', () {
      final lines = parseTtmlLyrics(juiceTtml);
      expect(lines, isNotNull);
      expect(lines, hasLength(5));
      expect(lines![0].timestamp, const Duration(milliseconds: 4008));
      expect(lines[0].text, 'Ooh, ooh, whoa');
      expect(lines[0].words, isEmpty);
      expect(lines[1].timestamp, const Duration(milliseconds: 9946));
      // m:ss.mmm : 1:00.682 = 60 682 ms.
      expect(lines[4].timestamp, const Duration(milliseconds: 60682));
      expect(lines[4].text, 'All I ever do is get **** up');
      expect(lines.every((line) => line.timestamp != null), isTrue);
    });

    test('Tsota réel : texte seul, jamais de lignes à 00:00', () {
      final lines = parseTtmlLyrics(tsotaTtml);
      expect(lines, isNotNull);
      expect(lines, hasLength(3));
      expect(lines!.every((line) => line.timestamp == null), isTrue);
      expect(lines[0].text, 'Aieyii ...aieyaa...aieyii..');
      expect(lines[1].text, 'Ny Olombelona oa samy misy maso');
    });

    test('mots : spans parsés, chœur marqué, sans begin ignoré', () {
      const ttml =
          '<tt xmlns="http://www.w3.org/ns/ttml"><body><div>'
          '<p begin="1.000" end="4.000">'
          '<span begin="1.000" end="1.500">Une</span> '
          '<span begin="1.500" end="2.000">ligne</span>'
          '<span begin="2.000" end="2.500" ttm:role="x-bg" xmlns:ttm="http://www.w3.org/ns/ttml#metadata">ooh</span>'
          '<span>sans heure</span>'
          '</p></div></body></tt>';
      final lines = parseTtmlLyrics(ttml);
      expect(lines, hasLength(1));
      final line = lines!.single;
      expect(line.timestamp, const Duration(milliseconds: 1000));
      expect(line.text, 'Une ligne ooh sans heure');
      expect(line.words, hasLength(3));
      expect(line.words[0].text, 'Une');
      expect(line.words[0].start, const Duration(milliseconds: 1000));
      expect(line.words[0].duration, const Duration(milliseconds: 500));
      expect(line.words[0].isBackground, isFalse);
      expect(line.words[2].text, 'ooh');
      expect(line.words[2].isBackground, isTrue);
    });

    test('<br/> devient un espace, pas une ligne collée', () {
      const ttml =
          '<tt xmlns="http://www.w3.org/ns/ttml"><body><div>'
          '<p begin="1.000">premier<br/>deuxième</p>'
          '</div></body></tt>';
      final lines = parseTtmlLyrics(ttml);
      expect(lines!.single.text, 'premier deuxième');
    });

    test('entités XML décodées', () {
      const ttml =
          '<tt xmlns="http://www.w3.org/ns/ttml"><body><div>'
          '<p begin="1.000">Rock &amp; Roll &quot;tout&quot; &#39;ça&#39;</p>'
          '</div></body></tt>';
      final lines = parseTtmlLyrics(ttml);
      expect(lines!.single.text, 'Rock & Roll "tout" \'ça\'');
    });

    test('begin illisible : la ligne est abandonnée, les autres restent', () {
      const ttml =
          '<tt xmlns="http://www.w3.org/ns/ttml"><body><div>'
          '<p begin="nimporte">cassée</p>'
          '<p begin="2.000">bonne</p>'
          '</div></body></tt>';
      final lines = parseTtmlLyrics(ttml);
      expect(lines, hasLength(1));
      expect(lines!.single.text, 'bonne');
    });

    test('ligne vide ignorée', () {
      const ttml =
          '<tt xmlns="http://www.w3.org/ns/ttml"><body><div>'
          '<p begin="1.000">   </p>'
          '<p begin="2.000">pleine</p>'
          '</div></body></tt>';
      final lines = parseTtmlLyrics(ttml);
      expect(lines, hasLength(1));
      expect(lines!.single.text, 'pleine');
    });

    test('XML mal formé = null', () {
      expect(parseTtmlLyrics('pas du xml du tout'), isNull);
      expect(parseTtmlLyrics('<tt><body><p>non fermé'), isNull);
    });

    test('sans <p> = null', () {
      expect(
        parseTtmlLyrics(
          '<tt xmlns="http://www.w3.org/ns/ttml"><body></body></tt>',
        ),
        isNull,
      );
    });
  });
}
