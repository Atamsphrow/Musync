// The head-only read in TagBackupStore.capture (the batch's first full
// read per track, removed October 2026) must store byte for byte the
// blob the old whole-file read stored — an undo splices those bytes
// back in front of the audio, so a shorter or longer blob corrupts.
// Every case below pins the blob against the legacy definition: the
// first `audioOffset` bytes of the full file, clamped to its length.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:musync/core/id3/id3_tag.dart';
import 'package:musync/core/id3/tag_backup.dart';

/// A hand-built ID3 tag: one APIC frame, [payload] filler bytes.
Uint8List _tag({int major = 4, int payload = 200, bool footer = false}) {
  final body = BytesBuilder()
    ..add(ascii.encode('APIC'))
    ..add(
      major == 4
          ? [
              (payload >> 21) & 0x7F,
              (payload >> 14) & 0x7F,
              (payload >> 7) & 0x7F,
              payload & 0x7F,
            ]
          : [
              (payload >> 24) & 0xFF,
              (payload >> 16) & 0xFF,
              (payload >> 8) & 0xFF,
              payload & 0xFF,
            ],
    )
    ..add([0, 0])
    ..add(List<int>.generate(payload, (i) => (i + 3) % 256));
  final bodyBytes = body.toBytes();
  final builder = BytesBuilder()
    ..add(ascii.encode('ID3'))
    ..add([major, 0, footer ? 0x10 : 0])
    ..add([
      (bodyBytes.length >> 21) & 0x7F,
      (bodyBytes.length >> 14) & 0x7F,
      (bodyBytes.length >> 7) & 0x7F,
      bodyBytes.length & 0x7F,
    ])
    ..add(bodyBytes);
  if (footer) {
    builder
      ..add(ascii.encode('3DI'))
      ..add([major, 0, 0x10])
      ..add([
        (bodyBytes.length >> 21) & 0x7F,
        (bodyBytes.length >> 14) & 0x7F,
        (bodyBytes.length >> 7) & 0x7F,
        bodyBytes.length & 0x7F,
      ]);
  }
  return builder.toBytes();
}

Uint8List _audio() =>
    Uint8List.fromList(List<int>.generate(8192, (i) => (i * 7) % 256));

void main() {
  late Directory tempDir;
  late TagBackupStore store;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('musync_head_');
    store = TagBackupStore(root: tempDir);
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  Future<Uint8List> blobOf(String path) async {
    final entry = await store.backupFor(path);
    expect(entry, isNotNull);
    return File(
      '${tempDir.path}${Platform.pathSeparator}tag_backups'
      '${Platform.pathSeparator}${entry!.storedAs}',
    ).readAsBytes();
  }

  Future<void> expectLegacyBlob(String name, Uint8List content) async {
    final path = '${tempDir.path}${Platform.pathSeparator}$name';
    await File(path).writeAsBytes(content);
    expect(await store.capture(path), isTrue);
    final offset = (Id3Tag.parse(content)?.audioOffset ?? 0).clamp(
      0,
      content.length,
    );
    expect(await blobOf(path), content.sublist(0, offset));
  }

  test('v2.3 tag: blob is the tag head, not the file', () async {
    await expectLegacyBlob('v23.mp3', Uint8List.fromList([
      ..._tag(major: 3),
      ..._audio(),
    ]));
  });

  test('v2.4 tag with footer: blob includes the footer', () async {
    final content = Uint8List.fromList([
      ..._tag(major: 4, footer: true),
      ..._audio(),
    ]);
    await expectLegacyBlob('v24f.mp3', content);
    final offset = Id3Tag.parse(content)!.audioOffset;
    expect((await blobOf(
      '${tempDir.path}${Platform.pathSeparator}v24f.mp3',
    )).length, offset);
  });

  test('declared size past the file end: blob is the whole file', () async {
    final tag = _tag(major: 4, payload: 40);
    // Lie about the size: claim ~500 KB of tag in a ~8 KB file.
    tag[6] = 0x7F;
    tag[7] = 0x7F;
    tag[8] = 0x7F;
    tag[9] = 0x7F;
    final content = Uint8List.fromList([...tag, ..._audio()]);
    final path = '${tempDir.path}${Platform.pathSeparator}trunc.mp3';
    await File(path).writeAsBytes(content);
    expect(await store.capture(path), isTrue);
    expect(await blobOf(path), content);
  });

  test('non-syncsafe size: falls back, blob matches legacy', () async {
    final tag = _tag(major: 3);
    tag[9] |= 0x80; // size bytes must have their high bit clear
    await expectLegacyBlob('nonsync.mp3', Uint8List.fromList([
      ...tag,
      ..._audio(),
    ]));
  });

  test('untagged MP3: empty blob, capture still succeeds', () async {
    final content = Uint8List.fromList([0xFF, 0xFB, ..._audio()]);
    final path = '${tempDir.path}${Platform.pathSeparator}bare.mp3';
    await File(path).writeAsBytes(content);
    expect(await store.capture(path), isTrue);
    expect(await blobOf(path), isEmpty);
  });
}
