import 'package:flutter/foundation.dart';
import 'package:mrz_parser/mrz_parser.dart';
import 'scanner_utils.dart';

class MrzResult {
  final String documentType;
  final String issuingCountry;
  final String lastName;
  final String firstName;
  final String documentNumber;
  final String nationality;
  final String birthDate; // YYYY-MM-DD
  final String sex;
  final String expiryDate; // YYYY-MM-DD
  final String personalId;

  MrzResult({
    required this.documentType,
    required this.issuingCountry,
    required this.lastName,
    required this.firstName,
    required this.documentNumber,
    required this.nationality,
    required this.birthDate,
    required this.sex,
    required this.expiryDate,
    required this.personalId,
  });

  bool get isValid => documentNumber.isNotEmpty && lastName.isNotEmpty;
}

class MrzParser {
  /// Robustly parses MRZ strings by finding key TD1/TD3 segments.
  /// Handles non-standard formats (e.g., Algerian IDs using '@')
  /// and automatically corrects AZERTY/QWERTY layout mismatches.
  static MrzResult? parse(String mrzString) {
    if (mrzString.isEmpty) return null;

    debugPrint('--- MRZ Parse Input ---');
    debugPrint('Raw Length: ${mrzString.length}');
    debugPrint('Raw Input: $mrzString');

    // Strategy 1: Raw / Basic normalization
    var result = _tryParseLayout(mrzString);
    if (result != null) {
      debugPrint('Success: Parsed with raw input.');
      return result;
    }

    // Strategy 2: Numeric-heavy recovery (Treat §, ! as digits 6, 8)
    debugPrint('Attempting Numeric-heavy recovery...');
    String recoveredNum = ScannerUtils.unscramble(
      mrzString,
      variant: ScannerVariant.numeric,
    );
    debugPrint('Recovered (Numeric): $recoveredNum');

    var resNum = _tryParseLayout(recoveredNum);
    if (resNum != null) {
      debugPrint('Success: Parsed with Numeric-heavy layout.');
      return resNum;
    }

    // Strategy 3: Filler-heavy recovery (Treat §, ! as fillers <)
    debugPrint('Attempting Filler-heavy recovery...');
    String recoveredFil = ScannerUtils.unscramble(
      mrzString,
      variant: ScannerVariant.filler,
    );
    debugPrint('Recovered (Filler): $recoveredFil');

    var resFil = _tryParseLayout(recoveredFil);
    if (resFil != null) {
      debugPrint('Success: Parsed with Filler-heavy layout.');
      return resFil;
    }

    // Strategy 4: Structural Recovery (Positional repair)
    debugPrint('Attempting Structural recovery...');
    String recoveredStr = ScannerUtils.unscrambleStructural(mrzString);
    debugPrint('Recovered (Structural): $recoveredStr');

    var resStr = _tryParseLayout(recoveredStr);
    if (resStr != null) {
      debugPrint('Success: Parsed with Structural layout.');
      return resStr;
    }

    debugPrint('FAILED: Format MRZ inconnu for input: $mrzString');
    return null;
  }

  static MrzResult? _tryParseLayout(String mrzString) {
    try {
      // Normalize common scanner variations
      String raw = mrzString
          .replaceAll(RegExp(r'\s+'), '')
          .toUpperCase()
          .replaceAll('@', '<')
          .replaceAll('»', '<')
          .replaceAll('ˆ', '<');

      // Before splitting into lines, we can try to fix certain O-errors in numeric regions.
      // However, it's safer to do it line-by-line if we know which line is which.
      // But for a quick fix, let's at least handle it during extraction.

      List<String> lines = [];
      // ... existing logic to find lines (already robust) ...

      // 1. Try fixed-length splitting first (Standard MRZ)
      if (raw.length == 90) {
        lines = [
          raw.substring(0, 30),
          raw.substring(30, 60),
          raw.substring(60, 90),
        ];
      } else if (raw.length == 88) {
        lines = [raw.substring(0, 44), raw.substring(44, 88)];
      } else if (raw.length == 72) {
        lines = [raw.substring(0, 36), raw.substring(36, 72)];
      }

      // If fixed length split exists, try to parse it immediately
      if (lines.isNotEmpty) {
        final result = MRZParser.tryParse(lines);
        if (result != null) {
          return MrzResult(
            documentType: result.documentType == 'I' && lines[0].startsWith('DL') 
                ? 'DL' 
                : (result.documentType == 'I' ? 'CIN' : result.documentType),
            issuingCountry: result.countryCode,
            lastName: result.surnames,
            firstName: result.givenNames,
            documentNumber: result.documentNumber,
            nationality: result.nationalityCountryCode,
            birthDate: _formatDate(result.birthDate, isExpiry: false),
            sex: result.sex == Sex.male
                ? 'M'
                : (result.sex == Sex.female ? 'F' : 'X'),
            expiryDate: _formatDate(result.expiryDate, isExpiry: true),
            personalId: result.personalNumber,
          );
        }
        
        // If fixed split failed but it's Algerian, try manual parse as fallback
        if (lines[0].contains('DZA')) {
           final manual = _manualParseAlgerian(lines);
           if (manual != null && manual.isValid) return manual;
        }
        
        // If we reach here, the fixed-length data was unparsable.
        // We'll clear 'lines' to allow the Robust logic below to try and find valid segments
        // (which might happen if the 90 chars contained leading/trailing noise).
        lines = [];
      }

      // 2. Try to find 3 lines for TD1 using robust regex (Handles noise/offsets)
      if (raw.contains('ID') || raw.contains('DL') || raw.contains('I<') || raw.length > 50) {
        String? line1, line2, line3;
        
        // Find Line 1: Info (IDDZA or DLDZA...)
        // Tolerates '7' instead of 'I'
        final l1Match = RegExp(r'([ID7][A-Z0-9<][A-Z0-9<]{3}[A-Z0-9<]{10,25})').firstMatch(raw);
        if (l1Match != null) {
          line1 = l1Match.group(0)!;
          if (line1.startsWith('7')) line1 = 'I' + line1.substring(1);
          if (line1.length > 30) line1 = line1.substring(0, 30);
          line1 = line1.padRight(30, '<');
        }

        // Find Line 2: Bio (Birth/Sex/Expiry)
        // Relaxed regex: allows digits and common OCR errors. 
        // We ensure it doesn't match the same start as Line 1 if possible.
        final l2Match = RegExp(r'([A-Z0-9<]{6,7}[MF<][A-Z0-9<]{6,7}[A-Z<]{1,3}[A-Z0-9<]*)').firstMatch(
          line1 != null ? raw.replaceFirst(line1.replaceAll('<', ''), '') : raw
        );
        if (l2Match != null) {
          line2 = l2Match.group(0)!;
          line2 = _cleanBioLine(line2);
          if (line2.length > 30) line2 = line2.substring(0, 30);
          line2 = line2.padRight(30, '<');
        }

        // Find Line 3: Name
        final l3Match = RegExp(r'([A-Z<]{2,}<<[A-Z<]+)').firstMatch(raw);
        if (l3Match != null) {
          line3 = l3Match.group(0)!;
          if (line3.length > 30) line3 = line3.substring(0, 30);
          line3 = line3.padRight(30, '<');
        }

        if (line1 != null && (line2 != null || line3 != null)) {
          debugPrint('Identified TD1 Lines (Robust):');
          debugPrint(' - Line 1: $line1');
          debugPrint(' - Line 2: ${line2 ?? "MISSING"}');
          debugPrint(' - Line 3: ${line3 ?? "MISSING"}');
          lines = [line1, line2 ?? ("<" * 30), line3 ?? ("<" * 30)];
        }
      }

      if (lines.isEmpty) return null;

      final result = MRZParser.tryParse(lines);
      if (result == null) {
        // LAST RESORT: Manual extraction for Algerian TD1/TD3
        if (lines.isNotEmpty && lines[0].contains('DZA')) {
          return _manualParseAlgerian(lines);
        }
        return null;
      }

      return MrzResult(
        documentType: result.documentType == 'I' && lines.isNotEmpty && lines[0].startsWith('DL') 
            ? 'DL' 
            : (result.documentType == 'I' ? 'CIN' : result.documentType),
        issuingCountry: result.countryCode,
        lastName: result.surnames,
        firstName: result.givenNames,
        documentNumber: result.documentNumber,
        nationality: result.nationalityCountryCode,
        birthDate: _formatDate(result.birthDate, isExpiry: false),
        sex: result.sex == Sex.male
            ? 'M'
            : (result.sex == Sex.female ? 'F' : 'X'),
        expiryDate: _formatDate(result.expiryDate, isExpiry: true),
        personalId: result.personalNumber,
      );
    } catch (e) {
      return null;
    }
  }

  static String _formatDate(DateTime? date, {bool isExpiry = false}) {
    if (date == null) return '';
    int year = date.year;
    
    // Safety check for future expiry dates
    if (isExpiry && year < 2000) {
      year += 100;
    }

    final y = year.toString().padLeft(4, '0');
    final m = date.month.toString().padLeft(2, '0');
    final d = date.day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }

  static String _cleanBioLine(String line) {
    if (line.length < 15) return line;
    // DOB is 0-5, Check is 6, Sex is 7, Expiry is 8-13, Check is 14
    List<String> chars = line.split('');

    void cleanDigit(int index) {
      if (index < chars.length) {
        String c = chars[index];
        if (c == 'O' || c == 'Q') {
          chars[index] = '0';
        } else if (c == 'I' || c == 'L') {
          chars[index] = '1';
        } else if (c == 'Z') {
          chars[index] = '2';
        } else if (c == 'S') {
          chars[index] = '5';
        } else if (c == 'B') {
          chars[index] = '8';
        }
      }
    }

    // Clean DOB region
    for (int i = 0; i < 7; i++) {
      cleanDigit(i);
    }
    // Clean Expiry region
    for (int i = 8; i < 15; i++) {
      cleanDigit(i);
    }

    return chars.join('');
  }

  /// Manual extraction for Algerian TD1 when standard parser fails.
  /// Line 1: [ID][Type][Country][IDNumber(9)][Check][Fillers]
  /// Line 2: [DOB(6)][Check][Sex][Expiry(6)][Check][Nationality(3)][Optional][Check]
  /// Line 3: [Surname]<<[GivenNames]
  static MrzResult? _manualParseAlgerian(List<String> lines) {
    if (lines.isEmpty) return null;
    String l1 = lines[0];
    String? l2 = lines.length > 1 ? lines[1] : null;
    String? l3 = lines.length > 2 ? lines[2] : null;

    // 1. Doc Number from Line 1 (chars 5-14)
    String docNum = "";
    if (l1.length >= 14) {
      docNum = l1.substring(5, 14);
    } else if (l1.length >= 9) {
      docNum = l1.substring(0, 9); // Fallback for truncated line 1
    }
    // Clean ID number (common OCR errors)
    docNum = docNum.replaceAll('O', '0').replaceAll('Q', '0').replaceAll('I', '1').replaceAll('L', '1').replaceAll('S', '5').replaceAll('B', '8');

    // 2. Name from Line 3
    String lastName = "";
    String firstName = "";
    if (l3 != null && l3.contains('<<')) {
      final parts = l3.split('<<');
      lastName = parts[0].replaceAll('<', ' ').trim();
      if (parts.length > 1) {
        firstName = parts[1].replaceAll('<', ' ').trim();
      }
    }

    // 3. Bio from Line 2 (If available)
    String birth = "";
    String sex = "";
    String expiry = "";
    if (l2 != null && l2.length >= 15) {
      birth = l2.substring(0, 6);
      sex = l2[7];
      expiry = l2.substring(8, 14);
    }

    if (docNum.isEmpty && lastName.isEmpty) return null;

    return MrzResult(
      documentType: l1.startsWith('DL') ? 'DL' : 'CIN',
      issuingCountry: 'DZA',
      lastName: lastName,
      firstName: firstName,
      documentNumber: docNum,
      nationality: 'DZA',
      birthDate: birth.length == 6 ? _manualFormatDate(birth) : "",
      sex: (sex == 'M' || sex == 'F') ? sex : "",
      expiryDate: expiry.length == 6 ? _manualFormatDate(expiry, isExpiry: true) : "",
      personalId: "",
    );
  }

  static String _manualFormatDate(String raw, {bool isExpiry = false}) {
    if (raw.length != 6) return "";
    final yy = raw.substring(0, 2);
    final mm = raw.substring(2, 4);
    final dd = raw.substring(4, 6);
    
    int year = int.tryParse(yy) ?? 0;
    if (isExpiry) {
      year += 2000;
    } else {
      year += (year < 30) ? 2000 : 1900;
    }
    return "$year-$mm-$dd";
  }
}
