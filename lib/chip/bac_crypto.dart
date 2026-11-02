import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:pointycastle/export.dart';

/// ICAO 9303 Basic Access Control: MRZ-derived keys, ISO 9797-1 padding/MAC,
/// and 3DES CBC — the primitives needed to authenticate to an eMRTD chip and
/// read its data groups under secure messaging. Algorithm details cross-
/// checked against JMRTD's `Util.java` and Bouncy Castle's
/// `ISO9797Alg3Mac.java` (the two most widely deployed reference
/// implementations), since there's no local hardware to test against.

int _mrzCharValue(String c) {
  if (c == '<') return 0;
  final code = c.codeUnitAt(0);
  if (code >= 48 && code <= 57) return code - 48; // '0'-'9'
  if (code >= 65 && code <= 90) return code - 55; // 'A'-'Z' -> 10-35
  throw ArgumentError('Invalid MRZ character: $c');
}

/// ICAO 9303 MRZ check digit: weights 7,3,1 cycling, mod 10.
int mrzCheckDigit(String field) {
  const weights = [7, 3, 1];
  var sum = 0;
  for (var i = 0; i < field.length; i++) {
    sum += _mrzCharValue(field[i]) * weights[i % 3];
  }
  return sum % 10;
}

String _isoDateToYYMMDD(String isoDate) {
  // isoDate is "YYYY-MM-DD" (as produced by MrzParser).
  return isoDate.substring(2, 4) + isoDate.substring(5, 7) + isoDate.substring(8, 10);
}

/// ponytail: document number is padded/truncated to the TD3 (passport) field
/// width of 9 — correct for the vast majority of MRTDs; TD1 id-card composite
/// check digits have extra edge cases we don't handle. Upgrade if a reader
/// reports BAC failures specifically on TD1 cards with >9-char numbers.
String _padDocNumber(String docNumber) {
  final upper = docNumber.toUpperCase();
  if (upper.length >= 9) return upper.substring(0, 9);
  return upper.padRight(9, '<');
}

/// Builds the MRZ_information string BAC's key seed is hashed from:
/// documentNumber+CD + dateOfBirth+CD + dateOfExpiry+CD (all YYMMDD).
String buildMrzInformation({
  required String documentNumber,
  required String birthDateIso,
  required String expiryDateIso,
}) {
  final docNum = _padDocNumber(documentNumber);
  final dob = _isoDateToYYMMDD(birthDateIso);
  final exp = _isoDateToYYMMDD(expiryDateIso);
  final docCd = mrzCheckDigit(docNum);
  final dobCd = mrzCheckDigit(dob);
  final expCd = mrzCheckDigit(exp);
  return '$docNum$docCd$dob$dobCd$exp$expCd';
}

Uint8List sha1(Uint8List data) => Uint8List.fromList(crypto.sha1.convert(data).bytes);

/// K_seed = first 16 bytes of SHA-1(MRZ_information).
Uint8List computeKeySeed(String mrzInformation) {
  return sha1(Uint8List.fromList(ascii.encode(mrzInformation))).sublist(0, 16);
}

/// KDF per ICAO 9303 App D.1: SHA-1(seed || 00000000 | counter), first 16
/// bytes split into two 8-byte DES key halves (E = bytes 0-7, D = bytes 8-15)
/// — used directly as a 16-byte DESede key (2-key triple DES, E|D|E).
///
/// Deliberately does NOT set DES odd-parity bits on the digest bytes: cross-
/// checked against Elyctis's own ElyMRTD reference implementation's debug
/// log for this exact document (same MRZ-derived key seed, so directly
/// comparable) — its Kenc/Kmac are the raw SHA-1 bytes verbatim, no parity
/// adjustment. Setting parity here silently produced different key bytes,
/// which BAC's own encrypt/decrypt round-trip masked (both sides local, so
/// self-consistent either way) but caused every subsequent secure-messaging
/// command to fail against the real card.
Uint8List deriveKey(Uint8List keySeed, int counter) {
  final input = Uint8List(keySeed.length + 4);
  input.setRange(0, keySeed.length, keySeed);
  input[keySeed.length + 3] = counter;
  return sha1(input).sublist(0, 16);
}

Uint8List randomBytes(int length) {
  final rnd = Random.secure();
  return Uint8List.fromList(List<int>.generate(length, (_) => rnd.nextInt(256)));
}

/// ISO/IEC 9797-1 padding method 2: append 0x80 then zero-fill to the next
/// block boundary. Always adds at least one byte, even if already aligned.
Uint8List isoPad(Uint8List data, [int blockSize = 8]) {
  final padLen = blockSize - (data.length % blockSize);
  final out = Uint8List(data.length + padLen);
  out.setRange(0, data.length, data);
  out[data.length] = 0x80;
  return out;
}

Uint8List isoUnpad(Uint8List padded) {
  var i = padded.length - 1;
  while (i >= 0 && padded[i] == 0) {
    i--;
  }
  if (i < 0 || padded[i] != 0x80) {
    throw StateError('Invalid ISO 9797-1 padding');
  }
  return padded.sublist(0, i);
}

/// Single-DES ECB on one 8-byte block, implemented via pointycastle's
/// DESedeEngine with the 8-byte key repeated 3 times (K|K|K) — mathematically
/// identical to single DES since Enc(K) after Dec(K) after Enc(K) collapses
/// to a single Enc(K)/Dec(K).
Uint8List _singleDesBlock(Uint8List key8, Uint8List block8, {required bool encrypt}) {
  final engine = DESedeEngine()
    ..init(encrypt, KeyParameter(Uint8List.fromList([...key8, ...key8, ...key8])));
  final out = Uint8List(8);
  engine.processBlock(block8, 0, out, 0);
  return out;
}

/// 2-key triple DES (E-D-E) on one 8-byte block using a 16-byte key.
Uint8List tdesEcbBlock(Uint8List key16, Uint8List block8, {required bool encrypt}) {
  final engine = DESedeEngine()..init(encrypt, KeyParameter(key16));
  final out = Uint8List(8);
  engine.processBlock(block8, 0, out, 0);
  return out;
}

/// 2-key triple DES CBC over data whose length is a multiple of 8.
Uint8List tdesCbc(Uint8List key16, Uint8List iv8, Uint8List data, {required bool encrypt}) {
  final cipher = CBCBlockCipher(DESedeEngine())
    ..init(encrypt, ParametersWithIV(KeyParameter(key16), iv8));
  final out = Uint8List(data.length);
  for (var off = 0; off < data.length; off += 8) {
    cipher.processBlock(data, off, out, off);
  }
  return out;
}

/// ISO/IEC 9797-1 MAC algorithm 3 ("retail MAC"): single-DES CBC-MAC with K1
/// over all blocks, then Dec(K2) then Enc(K1) on the final block. [macKey16]
/// is K1 (bytes 0-7) || K2 (bytes 8-15) — the same layout `deriveKey`
/// produces. [paddedData] must already be padded to a multiple of 8.
Uint8List retailMac(Uint8List macKey16, Uint8List paddedData) {
  final k1 = macKey16.sublist(0, 8);
  final k2 = macKey16.sublist(8, 16);
  var h = Uint8List(8);
  for (var off = 0; off < paddedData.length; off += 8) {
    final block = Uint8List(8);
    for (var i = 0; i < 8; i++) {
      block[i] = paddedData[off + i] ^ h[i];
    }
    h = _singleDesBlock(k1, block, encrypt: true);
  }
  final decrypted = _singleDesBlock(k2, h, encrypt: false);
  return _singleDesBlock(k1, decrypted, encrypt: true);
}

bool bytesEqual(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
