// The floating bubble draws whatever [BubblePayload] says, so the choice of
// which lines to show is tested here, without the overlay plugin.
import 'package:flutter_test/flutter_test.dart';
import 'package:musync/features/bubble/data/bubble_payload.dart';

void main() {
  const texts = ['Une', 'Deux', 'Trois'];

  group('BubblePayload.fromLines', () {
    test('a line in the middle has a neighbour on each side', () {
      final p = BubblePayload.fromLines(texts, 1, 3, widthDp: 200);
      expect((p.previous, p.current, p.next), ('Une', 'Deux', 'Trois'));
    });

    test('the first line has no previous one', () {
      final p = BubblePayload.fromLines(texts, 0, 3, widthDp: 200);
      expect((p.previous, p.current, p.next), ('', 'Une', 'Deux'));
    });

    test('the last line has no next one', () {
      final p = BubblePayload.fromLines(texts, 2, 2, widthDp: 200);
      expect((p.current, p.next), ('Trois', ''));
    });

    test('before the first line: the note, with the first line to come', () {
      final p = BubblePayload.fromLines(texts, null, 2, widthDp: 200);
      expect((p.current, p.next), (kBubbleIdle, 'Une'));
    });

    test('an empty timed line is an instrumental break, not a blank bubble', () {
      final p = BubblePayload.fromLines(['Une', '  ', 'Trois'], 1, 1, widthDp: 200);
      expect(p.current, kBubbleIdle);
    });

    test('no lyrics at all', () {
      final p = BubblePayload.fromLines(const [], 0, 2, widthDp: 200);
      expect(p.current, kBubbleIdle);
      expect(p.previous, isEmpty);
      expect(p.next, isEmpty);
    });

    test('an index past the end shows the note rather than crashing', () {
      final p = BubblePayload.fromLines(texts, 9, 2, widthDp: 200);
      expect(p.current, kBubbleIdle);
    });
  });

  group('encoding', () {
    test('survives the trip between the two isolates', () {
      final p = BubblePayload.fromLines(texts, 1, 3, widthDp: 200);
      final back = BubblePayload.tryDecode(p.encode())!;
      expect((back.previous, back.current, back.next, back.lines),
          ('Une', 'Deux', 'Trois', 3));
    });

    test('control strings and junk are not payloads', () {
      expect(BubblePayload.tryDecode('ready'), isNull);
      expect(BubblePayload.tryDecode(42), isNull);
      expect(BubblePayload.tryDecode('[1,2]'), isNull);
    });

    test('the width travels with the payload', () {
      final p = BubblePayload.fromLines(texts, 1, 3, widthDp: 288);
      expect(BubblePayload.tryDecode(p.encode())!.widthDp, 288);
    });

    test('a line count out of range is brought back to 1..3', () {
      final back = BubblePayload.tryDecode('{"c":"x","l":9}')!;
      expect(back.lines, 3);
    });

    test('taller bubble for more lines', () {
      expect(bubbleHeightFor(1) < bubbleHeightFor(2), isTrue);
      expect(bubbleHeightFor(2) < bubbleHeightFor(3), isTrue);
    });
  });
  group('timed lines for the overlay ticker', () {
    test('encode/decode round-trips the song id, timed lines and index', () {
      final p = BubblePayload.fromLines(
        texts,
        1,
        3,
        widthDp: 200,
        songId: '42',
        timedLines: [
          {'ms': 0, 't': 'Une'},
          {'ms': 5000, 't': 'Deux'},
          {'ms': 10000, 't': 'Trois'},
        ],
      );
      final back = BubblePayload.tryDecode(p.encode())!;
      expect(back.songId, '42');
      expect(back.activeIndex, 1);
      expect(back.timedLines.length, 3);
      expect(back.timedLines[1]['ms'], 5000);
      expect(back.timedLines[1]['t'], 'Deux');
    });

    test('old payloads without timed lines still decode', () {
      final back = BubblePayload.tryDecode(
        '{"p":"","c":"Une","n":"Deux","l":2,"w":200}',
      )!;
      expect(back.songId, '');
      expect(back.timedLines, isEmpty);
      expect(back.activeIndex, isNull);
    });

    test('idle carries no timed lines', () {
      const p = BubblePayload.idle(2);
      final back = BubblePayload.tryDecode(p.encode())!;
      expect(back.timedLines, isEmpty);
      expect(back.songId, '');
    });
  });
}
