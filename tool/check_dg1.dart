// Self-check: dart run tool/check_dg1.dart
import 'dart:convert';
import 'dart:typed_data';

import 'package:biometric_info/chip/card_reader.dart';

void main() {
  const mrz = 'I<UTOD231458907<<<<<<<<<<<<<<<'
      '7408122F1204159UTO<<<<<<<<<<<6'
      'ERIKSSON<<ANNA<MARIA<<<<<<<<<<';
  final inner = [0x5F, 0x1F, 90, ...ascii.encode(mrz)];
  final f = parseDg1(Uint8List.fromList([0x61, inner.length, ...inner]));
  assert(f['Nom'] == 'ERIKSSON', f['Nom']);
  assert(f['Prénom(s)'] == 'ANNA MARIA', f['Prénom(s)']);
  assert(f['N° de document'] == 'D23145890', f['N° de document']);
  assert(f['Date de naissance'] == '12/08/1974', f['Date de naissance']);
  assert(f["Date d'expiration"] == '15/04/2012', f["Date d'expiration"]);
  assert(f['Sexe'] == 'Féminin');
  print('ok');
}
