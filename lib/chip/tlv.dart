import 'dart:typed_data';

/// Minimal BER-TLV reader — enough for the fixed, well-formed structures
/// found in EF.DG2 and ISO 7816-4 secure messaging response data objects.
class Tlv {
  final int tag;
  final Uint8List value;
  Tlv(this.tag, this.value);
}

int berLength(Uint8List data, int offset) {
  final first = data[offset];
  if (first & 0x80 == 0) return first;
  final numBytes = first & 0x7F;
  var len = 0;
  for (var i = 0; i < numBytes; i++) {
    len = (len << 8) | data[offset + 1 + i];
  }
  return len;
}

int berLengthByteCount(Uint8List data, int offset) {
  final first = data[offset];
  return first & 0x80 == 0 ? 1 : 1 + (first & 0x7F);
}

/// Encodes a BER length (short or long form, up to 3-byte long form).
Uint8List encodeBerLength(int length) {
  if (length < 0x80) return Uint8List.fromList([length]);
  if (length <= 0xFF) return Uint8List.fromList([0x81, length]);
  return Uint8List.fromList([0x82, (length >> 8) & 0xFF, length & 0xFF]);
}

List<Tlv> parseTlvSequence(Uint8List data) {
  final result = <Tlv>[];
  var i = 0;
  while (i < data.length) {
    var tag = data[i];
    i++;
    if (tag & 0x1F == 0x1F) {
      int b;
      do {
        b = data[i];
        tag = (tag << 8) | b;
        i++;
      } while (b & 0x80 != 0);
    }
    final len = berLength(data, i);
    i += berLengthByteCount(data, i);
    final value = data.sublist(i, i + len);
    i += len;
    result.add(Tlv(tag, value));
  }
  return result;
}

Tlv? findTag(List<Tlv> tlvs, int tag) {
  for (final t in tlvs) {
    if (t.tag == tag) return t;
  }
  return null;
}
