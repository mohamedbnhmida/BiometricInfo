import 'dart:typed_data';

import 'tlv.dart';

/// Extracts the raw face-image codestream (JPEG or JPEG2000) out of an
/// EF.DG2 file, per ICAO 9303 Part 10 / ISO 7816-11's biometric data
/// template nesting:
///   0x75 (DG2) -> 0x7F61 (biometric info template group) -> 0x02 (count) +
///   0x7F60 (one biometric info template) -> 0xA1 (header, ignored) +
///   0x7F2E/0x5F2E (biometric data == an ISO 19794-5 face image record).
Uint8List? extractFacePhotoFromDg2(Uint8List dg2Bytes) {
  final top = findTag(parseTlvSequence(dg2Bytes), 0x75);
  if (top == null) return null;
  final group = findTag(parseTlvSequence(top.value), 0x7F61);
  if (group == null) return null;
  for (final node in parseTlvSequence(group.value)) {
    if (node.tag != 0x7F60) continue;
    final instance = parseTlvSequence(node.value);
    final bioData = findTag(instance, 0x7F2E) ?? findTag(instance, 0x5F2E);
    if (bioData == null) continue;
    final photo = _extractImageCodestream(bioData.value);
    if (photo != null) return photo;
  }
  return null;
}

/// ponytail: rather than walking the exact ISO 19794-5 facial-record header
/// (record length, feature-point count/table, image-info block — ~30-50
/// bytes of fixed fields before the pixel data), scan for the image's own
/// magic bytes. The header is short and structured, so a false match before
/// the real image start is not realistically possible. Upgrade to full
/// header parsing only if a reader is ever seen emitting an image format
/// that isn't found this way.
Uint8List? _extractImageCodestream(Uint8List biometricData) {
  for (var i = 0; i + 2 < biometricData.length; i++) {
    // JPEG SOI marker.
    if (biometricData[i] == 0xFF && biometricData[i + 1] == 0xD8 && biometricData[i + 2] == 0xFF) {
      return biometricData.sublist(i);
    }
    // JP2 signature box: 00 00 00 0C 6A 50 20 20 0D 0A 87 0A.
    if (i + 11 < biometricData.length &&
        biometricData[i] == 0x00 &&
        biometricData[i + 1] == 0x00 &&
        biometricData[i + 2] == 0x00 &&
        biometricData[i + 3] == 0x0C &&
        biometricData[i + 4] == 0x6A &&
        biometricData[i + 5] == 0x50) {
      return biometricData.sublist(i);
    }
  }
  return null;
}

bool isJpeg(Uint8List imageBytes) =>
    imageBytes.length >= 3 && imageBytes[0] == 0xFF && imageBytes[1] == 0xD8 && imageBytes[2] == 0xFF;
