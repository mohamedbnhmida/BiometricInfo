import 'package:biometric_info/chip/pcsc.dart';
import 'package:biometric_info/mrz/mrz_parser.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('douchette TD3 + TD1 lines parse to the chip access fields', () {
    final p = MrzParser.parse('P<UTOERIKSSON<<ANNA<MARIA<<<<<<<<<<<<<<<<<<<\nL898902C36UTO7408122F1204159ZE184226B<<<<<10')!;
    expect([p.documentNumber, p.birthDate, p.expiryDate], ['L898902C3', '1974-08-12', '2012-04-15']);
    final i = MrzParser.parse('I<UTOD231458907<<<<<<<<<<<<<<<\n7408122F1204159UTO<<<<<<<<<<<6\nERIKSSON<<ANNA<MARIA<<<<<<<<<<')!;
    expect([i.documentNumber, i.birthDate, i.expiryDate], ['D23145890', '1974-08-12', '2012-04-15']);
  });

  test('contactless slot detected for uTrust and ACS ACR1281', () {
    for (final r in ['Identiv uTrust 4701 F CL Reader 0', 'Identiv uTrust 4701 F Dual Interface Reader(1)',
        'ACS ACR1281 1S Dual Reader PICC 0', 'ACS ACR1281 1S Dual Reader(1)']) {
      expect(looksContactless(r), isTrue, reason: r);
    }
    for (final r in ['ACS ACR1281 1S Dual Reader ICC 0', 'ACS ACR1281 1S Dual Reader SAM 0',
        'ACS ACR1281 1S Dual Reader(2)', 'Identiv uTrust 4701 F Dual Interface Reader(2)']) {
      expect(looksContactless(r), isFalse, reason: r);
    }
  });
}
