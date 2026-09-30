// Image attachments: validation, magic-byte sniffing and base64 encoding for
// the prompt `images` field. Ported from web/src/lib/composer/images.ts plus
// the web ImageTray/attach flow. Pure Dart, no Flutter imports.
//
// Wire contract (docs/API.md): up to 4 images, image/png|jpeg|webp|gif, at
// most 5 MB DECODED each, raw base64 with no `data:` prefix. The gateway
// checks the magic bytes against the claimed mime, so the mime we send is
// always sniffed from the bytes, never the file extension.

import 'dart:convert';
import 'dart:typed_data';

const int maxImages = 4;
const int maxImageBytes = 5 * 1024 * 1024;

/// Mimes the gateway accepts, in the order the picker accepts list uses.
const List<String> imageTypes = [
  'image/png',
  'image/jpeg',
  'image/webp',
  'image/gif',
];

const String imageAccept = 'image/png,image/jpeg,image/webp,image/gif';

/// The JSON shape of one prompt image.
typedef PromptImage = Map<String, String>;

bool isImageType(String t) => imageTypes.contains(t);

/// Sniff the mime type from magic bytes; null when not a supported image.
/// Never trust the file extension: the gateway validates the bytes against
/// the declared mime.
String? sniffImageMime(Uint8List bytes) {
  bool at(int i, List<int> sig) {
    if (i + sig.length > bytes.length) return false;
    for (var j = 0; j < sig.length; j++) {
      if (bytes[i + j] != sig[j]) return false;
    }
    return true;
  }

  if (at(0, [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])) {
    return 'image/png';
  }
  if (at(0, [0xFF, 0xD8, 0xFF])) return 'image/jpeg';
  if (at(0, [
    0x52, 0x49, 0x46, 0x46, // RIFF
  ]) &&
      at(8, [0x57, 0x45, 0x42, 0x50])) {
    return 'image/webp';
  }
  if (at(0, [0x47, 0x49, 0x46, 0x38])) return 'image/gif'; // GIF8
  return null;
}

/// An error to show the user, or null when the image can be attached.
/// [attached] is how many images are already in the tray; [declaredMime] is
/// what the source claims the bytes are (a file's mime type), which must be
/// an accepted type and must match the bytes' magic bytes.
String? imageProblem(
  Uint8List bytes, {
  required int attached,
  String? declaredMime,
}) {
  if (attached >= maxImages) return 'Up to $maxImages images per message';
  if (declaredMime != null && !isImageType(declaredMime)) {
    return 'Use a PNG, JPEG, WebP or GIF image';
  }
  final sniffed = sniffImageMime(bytes);
  if (sniffed == null ||
      (declaredMime != null && declaredMime != sniffed)) {
    return 'Use a PNG, JPEG, WebP or GIF image';
  }
  if (bytes.length > maxImageBytes) return 'Images can be at most 5 MB';
  return null;
}

/// Raw base64, no `data:` prefix, as the gateway expects.
String bytesToBase64(Uint8List bytes) => base64Encode(bytes);

/// The prompt `images` entry for validated image bytes. The mimeType is
/// sniffed from the bytes.
PromptImage toPromptImage(Uint8List bytes) {
  final mime = sniffImageMime(bytes);
  if (mime == null) throw const FormatException('Unsupported image type');
  return {
    'type': 'image',
    'data': bytesToBase64(bytes),
    'mimeType': mime,
  };
}

/// One image in the tray: the decoded bytes plus the sniffed mime, with an
/// id so removal can be keyed (like the web's Attached).
class AttachedImage {
  AttachedImage({
    required this.id,
    required this.bytes,
    required this.mimeType,
  });

  final int id;
  final Uint8List bytes;

  /// Sniffed from the magic bytes; the mime the prompt declares.
  final String mimeType;
}
