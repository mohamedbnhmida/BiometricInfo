import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'bac_crypto.dart';
import 'dg2_parser.dart';
import 'pcsc.dart';
import 'tlv.dart';

/// Everything read from the chip. MRZ fields come from DG1, the photo from
/// DG2, the optional extras from DG7/DG11/DG12/DG13 (whichever EF.COM lists).
/// [images] holds the other pictures (signature, document scans) as JPEG.
class CardData {
  final Map<String, String> fields;
  final Uint8List? photoJpeg;
  final Map<String, Uint8List> images;
  CardData(this.fields, this.photoJpeg, [this.images = const {}]);
}

Uint8List _checkSw(Uint8List resp) {
  if (resp.length < 2) throw PcscException('Réponse APDU invalide');
  final sw1 = resp[resp.length - 2], sw2 = resp[resp.length - 1];
  if (sw1 != 0x90 || sw2 != 0x00) {
    throw PcscException(
      'La carte a répondu SW=${((sw1 << 8) | sw2).toRadixString(16).padLeft(4, '0')}',
    );
  }
  return resp.sublist(0, resp.length - 2);
}

Uint8List _plain(PcscSession s, List<int> apdu) =>
    _checkSw(s.transmit(Uint8List.fromList(apdu)));

/// BAC secure messaging (ICAO 9303) — same algorithm as the visitor app's
/// emrtd_reader.dart, without its APDU debug prints.
class _Sm {
  final Uint8List ksEnc, ksMac, ssc;
  _Sm(this.ksEnc, this.ksMac, this.ssc);

  void _inc() {
    for (var i = ssc.length - 1; i >= 0; i--) {
      ssc[i] = (ssc[i] + 1) & 0xFF;
      if (ssc[i] != 0) break;
    }
  }

  Uint8List send(PcscSession s, int ins, int p1, int p2, {Uint8List? data, int? le}) {
    _inc();
    Uint8List? do87;
    if (data != null) {
      final iv = Uint8List(8); // 3DES SM: zero IV (E(KSenc, SSC) is the AES rule)
      final v = [0x01, ...tdesCbc(ksEnc, iv, isoPad(data), encrypt: true)];
      do87 = Uint8List.fromList([0x87, ...encodeBerLength(v.length), ...v]);
    }
    final do97 = le == null ? null : Uint8List.fromList([0x97, 0x01, le & 0xFF]);
    final macIn = BytesBuilder()
      ..add(ssc)
      ..add(isoPad(Uint8List.fromList([0x0C, ins, p1, p2])));
    if (do87 != null) macIn.add(do87);
    if (do97 != null) macIn.add(do97);
    final body = [...?do87, ...?do97, 0x8E, 0x08, ...retailMac(ksMac, isoPad(macIn.toBytes()))];
    final resp = _checkSw(s.transmit(Uint8List.fromList([0x0C, ins, p1, p2, body.length, ...body, 0x00])));

    _inc();
    final tlvs = parseTlvSequence(resp);
    final r87 = findTag(tlvs, 0x87), r99 = findTag(tlvs, 0x99), r8e = findTag(tlvs, 0x8E);
    if (r99 == null || r8e == null) throw PcscException('Réponse sécurisée incomplète');
    final check = BytesBuilder()..add(ssc);
    if (r87 != null) check.add([0x87, ...encodeBerLength(r87.value.length), ...r87.value]);
    check.add([0x99, ...encodeBerLength(r99.value.length), ...r99.value]);
    if (!bytesEqual(retailMac(ksMac, isoPad(check.toBytes())), r8e.value)) {
      throw PcscException('MAC de réponse invalide');
    }
    if (r99.value[0] != 0x90 || r99.value[1] != 0x00) {
      throw PcscException(
        'La carte a répondu SW=${((r99.value[0] << 8) | r99.value[1]).toRadixString(16).padLeft(4, '0')}',
      );
    }
    if (r87 == null) return Uint8List(0);
    final iv = Uint8List(8); // 3DES SM: zero IV (E(KSenc, SSC) is the AES rule)
    return isoUnpad(tdesCbc(ksEnc, iv, r87.value.sublist(1), encrypt: false));
  }

  /// SELECT + READ BINARY of a whole elementary file.
  Uint8List readFile(PcscSession s, int fid) {
    send(s, 0xA4, 0x02, 0x0C, data: Uint8List.fromList([fid >> 8, fid & 0xFF]));
    final head = send(s, 0xB0, 0, 0, le: 8);
    if (head.length < 2) throw PcscException('Fichier vide');
    final total = 1 + berLengthByteCount(head, 1) + berLength(head, 1);
    final buf = BytesBuilder()..add(head);
    var off = head.length;
    while (off < total) {
      final part = send(s, 0xB0, off >> 8, off & 0xFF, le: (total - off).clamp(0, 200));
      if (part.isEmpty) break;
      buf.add(part);
      off += part.length;
    }
    return buf.toBytes();
  }
}

/// Debug console trace of each chip step ("[chip] …"); no-op in release.
void _log(String m) {
  assert(() {
    // ignore: avoid_print
    print('[chip] $m');
    return true;
  }());
}

/// Blocking: run it with Isolate.run. Dates are ISO "YYYY-MM-DD".
CardData readCardSync({
  required String documentNumber,
  required String birthDateIso,
  required String expiryDateIso,
}) {
  if (!PcscSession.isSupported) throw PcscException('Lecture disponible sous Windows et macOS uniquement');
  final s = PcscSession()..establish();
  try {
    final readers = s.listReaders();
    _log('readers: $readers');
    if (readers.isEmpty) throw PcscException('Aucun lecteur de cartes détecté');
    // Any reader: contactless first, then contact slots. The first reader
    // holding a card that answers the eMRTD application is used.
    final ordered = [...readers.where(looksContactless), ...readers.where((r) => !looksContactless(r))];
    var connected = false;
    final errors = <String>[];
    for (final r in ordered) {
      try {
        _log('connect $r …');
        s.connect(r);
        _log('connected $r');
      } on PcscException catch (e) {
        _log('connect failed: ${e.message}');
        errors.add(e.message); // No card / busy; try the next one.
        continue;
      }
      try {
        _plain(s, [0x00, 0xA4, 0x04, 0x0C, 0x07, 0xA0, 0x00, 0x00, 0x02, 0x47, 0x10, 0x01]);
        connected = true;
        _log('eMRTD application selected on $r');
        break;
      } on PcscException catch (e) {
        _log('SELECT eMRTD failed on $r: ${e.message}');
        // E.g. a CIN pushed into the contact slot: its contact chip only
        // holds the e-signature app (IAS Classic); photo and data are on
        // the contactless chip.
        errors.add('Cette puce ne contient pas les données d\'identité : '
            'posez la carte À PLAT sur le dessus du lecteur (sans contact), pas dans la fente.');
        s.disconnect();
      }
    }
    if (!connected) {
      final wrongChip = errors.where((e) => e.startsWith('Cette puce')).toList();
      throw PcscException(wrongChip.isNotEmpty
          ? wrongChip.first
          : 'Aucune carte détectée : posez la carte sur le lecteur\n${errors.join('\n')}');
    }
    try {
      final rndIcc = _plain(s, [0x00, 0x84, 0x00, 0x00, 0x08]);
      _log('challenge OK, running BAC');

      final seed = computeKeySeed(buildMrzInformation(
        documentNumber: documentNumber,
        birthDateIso: birthDateIso,
        expiryDateIso: expiryDateIso,
      ));
      final kEnc = deriveKey(seed, 1), kMac = deriveKey(seed, 2);
      final rndIfd = randomBytes(8), kIfd = randomBytes(16);
      final eIfd = tdesCbc(kEnc, Uint8List(8), Uint8List.fromList([...rndIfd, ...rndIcc, ...kIfd]), encrypt: true);
      final Uint8List auth;
      try {
        auth = _plain(s, [0x00, 0x82, 0x00, 0x00, 0x28, ...eIfd, ...retailMac(kMac, isoPad(eIfd)), 0x28]);
      } on PcscException catch (e) {
        throw PcscException(
            'Accès refusé : vérifiez le numéro, la date de naissance et la date d\'expiration\n(${e.message})');
      }
      _log('MUTUAL AUTHENTICATE answered (${auth.length} bytes)');
      final eIcc = auth.sublist(0, 32);
      if (!bytesEqual(retailMac(kMac, isoPad(eIcc)), auth.sublist(32, 40))) {
        throw PcscException('Accès refusé : données saisies incorrectes');
      }
      final r = tdesCbc(kEnc, Uint8List(8), eIcc, encrypt: false);
      if (!bytesEqual(r.sublist(0, 8), rndIcc) || !bytesEqual(r.sublist(8, 16), rndIfd)) {
        throw PcscException('Authentification échouée');
      }
      final kSeed = Uint8List(16);
      for (var i = 0; i < 16; i++) {
        kSeed[i] = kIfd[i] ^ r[16 + i];
      }
      final sm = _Sm(deriveKey(kSeed, 1), deriveKey(kSeed, 2),
          Uint8List.fromList([...rndIcc.sublist(4), ...rndIfd.sublist(4)]));

      // EF.COM lists the data groups present; fall back to the usual ones.
      var dgs = {7, 11, 12, 13};
      try {
        final com = findTag(parseTlvSequence(sm.readFile(s, 0x011E)), 0x60);
        final list = com == null ? null : findTag(parseTlvSequence(com.value), 0x5C);
        if (list != null) dgs = {for (final t in list.value) ?_dgByTag[t]};
      } on Object {
        // No EF.COM: keep the defaults.
      }

      _log('BAC OK, data groups: $dgs');
      final fields = parseDg1(sm.readFile(s, 0x0101));
      _log('DG1 read: ${fields.length} fields');
      final photo = extractFacePhotoFromDg2(sm.readFile(s, 0x0102));
      _log('DG2 photo: ${photo?.length ?? 0} bytes');
      final images = <String, Uint8List>{};
      for (final dg in [7, 11, 12, 13]) {
        if (!dgs.contains(dg)) continue;
        try {
          fields.addAll(parseTextDg(sm.readFile(s, 0x0100 + dg), images));
          _log('DG$dg read');
        } on Object catch (e) {
          _log('DG$dg skipped: $e');
          // Optional groups: a missing/odd file must not lose DG1/DG2.
        }
      }
      if (dgs.contains(3) || dgs.contains(4)) {
        fields['Empreintes / iris'] = 'Présents mais protégés (EAC) : lecture réservée aux autorités émettrices';
      }
      for (final k in images.keys.toList()) {
        final j = toJpeg(images[k]!);
        if (j == null) {
          images.remove(k);
        } else {
          images[k] = j;
        }
      }
      return CardData(fields, photo == null ? null : toJpeg(photo), images);
    } finally {
      s.disconnect();
    }
  } finally {
    s.release();
  }
}

/// DG2 may hold JPEG2000, which neither Flutter nor the pdf package decode.
/// macOS converts it with the built-in `sips`.
/// ponytail: Windows JPEG2000 is not converted (returns null → no photo);
/// reuse the visitor app's freeimage_native.dart if a Windows client needs it.
Uint8List? toJpeg(Uint8List img) {
  if (isJpeg(img)) return img;
  if (!Platform.isMacOS) return null;
  final dir = Directory.systemTemp.createTempSync('bioinfo');
  try {
    final src = File('${dir.path}/p.jp2')..writeAsBytesSync(img);
    final out = '${dir.path}/p.jpg';
    Process.runSync('sips', ['-s', 'format', 'jpeg', src.path, '--out', out]);
    final f = File(out);
    return f.existsSync() ? f.readAsBytesSync() : null;
  } finally {
    dir.deleteSync(recursive: true);
  }
}

String _clean(String s) => s.replaceAll('<', ' ').replaceAll(RegExp(r' +'), ' ').trim();

String _date(String yymmdd, {required bool future}) {
  if (!RegExp(r'^\d{6}$').hasMatch(yymmdd)) return yymmdd;
  final yy = int.parse(yymmdd.substring(0, 2));
  final now = DateTime.now().year % 100;
  // Birth dates are in the past, expiry dates up to ~20 years ahead.
  final century = future ? (yy <= now + 20 ? 2000 : 1900) : (yy <= now ? 2000 : 1900);
  return '${yymmdd.substring(4)}/${yymmdd.substring(2, 4)}/${century + yy}';
}

String _docTypeLabel(String code) => switch (code.isEmpty ? '' : code[0]) {
      'P' => 'Passeport',
      'I' || 'A' || 'C' => 'Carte d\'identité',
      'V' => 'Visa',
      _ => code,
    };

final _arabicWord = RegExp(r'[\u0600-\u06FF]');
const _sexWords = {'M', 'F', 'X', 'ذكر', 'أنثى', 'انثى'};
final _bloodGroup = RegExp(r'^(A|B|AB|O|0)\s*(RH)?\s*[+-]$', caseSensitive: false);

/// DG1 = 0x61 → 0x5F1F MRZ text. TD1 (ID card, 3×30), TD2 (2×36), TD3 (passport, 2×44).
Map<String, String> parseDg1(Uint8List dg1) {
  final outer = findTag(parseTlvSequence(dg1), 0x61);
  final mrzTag = outer == null ? null : findTag(parseTlvSequence(outer.value), 0x5F1F);
  if (mrzTag == null) throw PcscException('DG1 illisible');
  final m = ascii.decode(mrzTag.value, allowInvalid: true);
  final String docType, country, docNo, dob, sex, exp, nat, names, optional;
  if (m.length == 90) {
    docType = m.substring(0, 2);
    country = m.substring(2, 5);
    docNo = m.substring(5, 14);
    optional = m.substring(15, 30);
    dob = m.substring(30, 36);
    sex = m.substring(37, 38);
    exp = m.substring(38, 44);
    nat = m.substring(45, 48);
    names = m.substring(60, 90);
  } else {
    final w = m.length == 72 ? 36 : 44;
    docType = m.substring(0, 2);
    country = m.substring(2, 5);
    names = m.substring(5, w);
    docNo = m.substring(w, w + 9);
    nat = m.substring(w + 10, w + 13);
    dob = m.substring(w + 13, w + 19);
    sex = m.substring(w + 20, w + 21);
    exp = m.substring(w + 21, w + 27);
    optional = m.length == 88 ? m.substring(w + 28, w + 42) : m.substring(w + 28, w + 35);
  }
  final parts = names.split('<<');
  return {
    'Nom': _clean(parts.first),
    'Prénom(s)': _clean(parts.skip(1).join(' ')),
    'N° de document': _clean(docNo),
    'Type de document': _docTypeLabel(_clean(docType)),
    'Pays émetteur': _clean(country),
    'Nationalité': _clean(nat),
    'Date de naissance': _date(dob, future: false),
    'Sexe': switch (sex) { 'M' => 'Masculin', 'F' => 'Féminin', _ => 'Non précisé' },
    'Date d\'expiration': _date(exp, future: true),
    if (_clean(optional).isNotEmpty) 'Données complémentaires': _clean(optional),
  };
}

const _dgByTag = {
  0x61: 1, 0x75: 2, 0x63: 3, 0x76: 4, 0x65: 5, 0x66: 6, 0x67: 7, 0x68: 8,
  0x69: 9, 0x6A: 10, 0x6B: 11, 0x6C: 12, 0x6D: 13, 0x6E: 14, 0x6F: 15, 0x70: 16,
};

/// ICAO 9303 part 10 tags of DG7 (signature), DG11 (personal details) and
/// DG12 (document details). Anything else (e.g. DG13, national data) is
/// shown under its raw tag.
const _labels = {
  0x5F0E: 'Nom complet',
  0x5F0F: 'Autre(s) nom(s)',
  0x5F10: 'N° personnel',
  0x5F2B: 'Date de naissance (complète)',
  0x5F11: 'Lieu de naissance',
  0x5F42: 'Adresse',
  0x5F12: 'Téléphone',
  0x5F13: 'Profession',
  0x5F14: 'Titre',
  0x5F15: 'Résumé personnel',
  0x5F17: 'Autres documents de voyage',
  0x5F18: 'Informations de garde',
  0x5F19: 'Autorité de délivrance',
  0x5F26: 'Date de délivrance',
  0x5F1A: 'Autres personnes',
  0x5F1B: 'Mentions / observations',
  0x5F1C: 'Taxes / sortie',
  0x5F55: 'Date de personnalisation',
  0x5F56: 'N° du système de personnalisation',
};
const _imageLabels = {
  0x5F43: 'Signature',
  0x5F16: 'Preuve de citoyenneté',
  0x5F1D: 'Image recto',
  0x5F1E: 'Image verso',
};

/// Card text is UTF-8 per ICAO, but some issuers (e.g. Algeria) store Arabic
/// one byte per letter.
/// ponytail: non-UTF-8 is read as ISO-8859-6; switch to a Windows-1256 table
/// if a card shows wrong Arabic letters.
String decodeCardText(Uint8List b) {
  try {
    return utf8.decode(b);
  } on FormatException {
    return String.fromCharCodes(b.map((c) => c >= 0xAC && c != 0xAD ? c + 0x560 : c));
  }
}

String _prettyDate(String v) {
  final d = RegExp(r'^(\d{4})(\d{2})(\d{2})(\d{2})?(\d{2})?\d*$').firstMatch(v);
  if (d == null) return v;
  final date = '${d[3]}/${d[2]}/${d[1]}';
  return d[4] == null ? date : '$date ${d[4]}:${d[5] ?? '00'}';
}

/// DG7 / DG11 / DG12 / DG13: one outer template holding text tags (some
/// nested in A0/A1 lists). Text goes to the returned map, pictures to [images].
Map<String, String> parseTextDg(Uint8List dg, Map<String, Uint8List> images) {
  final out = <String, String>{};
  void walk(List<Tlv> tlvs) {
    for (final t in tlvs) {
      if (t.tag == 0x5C || t.tag == 0x02 || t.value.isEmpty) continue;
      if (t.tag == 0xA0 || t.tag == 0xA1) {
        walk(parseTlvSequence(t.value));
        continue;
      }
      if (_imageLabels.containsKey(t.tag)) {
        var label = _imageLabels[t.tag]!;
        for (var n = 2; images.containsKey(label); n++) {
          label = '${_imageLabels[t.tag]} $n';
        }
        images[label] = t.value;
        continue;
      }
      final text = _clean(decodeCardText(t.value));
      // ponytail: national tags (DG13) are undocumented; recognise a blood
      // group by its value, show the rest under the raw tag.
      final label = _labels[t.tag] ??
          (_bloodGroup.hasMatch(text) ? 'Groupe sanguin' : 'Donnée ${t.tag.toRadixString(16).toUpperCase()}');
      final v = const {0x5F2B, 0x5F26, 0x5F55}.contains(t.tag) ? _prettyDate(text) : text;
      if (v.isEmpty) continue;
      // Some cards (Algeria) pack sex + blood group into one field ("M ذكر O+"):
      // the blood group gets its own field, the sex is already in DG1.
      final tokens = v.split(' ');
      if (tokens.every((w) => _bloodGroup.hasMatch(w) || _sexWords.contains(w))) {
        for (final w in tokens.where(_bloodGroup.hasMatch)) {
          out['Groupe sanguin'] = w.toUpperCase();
        }
        continue;
      }
      // Mixed values ("SI AHMED سي أحمد") become a Latin and an Arabic field.
      final words = v.split(' ');
      final ar = words.where(_arabicWord.hasMatch).join(' ');
      final latin = words.where((w) => !_arabicWord.hasMatch(w)).join(' ');
      void add(String l, String x) {
        if (x.isNotEmpty) out.update(l, (old) => '$old / $x', ifAbsent: () => x);
      }
      add(label, latin);
      add('$label (arabe)', ar);
    }
  }

  walk(parseTlvSequence(parseTlvSequence(dg).first.value));
  return out;
}
