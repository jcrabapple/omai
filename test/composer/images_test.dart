// Image attachment logic tests, ported from the web's images.ts rules
// (web/src/lib/composer/images.ts and its tests) plus magic-byte sniffing.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:omai/composer/images.dart';

Uint8List _bytes(List<int> l) => Uint8List.fromList(l);

final png = _bytes([
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3,
]);
final jpeg = _bytes([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3]);
final webp = _bytes([
  0x52, 0x49, 0x46, 0x46, 0x0A, 0x00, 0x00, 0x00,
  0x57, 0x45, 0x42, 0x50, 1, 2,
]);
final gif = _bytes([0x47, 0x49, 0x46, 0x38, 0x39, 0x61, 1, 2]);
final notAnImage = _bytes([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12]);

void main() {
  group('sniffImageMime', () {
    test('detects each supported type from magic bytes', () {
      expect(sniffImageMime(png), 'image/png');
      expect(sniffImageMime(jpeg), 'image/jpeg');
      expect(sniffImageMime(webp), 'image/webp');
      expect(sniffImageMime(gif), 'image/gif');
      expect(sniffImageMime(notAnImage), isNull);
      // Too short to be anything.
      expect(sniffImageMime(_bytes([0x89])), isNull);
    });
  });

  group('imageProblem', () {
    // The declared mime never rejects (triage #5): the gateway only checks
    // the sniffed mime against the bytes and we always SEND the sniffed
    // mime, so the decision is purely on the bytes.
    test('accepts a PNG delivered with a JPEG declaration', () {
      expect(
        imageProblem(png, attached: 0, declaredMime: 'image/jpeg'),
        isNull,
      );
    });

    test('accepts an image/jpg declaration', () {
      expect(
        imageProblem(jpeg, attached: 0, declaredMime: 'image/jpg'),
        isNull,
      );
    });

    test('accepts JPEG bytes declared as HEIC and attaches image/jpeg', () {
      expect(
        imageProblem(jpeg, attached: 0, declaredMime: 'image/heic'),
        isNull,
      );
      // What we would attach is the sniffed mime, image/jpeg.
      expect(toPromptImage(jpeg)['mimeType'], 'image/jpeg');
    });

    test('rejects bytes that are not an image at all', () {
      expect(
        imageProblem(notAnImage, attached: 0),
        'Use a PNG, JPEG, WebP or GIF image',
      );
    });

    test('enforces the count limit with the web message', () {
      expect(
        imageProblem(png, attached: maxImages),
        'Up to $maxImages images per message',
      );
      expect(imageProblem(png, attached: maxImages - 1), isNull);
    });

    test('enforces the 5 MB decoded size limit', () {
      final big = Uint8List(maxImageBytes + 1);
      big[0] = 0x89;
      big.setRange(
        1,
        8,
        [0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A],
      );
      expect(imageProblem(big, attached: 0), 'Images can be at most 5 MB');
      // Exactly at the limit is fine.
      final edge = Uint8List(maxImageBytes);
      edge[0] = 0x89;
      edge.setRange(1, 8, [0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
      expect(imageProblem(edge, attached: 0), isNull);
    });
  });

  group('toPromptImage', () {
    test('produces raw base64 with no data: prefix and the sniffed mime', () {
      final prompt = toPromptImage(png);
      expect(prompt['type'], 'image');
      expect(prompt['mimeType'], 'image/png');
      final data = prompt['data']!;
      expect(data.startsWith('data:'), isFalse,
          reason: 'raw base64, no data: prefix');
      // Round-trips.
      expect(
        base64Decode(data),
        png,
      );
    });

    test('throws on unsupported bytes', () {
      expect(() => toPromptImage(notAnImage), throwsFormatException);
    });
  });

  test('constants match the wire contract', () {
    expect(maxImages, 4);
    expect(maxImageBytes, 5 * 1024 * 1024);
    expect(
      imageTypes,
      ['image/png', 'image/jpeg', 'image/webp', 'image/gif'],
    );
  });
}
