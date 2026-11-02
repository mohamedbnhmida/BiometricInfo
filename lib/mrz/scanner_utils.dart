enum ScannerVariant {
  numeric, // Map symbols (!, §, etc) to digits (8, 6, etc)
  filler,  // Map symbols (!, §, etc) to fillers (<)
}

class ScannerUtils {
  /// Maps scrambled characters back to standard using a hybrid strategy.
  static String unscramble(String input, {required ScannerVariant variant}) {
    if (input.isEmpty) return input;

    // Intelligent decision: if it already looks like a valid Algerian header (IDDZA),
    // don't apply the AWZQ letter swaps which would corrupt it.
    bool shouldSwapLetters = true;
    String upper = input.toUpperCase();
    if (upper.startsWith('IDDZA') || upper.startsWith('IDD ZA')) {
      shouldSwapLetters = false;
    } else if (upper.contains('IDDWQ') || upper.contains('IDD WQ')) {
      shouldSwapLetters = true; // Definitely swapped
    } else {
      // General heuristic: swap if it contains typical symbols that indicate a shifted layout
      const symbols = ['&', '\u00E9', '"', "'", '(', ')', '-', '\u00E8', '\u00E7', '\u00E0', '\u00A7', '!', '*'];
      shouldSwapLetters = symbols.any((s) => upper.contains(s));
    }

    final Map<String, String> map = {};
    
    // Letters (AZERTY/QWERTY swaps) - only if likely scrambled
    if (shouldSwapLetters) {
      map.addAll({
        "A": "Q", "Q": "A", "Z": "W", "W": "Z",
        "M": ",", "?": "M", ":": "M", ";": "M",
      });
    }

    // Always map standard separators
    map.addAll({"»": "<", "ˆ": "<", "@": "<"});

    if (variant == ScannerVariant.numeric) {
      map.addAll({
        "&": "1", "\u00E9": "2", "\u00C9": "2", "@": "2", "\"": "3", "#": "3",
        "'": "4", r"$": "4", "‘": "4", "’": "4",
        "(": "9", "%": "5",
        "-": "6", "\u00A7": "6", "^": "6",
        "\u00E8": "7", "\u00C8": "7",
        "_": "8", "!": "8", "*": "8",
        "\u00E7": "9", "\u00C7": "9",
        "\u00E0": "0", "\u00C0": "0", ")": "0", "\u00B0": "0",
        ".": "<",
        // Common OCR errors
        "O": "0", "I": "1", "L": "1", "Z": "2", "S": "5", "B": "8",
      });
    } else {
      map.addAll({
        "&": "1", "\u00E9": "2", "\u00C9": "2", "\"": "3", "'": "4",
        "(": "9", "%": "5",
        "-": "6", "\u00E8": "7", "\u00C8": "7",
        "_": "8", "\u00E7": "9", "\u00C7": "9",
        "\u00E0": "0", "\u00C0": "0", ")": "0",
        "\u00A7": "<", "!": "<", ".": "<", "*": "<", r"$": "<",
      });
    }

    String recovered = "";
    for (int i = 0; i < upper.length; i++) {
      String char = upper[i];
      recovered += map[char] ?? char;
    }
    return recovered;
  }

  /// Structural repair based on the 30x3 Algerian TD1 layout.
  /// Repairs based on context (ID number zone vs Filler zone).
  static String unscrambleStructural(String input) {
    if (input.isEmpty) return input;
    
    // 1. Normalize global letter swaps
    String cleaned = input.toUpperCase()
        .replaceAll("W", "Z").replaceAll("Q", "A") // Global swaps
        .replaceAll("\n", "").replaceAll("\r", "").trim();

    // 2. Identify segments (Approx 30 chars each)
    if (cleaned.length < 50) return unscramble(cleaned, variant: ScannerVariant.numeric);

    // Common Zone Maps
    final numMap = {
      "&": "7", // Shifted 7
      "é": "2", "É": "2", "@": "2", "\"": "3", "#": "3",
      "'": "4", "\$": "4", "(": "9", "%": "5", "-": "6", "§": "6", 
      "^": "6", "è": "7", "_": "8", "!": "1", "*": "8", "ç": "9", "à": "0", "°": "0",
      ")": "0", "«": "2", "<": "2",
    };
    final filMap = {
      "§": "<", "!": "<", ".": "<", "@": "<", "»": "<", "ˆ": "<", "*": "<", "\$": "<", "«": "<"
    };

    String repair(String part, Map<String, String>? override) {
      String res = "";
      for (int i = 0; i < part.length; i++) {
        String c = part[i];
        if (override != null && override.containsKey(c)) {
          res += override[c]!;
        } else if (numMap.containsKey(c)) {
          res += numMap[c]!;
        } else if (filMap.containsKey(c)) {
          res += filMap[c]!;
        } else {
          res += c;
        }
      }
      return res;
    }

    int lineLen = (cleaned.length / 3).floor();
    List<String> lines = [];
    for (int i = 0; i < 3; i++) {
      int start = i * lineLen;
      int end = (i + 1) * lineLen;
      if (i == 2) end = cleaned.length;
      lines.add(cleaned.substring(start, end));
    }

    String result = "";
    
    // Line 1 Repair
    if (lines.length > 0) {
      String l1 = lines[0];
      String header = l1.substring(0, (5 < l1.length) ? 5 : l1.length);
      String rest = (l1.length > 5) ? l1.substring(5) : "";
      String idPart = rest.substring(0, (10 < rest.length) ? 10 : rest.length);
      String fillPart = (rest.length > 10) ? rest.substring(10) : "";
      result += repair(header, null);
      result += repair(idPart, numMap);
      result += repair(fillPart, filMap);
    }

    // Line 2 Repair
    if (lines.length > 1) {
      String l2 = lines[1];
      String bioPart = l2.substring(0, (15 < l2.length) ? 15 : l2.length);
      String nationPart = (l2.length > 15) ? l2.substring(15, (18 < l2.length) ? 18 : l2.length) : "";
      String fillPart = (l2.length > 18) ? l2.substring(18) : "";
      result += repair(bioPart, numMap);
      result += repair(nationPart, null);
      result += repair(fillPart, filMap);
    }

    // Line 3 Repair
    if (lines.length > 2) {
      String l3 = lines[2];
      result += repair(l3, filMap);
    }

    return result;
  }

  /// Checks if a string looks like it was scanned with the wrong layout (e.g. contains 'IDDWQ')
  static bool looksScrambled(String input) {
    input = input.toUpperCase();
    return input.contains('IDDWQ') || 
           input.contains('&') || 
           input.contains('é') || 
           input.contains('à');
  }
}
