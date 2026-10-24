import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musync/core/theme/artwork_scheme_provider.dart';

Future<Uint8List> _png(int width, int height) async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  final w = width.toDouble();
  final h = height.toDouble();
  canvas.drawRect(
    Rect.fromLTWH(0, 0, w, h),
    Paint()..color = const Color(0xFF1565C0),
  );
  canvas.drawRect(
    Rect.fromLTWH(0, 0, w * 0.4, h * 0.4),
    Paint()..color = const Color(0xFFE65100),
  );
  canvas.drawCircle(
    Offset(w * 0.75, h * 0.66),
    h * 0.2,
    Paint()..color = const Color(0xFF2E7D32),
  );
  final image = await recorder.endRecording().toImage(width, height);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return data!.buffer.asUint8List();
}

void main() {
  for (final size in const [(400, 300), (300, 400), (80, 60)]) {
    testWidgets(
      'même schéma que ColorScheme.fromImageProvider (${size.$1}×${size.$2})',
      (tester) async {
        await tester.runAsync(() async {
          final bytes = await _png(size.$1, size.$2);
          final expected = await ColorScheme.fromImageProvider(
            provider: MemoryImage(bytes),
            brightness: Brightness.dark,
          );
          final actual = await artworkSchemeFromBytes(bytes, Brightness.dark);
          expect(actual, expected);
        });
      },
    );
  }
}
