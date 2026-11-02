import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart' as pkg_ffi;
import 'package:win32/win32.dart' as win32;

/// Thrown for any PC/SC (smartcard reader subsystem) failure — no reader
/// present, no card on the reader, a transmit error, etc.
class PcscException implements Exception {
  final String message;
  PcscException(this.message);
  @override
  String toString() => 'PcscException: $message';
}

/// Contactless readers (e.g. "uTrust 4701 F CL Reader") are the only ones
/// that can talk to an eMRTD chip (a CIN's contact chip only holds the
/// e-signature app). With Identiv's macOS driver the uTrust 4701 F shows up
/// as "Dual Interface Reader(1)" = contactless top pad and "(2)" = contact
/// slot (checked from the card ATRs: 3B 8x 80 01… on (1), 3B 6E… on (2)).
/// ACS ACR1281U-C1: "ACS ACR1281 1S Dual Reader PICC 0" on Windows (ICC =
/// contact, SAM = SAM slot), "ACS ACR1281 1S Dual Reader(1)" on macOS.
/// ponytail: name-based; read the ATR (SCardStatus) if another reader
/// shows up with a different layout.
String _connectError(String reader, int rc) => switch (rc & 0xFFFFFFFF) {
      0x8010000B => 'Lecteur occupé par une autre application (fermez NFC Tools) : $reader',
      0x8010000C || 0x80100069 => 'Aucune carte sur $reader (0x${(rc & 0xFFFFFFFF).toRadixString(16)})',
      final c => 'Connexion impossible à $reader (0x${c.toRadixString(16)})',
    };

bool looksContactless(String readerName) {
  final n = readerName.toLowerCase();
  return n.contains('contactless') ||
      RegExp(r'\b(cl|picc)\b').hasMatch(n) ||
      RegExp(r'dual (interface )?reader\s*\(1\)').hasMatch(n);
}

// PC/SC Part 3 reader-attribute tags (winsmcrd.h) — stable, spec-defined
// values, not exported by package:win32.
const int _scardAttrVendorName = 0x00010100;
const int _scardAttrVendorIfdType = 0x00010101;
const int _scardAttrVendorIfdVersion = 0x00010102;
const int _scardAttrVendorIfdSerialNo = 0x00010103;

/// Diagnostic only, Windows: connects directly to a reader (SCARD_SHARE_
/// DIRECT — works with no card present, unlike the exclusive/shared modes
/// [PcscSession.connect] uses for an actual chip session) and reads
/// whatever vendor/serial attributes the CCID driver exposes. Used to
/// compare against a device's printed label serial when investigating
/// hardware-bound licensing — not used by the chip-read path.
Map<String, String> readReaderAttributes(String readerName) {
  if (!Platform.isWindows) return {'error': 'Windows-only diagnostic'};
  final result = <String, String>{};
  final phContext = pkg_ffi.calloc<ffi.IntPtr>();
  int context = 0;
  try {
    final rcCtx = win32.SCardEstablishContext(
      _scardScopeSystem,
      ffi.nullptr,
      ffi.nullptr,
      phContext,
    );
    if (rcCtx != 0) {
      return {
        'error': 'SCardEstablishContext failed (0x${rcCtx.toRadixString(16)})',
      };
    }
    context = phContext.value;

    final name = readerName.toNativeUtf16();
    final phCard = pkg_ffi.calloc<ffi.IntPtr>();
    final pdwProtocol = pkg_ffi.calloc<ffi.Uint32>();
    try {
      // SCARD_SHARE_DIRECT (3), no protocol — talking to the reader itself,
      // not negotiating a card session.
      final rc = win32.SCardConnect(context, name, 3, 0, phCard, pdwProtocol);
      if (rc != 0) {
        result['error'] =
            'SCardConnect(DIRECT) failed (0x${rc.toRadixString(16)})';
        return result;
      }
      final hCard = phCard.value;
      try {
        result['vendorName'] = _readAttribAsText(hCard, _scardAttrVendorName);
        result['ifdType'] = _readAttribAsText(hCard, _scardAttrVendorIfdType);
        result['ifdVersion'] = _readAttribAsText(
          hCard,
          _scardAttrVendorIfdVersion,
        );
        result['serialNumber'] = _readAttribAsText(
          hCard,
          _scardAttrVendorIfdSerialNo,
        );
      } finally {
        win32.SCardDisconnect(hCard, _scardLeaveCard);
      }
    } finally {
      pkg_ffi.calloc.free(name);
      pkg_ffi.calloc.free(phCard);
      pkg_ffi.calloc.free(pdwProtocol);
    }
  } finally {
    if (context != 0) win32.SCardReleaseContext(context);
    pkg_ffi.calloc.free(phContext);
  }
  return result;
}

String _readAttribAsText(int hCard, int attrId) {
  final buf = pkg_ffi.calloc<ffi.Uint8>(256);
  final len = pkg_ffi.calloc<ffi.Uint32>()..value = 256;
  try {
    final rc = win32.SCardGetAttrib(hCard, attrId, buf, len);
    if (rc != 0) return '(unavailable: 0x${rc.toRadixString(16)})';
    final bytes = buf.asTypedList(len.value).where((b) => b != 0).toList();
    final asText = String.fromCharCodes(bytes);
    final isPrintable =
        asText.isNotEmpty && asText.runes.every((r) => r >= 0x20 && r < 0x7F);
    return isPrintable
        ? asText
        : bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');
  } finally {
    pkg_ffi.calloc.free(buf);
    pkg_ffi.calloc.free(len);
  }
}

const int _scardScopeSystem = 2;
// Exclusive, not shared: BAC/secure-messaging is a stateful, multi-APDU
// session (SSC-synchronized) — if Windows' own Smart Card service (or
// anything else) opens a shared connection and sends even one APDU of its
// own mid-session (it routinely probes newly-inserted cards for PIV/CAC
// certificates), the card's SM state gets corrupted from under us. That
// matches exactly what was seen: BAC succeeds, the very next command fails
// with a secure-messaging status word. Exclusive access for the lifetime of
// one PcscSession prevents any other process from interleaving commands.
const int _scardShareExclusive = 1;
const int _scardShareShared = 2;
const int _scardProtocolT0 = 0x01;
const int _scardProtocolT1 = 0x02;
const int _scardLeaveCard = 0;

/// Thin synchronous wrapper over the OS smartcard subsystem (WinSCard on
/// Windows, PCSC.framework on macOS) — the ID BOX's smartcard reader shows up
/// as a standard PC/SC CCID device (VID 0x2B78) on both, so no vendor driver
/// is needed for raw APDU exchange.
///
/// Not thread-safe; intended to be used from a single (often background)
/// isolate for the lifetime of one chip read.
class PcscSession {
  static bool get isSupported => Platform.isWindows || Platform.isMacOS;

  int _context = 0;
  int _card = 0;
  int _activeProtocol = 0;

  void establish() {
    if (Platform.isWindows) {
      final phContext = pkg_ffi.calloc<ffi.IntPtr>();
      try {
        final rc = win32.SCardEstablishContext(
          _scardScopeSystem,
          ffi.nullptr,
          ffi.nullptr,
          phContext,
        );
        if (rc != 0)
          throw PcscException(
            'SCardEstablishContext failed (0x${rc.toRadixString(16)})',
          );
        _context = phContext.value;
      } finally {
        pkg_ffi.calloc.free(phContext);
      }
    } else {
      _context = _MacPcsc.establishContext();
    }
  }

  List<String> listReaders() {
    if (Platform.isWindows) {
      final pcch = pkg_ffi.calloc<ffi.Uint32>()..value = 4096;
      final buf = pkg_ffi.calloc<ffi.Uint16>(4096);
      try {
        final rc = win32.SCardListReaders(
          _context,
          ffi.nullptr,
          buf.cast<pkg_ffi.Utf16>(),
          pcch,
        );
        if (rc != 0) return const [];
        final units = buf.asTypedList(pcch.value);
        return _splitMultiString(units);
      } finally {
        pkg_ffi.calloc.free(pcch);
        pkg_ffi.calloc.free(buf);
      }
    } else {
      return _MacPcsc.listReaders(_context);
    }
  }

  void connect(String readerName) {
    if (Platform.isWindows) {
      final name = readerName.toNativeUtf16();
      final phCard = pkg_ffi.calloc<ffi.IntPtr>();
      final pdwProtocol = pkg_ffi.calloc<ffi.Uint32>();
      try {
        final rc = win32.SCardConnect(
          _context,
          name,
          _scardShareExclusive,
          _scardProtocolT0 | _scardProtocolT1,
          phCard,
          pdwProtocol,
        );
        if (rc != 0) throw PcscException(_connectError(readerName, rc));
        _card = phCard.value;
        _activeProtocol = pdwProtocol.value;
      } finally {
        pkg_ffi.calloc.free(name);
        pkg_ffi.calloc.free(phCard);
        pkg_ffi.calloc.free(pdwProtocol);
      }
    } else {
      final result = _MacPcsc.connect(_context, readerName);
      _card = result.card;
      _activeProtocol = result.protocol;
    }
  }

  Uint8List transmit(Uint8List apdu) {
    if (Platform.isWindows) {
      final sendPci = pkg_ffi.calloc<win32.SCARD_IO_REQUEST>()
        ..ref.dwProtocol = _activeProtocol
        ..ref.cbPciLength = ffi.sizeOf<win32.SCARD_IO_REQUEST>();
      final sendBuf = pkg_ffi.calloc<ffi.Uint8>(apdu.length);
      final recvBuf = pkg_ffi.calloc<ffi.Uint8>(4096);
      final recvLen = pkg_ffi.calloc<ffi.Uint32>()..value = 4096;
      try {
        sendBuf.asTypedList(apdu.length).setAll(0, apdu);
        final rc = win32.SCardTransmit(
          _card,
          sendPci,
          sendBuf,
          apdu.length,
          ffi.nullptr,
          recvBuf,
          recvLen,
        );
        if (rc != 0)
          throw PcscException(
            'SCardTransmit failed (0x${rc.toRadixString(16)})',
          );
        return Uint8List.fromList(recvBuf.asTypedList(recvLen.value));
      } finally {
        pkg_ffi.calloc.free(sendPci);
        pkg_ffi.calloc.free(sendBuf);
        pkg_ffi.calloc.free(recvBuf);
        pkg_ffi.calloc.free(recvLen);
      }
    } else {
      return _MacPcsc.transmit(_card, _activeProtocol, apdu);
    }
  }

  void disconnect() {
    if (_card == 0) return;
    if (Platform.isWindows) {
      win32.SCardDisconnect(_card, _scardLeaveCard);
    } else {
      _MacPcsc.disconnect(_card);
    }
    _card = 0;
  }

  void release() {
    if (_context == 0) return;
    if (Platform.isWindows) {
      win32.SCardReleaseContext(_context);
    } else {
      _MacPcsc.releaseContext(_context);
    }
    _context = 0;
  }

  static List<String> _splitMultiString(List<int> units) {
    final readers = <String>[];
    final current = StringBuffer();
    for (final u in units) {
      if (u == 0) {
        if (current.isEmpty) break;
        readers.add(current.toString());
        current.clear();
      } else {
        current.writeCharCode(u);
      }
    }
    return readers;
  }
}

class _MacConnectResult {
  final int card;
  final int protocol;
  _MacConnectResult(this.card, this.protocol);
}

/// Raw FFI bindings to macOS's system PCSC.framework — the same WinSCard-
/// shaped API as Windows, just with `char*` reader names instead of `wchar*`
/// and pointer-width (not fixed 32-bit) context/card handles.
class _MacPcsc {
  static final ffi.DynamicLibrary _lib = ffi.DynamicLibrary.open(
    '/System/Library/Frameworks/PCSC.framework/PCSC',
  );

  static final int Function(
    int,
    ffi.Pointer,
    ffi.Pointer,
    ffi.Pointer<ffi.IntPtr>,
  )
  _establishContext = _lib
      .lookupFunction<
        ffi.Int32 Function(
          ffi.Uint32,
          ffi.Pointer,
          ffi.Pointer,
          ffi.Pointer<ffi.IntPtr>,
        ),
        int Function(int, ffi.Pointer, ffi.Pointer, ffi.Pointer<ffi.IntPtr>)
      >('SCardEstablishContext');

  static final int Function(int) _releaseContext = _lib
      .lookupFunction<ffi.Int32 Function(ffi.IntPtr), int Function(int)>(
        'SCardReleaseContext',
      );

  static final int Function(
    int,
    ffi.Pointer<pkg_ffi.Utf8>,
    ffi.Pointer<pkg_ffi.Utf8>,
    ffi.Pointer<ffi.Uint32>,
  )
  _listReaders = _lib
      .lookupFunction<
        ffi.Int32 Function(
          ffi.IntPtr,
          ffi.Pointer<pkg_ffi.Utf8>,
          ffi.Pointer<pkg_ffi.Utf8>,
          ffi.Pointer<ffi.Uint32>,
        ),
        int Function(
          int,
          ffi.Pointer<pkg_ffi.Utf8>,
          ffi.Pointer<pkg_ffi.Utf8>,
          ffi.Pointer<ffi.Uint32>,
        )
      >('SCardListReaders');

  static final int Function(
    int,
    ffi.Pointer<pkg_ffi.Utf8>,
    int,
    int,
    ffi.Pointer<ffi.IntPtr>,
    ffi.Pointer<ffi.Uint32>,
  )
  _connect = _lib
      .lookupFunction<
        ffi.Int32 Function(
          ffi.IntPtr,
          ffi.Pointer<pkg_ffi.Utf8>,
          ffi.Uint32,
          ffi.Uint32,
          ffi.Pointer<ffi.IntPtr>,
          ffi.Pointer<ffi.Uint32>,
        ),
        int Function(
          int,
          ffi.Pointer<pkg_ffi.Utf8>,
          int,
          int,
          ffi.Pointer<ffi.IntPtr>,
          ffi.Pointer<ffi.Uint32>,
        )
      >('SCardConnect');

  static final int Function(int, int) _disconnect = _lib
      .lookupFunction<
        ffi.Int32 Function(ffi.IntPtr, ffi.Uint32),
        int Function(int, int)
      >('SCardDisconnect');

  static final int Function(
    int,
    ffi.Pointer<_MacScardIoRequest>,
    ffi.Pointer<ffi.Uint8>,
    int,
    ffi.Pointer<_MacScardIoRequest>,
    ffi.Pointer<ffi.Uint8>,
    ffi.Pointer<ffi.Uint32>,
  )
  _transmit = _lib
      .lookupFunction<
        ffi.Int32 Function(
          ffi.IntPtr,
          ffi.Pointer<_MacScardIoRequest>,
          ffi.Pointer<ffi.Uint8>,
          ffi.Uint32,
          ffi.Pointer<_MacScardIoRequest>,
          ffi.Pointer<ffi.Uint8>,
          ffi.Pointer<ffi.Uint32>,
        ),
        int Function(
          int,
          ffi.Pointer<_MacScardIoRequest>,
          ffi.Pointer<ffi.Uint8>,
          int,
          ffi.Pointer<_MacScardIoRequest>,
          ffi.Pointer<ffi.Uint8>,
          ffi.Pointer<ffi.Uint32>,
        )
      >('SCardTransmit');

  static int establishContext() {
    final ctx = pkg_ffi.calloc<ffi.IntPtr>();
    try {
      final rc = _establishContext(
        _scardScopeSystem,
        ffi.nullptr,
        ffi.nullptr,
        ctx,
      );
      if (rc != 0) throw PcscException('SCardEstablishContext failed ($rc)');
      return ctx.value;
    } finally {
      pkg_ffi.calloc.free(ctx);
    }
  }

  static void releaseContext(int context) => _releaseContext(context);

  static List<String> listReaders(int context) {
    final pcch = pkg_ffi.calloc<ffi.Uint32>()..value = 4096;
    final buf = pkg_ffi.calloc<ffi.Uint8>(4096).cast<pkg_ffi.Utf8>();
    try {
      final rc = _listReaders(context, ffi.nullptr, buf, pcch);
      if (rc != 0) return const [];
      final bytes = buf.cast<ffi.Uint8>().asTypedList(pcch.value);
      return PcscSession._splitMultiString(bytes);
    } finally {
      pkg_ffi.calloc.free(pcch);
      pkg_ffi.calloc.free(buf);
    }
  }

  static _MacConnectResult connect(int context, String readerName) {
    final name = readerName.toNativeUtf8();
    final phCard = pkg_ffi.calloc<ffi.IntPtr>();
    final pdwProtocol = pkg_ffi.calloc<ffi.Uint32>();
    try {
      // Shared, not exclusive: macOS's own smart card service (ctkd) opens
      // a contact card as soon as it is inserted, and an exclusive connect
      // then hangs inside SCardConnect or reports "no card".
      final rc = _connect(
        context,
        name,
        _scardShareShared,
        _scardProtocolT0 | _scardProtocolT1,
        phCard,
        pdwProtocol,
      );
      if (rc != 0) throw PcscException(_connectError(readerName, rc));
      return _MacConnectResult(phCard.value, pdwProtocol.value);
    } finally {
      pkg_ffi.calloc.free(name);
      pkg_ffi.calloc.free(phCard);
      pkg_ffi.calloc.free(pdwProtocol);
    }
  }

  static void disconnect(int card) => _disconnect(card, _scardLeaveCard);

  static Uint8List transmit(int card, int activeProtocol, Uint8List apdu) {
    final sendPci = pkg_ffi.calloc<_MacScardIoRequest>()
      ..ref.dwProtocol = activeProtocol
      ..ref.cbPciLength = ffi.sizeOf<_MacScardIoRequest>();
    final sendBuf = pkg_ffi.calloc<ffi.Uint8>(apdu.length);
    final recvBuf = pkg_ffi.calloc<ffi.Uint8>(4096);
    final recvLen = pkg_ffi.calloc<ffi.Uint32>()..value = 4096;
    try {
      sendBuf.asTypedList(apdu.length).setAll(0, apdu);
      final rc = _transmit(
        card,
        sendPci,
        sendBuf,
        apdu.length,
        ffi.nullptr,
        recvBuf,
        recvLen,
      );
      if (rc != 0) throw PcscException('SCardTransmit failed ($rc)');
      return Uint8List.fromList(recvBuf.asTypedList(recvLen.value));
    } finally {
      pkg_ffi.calloc.free(sendPci);
      pkg_ffi.calloc.free(sendBuf);
      pkg_ffi.calloc.free(recvBuf);
      pkg_ffi.calloc.free(recvLen);
    }
  }
}

final class _MacScardIoRequest extends ffi.Struct {
  @ffi.Uint32()
  external int dwProtocol;
  @ffi.Uint32()
  external int cbPciLength;
}
