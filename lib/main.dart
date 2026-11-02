import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter/services.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import 'chip/card_reader.dart';
import 'chip/pcsc.dart';
import 'country_resolver.dart';
import 'i18n.dart';
import 'mrz/mrz_parser.dart';
import 'mrz/scan_dialog.dart';

void main() => runApp(const BiometricInfoApp());

class BiometricInfoApp extends StatelessWidget {
  const BiometricInfoApp({super.key});

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
      valueListenable: appLang,
      builder: (context, lang, _) => MaterialApp(
        title: 'Biometric Info',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorSchemeSeed: const Color(0xFF1565C0),
          fontFamily: 'Cairo',
          inputDecorationTheme: const InputDecorationTheme(border: OutlineInputBorder()),
        ),
        locale: Locale(lang),
        supportedLocales: const [Locale('fr'), Locale('en'), Locale('ar')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        home: const HomePage(),
      ));
}

String _two(int n) => n.toString().padLeft(2, '0');
String _iso(DateTime d) => '${d.year}-${_two(d.month)}-${_two(d.day)}';
String _fr(DateTime d) => '${_two(d.day)}/${_two(d.month)}/${d.year}';

/// Top-level so the isolate closure captures only these strings, not the
/// widget state (which cannot be sent to another isolate).
Future<CardData> _readInBackground(String docNo, String birth, String expiry) =>
    Isolate.run(() => readCardSync(documentNumber: docNo, birthDateIso: birth, expiryDateIso: expiry));

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _docNo = TextEditingController();
  // A douchette types into whatever has focus: keep it on the document field.
  final _docFocus = FocusNode();
  Timer? _scanPause;
  DateTime? _birth, _expiry;
  bool _busy = false;
  String? _error;
  CardData? _card;

  Future<void> _read() async {
    final docNo = _docNo.text.trim().toUpperCase();
    if (docNo.isEmpty || _birth == null || _expiry == null) {
      setState(() => _error = tr('Saisissez le numéro et choisissez les deux dates.'));
      return;
    }
    final birth = _iso(_birth!), expiry = _iso(_expiry!);
    setState(() {
      _busy = true;
      _error = null;
      _card = null;
    });
    try {
      // A hung macOS/Windows smart card service never returns: give up
      // instead of spinning forever (the stuck isolate dies with the app).
      final card = await _readInBackground(docNo, birth, expiry)
          .timeout(const Duration(seconds: 45));
      setState(() => _card = card);
    } on TimeoutException {
      setState(() => _error = tr('Le lecteur ne répond pas : retirez la carte, réinsérez-la et réessayez.'));
    } on PcscException catch (e) {
      setState(() => _error = tr(e.message));
    } catch (e) {
      setState(() => _error = '${tr('Lecture impossible : posez la carte sur le lecteur et réessayez.')}\n($e)');
    } finally {
      setState(() => _busy = false);
      _docFocus.requestFocus();
    }
  }

  /// Fills the three fields from a douchette scan, then reads the chip
  /// right away (card is usually already on the reader).
  Future<void> _scan() async {
    final mrz = await showMrzScanDialog(context);
    if (mrz != null && mounted) await _fill(mrz);
  }


  Future<void> _fill(MrzResult mrz) async {
    setState(() {
      _docNo.text = mrz.documentNumber;
      _birth = DateTime.tryParse(mrz.birthDate) ?? _birth;
      _expiry = DateTime.tryParse(mrz.expiryDate) ?? _expiry;
    });
    await _read();
  }

  Future<void> _print() async {
    final card = _card!;
    final font = pw.Font.ttf(await rootBundle.load('assets/fonts/Cairo-Regular.ttf'));
    final bold = pw.Font.ttf(await rootBundle.load('assets/fonts/Cairo-Bold.ttf'));
    await Printing.layoutPdf(
      name: 'Biometric Info - ${card.fields['Nom'] ?? ''}',
      format: PdfPageFormat.a4,
      onLayout: (format) async => (buildPdf(card, font, bold)).save(),
    );
  }

  /// A douchette typing straight into the field (popup not opened): each
  /// MRZ line ends with Enter and piles up here — parse it like the popup.
  void _onDocSubmitted() {
    _scanPause?.cancel();
    final text = _docNo.text.trim();
    if (text.length < 25) {
      _read();
      return;
    }
    final mrz = MrzParser.parse(text);
    if (mrz != null && mrz.isValid) {
      _fill(mrz);
    } else {
      _onDocChanged(text); // more MRZ lines may follow: decide after the pause
    }
  }

  /// Douchettes without an Enter suffix: parse once typing pauses.
  void _onDocChanged(String text) {
    _scanPause?.cancel();
    if (text.trim().length >= 25) _scanPause = Timer(const Duration(milliseconds: 400), _parseDocField);
  }

  void _parseDocField() {
    final mrz = MrzParser.parse(_docNo.text.trim());
    if (mrz == null || !mrz.isValid) {
      // Typing paused on something that isn't an MRZ, e.g. the douchette
      // caught the QR code: clear it so the next scan starts clean.
      setState(() {
        _docNo.clear();
        _error = tr("Ce code n'est pas une MRZ (code QR ?) : visez les lignes MRZ en bas du document.");
      });
      return;
    }
    _fill(mrz);
  }

  Widget _field(String label, TextEditingController c) => Padding(
        padding: const EdgeInsets.only(bottom: 20),
        child: TextField(
          controller: c,
          focusNode: _docFocus,
          autofocus: true,
          onEditingComplete: () {}, // Enter after each MRZ line must not drop focus
          style: const TextStyle(fontSize: 20),
          textCapitalization: TextCapitalization.characters,
          onSubmitted: (_) => _onDocSubmitted(),
          onChanged: _onDocChanged,
          decoration: InputDecoration(labelText: tr(label), labelStyle: const TextStyle(fontSize: 17)),
        ),
      );

  Widget _dateField(String label, DateTime? value, DateTime first, DateTime last, DateTime initial,
          ValueChanged<DateTime> onPicked) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 20),
        child: InkWell(
          canRequestFocus: false, // else the douchette's Enter opens the picker
          onTap: () async {
            final d = await showDatePicker(
              context: context,
              firstDate: first,
              lastDate: last,
              initialDate: value ?? initial,
              initialDatePickerMode: DatePickerMode.year,
            );
            if (d != null) setState(() => onPicked(d));
            _docFocus.requestFocus();
          },
          child: InputDecorator(
            decoration: InputDecoration(
              labelText: tr(label),
              labelStyle: const TextStyle(fontSize: 17),
              suffixIcon: const Icon(Icons.calendar_month, size: 28),
            ),
            child: Text(value == null ? tr('Choisir…') : _fr(value),
                style: TextStyle(fontSize: 20, color: value == null ? Colors.black45 : null)),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    Localizations.localeOf(context); // rebuild on FR/EN/AR switch (tr() reads appLang)
    final form = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(tr('Données d\'accès à la puce'), style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        Text(tr('Scannez la MRZ ou recopiez-les depuis la carte, puis posez la carte sur le lecteur.'),
            style: const TextStyle(fontSize: 16)),
        const SizedBox(height: 24),
        _BubbleButton(
          onPressed: _busy ? null : _scan,
          icon: const Icon(Icons.document_scanner, size: 28, color: Colors.white),
          label: tr('Scanner la carte'),
        ),
        const SizedBox(height: 24),
        _field('N° de document', _docNo),
        _dateField('Date de naissance', _birth, DateTime(1900), DateTime.now(), DateTime(1990),
            (d) => _birth = d),
        _dateField('Date d\'expiration', _expiry, DateTime(2000), DateTime(DateTime.now().year + 20),
            DateTime.now(), (d) => _expiry = d),
        _BubbleButton(
          onPressed: _busy ? null : _read,
          icon: _busy
              ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 3, color: Colors.white))
              : const Icon(Icons.contactless, size: 28, color: Colors.white),
          label: tr(_busy ? 'Lecture en cours…' : 'Lire la carte'),
        ),
        const SizedBox(height: 12),
        _BubbleButton(
          color: const Color(0xFF2E7D32),
          onPressed: _card == null ? null : _print,
          icon: const Icon(Icons.print, size: 28, color: Colors.white),
          label: tr('Imprimer'),
        ),
        if (_error != null) ...[
          const SizedBox(height: 20),
          Text(_error!, style: const TextStyle(fontSize: 17, color: Color(0xFFC62828))),
        ],
      ],
    );

    final result = Card(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: _card == null
            ? Center(
                child: Text(tr('Aucune carte lue'), style: const TextStyle(fontSize: 20, color: Colors.black45)))
            : SingleChildScrollView(child: _CardView(_card!)),
      ),
    );

    return Scaffold(
      appBar: AppBar(
        title: const Text('Biometric Info', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
        backgroundColor: const Color(0xFF1565C0),
        foregroundColor: Colors.white,
        actions: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: SegmentedButton<String>(
              showSelectedIcon: false,
              style: SegmentedButton.styleFrom(
                foregroundColor: Colors.white,
                selectedForegroundColor: const Color(0xFF1565C0),
                selectedBackgroundColor: Colors.white,
                side: const BorderSide(color: Colors.white70),
                textStyle: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                minimumSize: const Size(72, 48),
              ),
              segments: const [
                ButtonSegment(value: 'fr', label: Text('FR')),
                ButtonSegment(value: 'en', label: Text('EN')),
                ButtonSegment(value: 'ar', label: Text('عربي')),
              ],
              selected: {appLang.value},
              onSelectionChanged: (v) => appLang.value = v.first,
            ),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: LayoutBuilder(
          builder: (context, c) => c.maxWidth > 900
              ? Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  SizedBox(width: 400, child: SingleChildScrollView(child: form)),
                  const SizedBox(width: 24),
                  Expanded(child: result),
                ])
              : ListView(children: [form, const SizedBox(height: 24), SizedBox(height: 600, child: result)]),
        ),
      ),
    );
  }
}

class _CardView extends StatelessWidget {
  final CardData card;
  const _CardView(this.card);

  @override
  Widget build(BuildContext context) {
    final pictures = {
      if (card.photoJpeg != null) 'Photo': card.photoJpeg!,
      ...card.images,
    };
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 200,
          child: Column(children: [
            if (pictures.isEmpty)
              Container(
                height: 260,
                decoration: BoxDecoration(border: Border.all(color: Colors.black26)),
                child: const Center(child: Icon(Icons.person, size: 100, color: Colors.black26)),
              ),
            for (final p in pictures.entries)
              Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: InkWell(
                  onTap: () => _showFullScreen(context, p.key, p.value, card.fields['Nom'] ?? 'carte'),
                  child: Column(children: [
                    Container(
                      height: p.key == 'Photo' ? 260 : 120,
                      width: 200,
                      decoration: BoxDecoration(border: Border.all(color: Colors.black26)),
                      child: Image.memory(p.value, fit: BoxFit.contain),
                    ),
                    const SizedBox(height: 4),
                    Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                      const Icon(Icons.zoom_out_map, size: 20, color: Colors.black54),
                      const SizedBox(width: 6),
                      Text(tr(p.key), style: const TextStyle(fontSize: 15, color: Colors.black54)),
                    ]),
                  ]),
                ),
              ),
          ]),
        ),
        const SizedBox(width: 24),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final e in card.fields.entries)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(tr(e.key), style: const TextStyle(fontSize: 14, color: Colors.black54)),
                    if (_countryKeys.contains(e.key))
                      _CountryValue(e.value)
                    else
                      SelectableText(tr(e.value),
                          textDirection: _arabic.hasMatch(e.value) ? TextDirection.rtl : TextDirection.ltr,
                          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
                  ]),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Saves into the user's Downloads folder — no file dialog, one click.
Future<String> _saveToDownloads(Uint8List bytes, String name) async {
  final home = Platform.environment[Platform.isWindows ? 'USERPROFILE' : 'HOME']!;
  final sep = Platform.pathSeparator;
  final now = DateTime.now();
  final stamp = '${now.year}${_two(now.month)}${_two(now.day)}_${_two(now.hour)}${_two(now.minute)}${_two(now.second)}';
  final safe = name.replaceAll(RegExp(r'[^A-Za-z0-9]+'), '_');
  final file = File('$home${sep}Downloads$sep${safe}_$stamp.jpg');
  await file.writeAsBytes(bytes);
  return file.path;
}

void _reveal(String path) =>
    Platform.isWindows ? Process.run('explorer', ['/select,', path]) : Process.run('open', ['-R', path]);

void _showFullScreen(BuildContext context, String label, Uint8List bytes, String owner) {
  showDialog<void>(
    context: context,
    builder: (ctx) => Dialog.fullscreen(
      backgroundColor: Colors.black,
      child: Column(children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Row(children: [
            Text(tr(label), style: const TextStyle(fontSize: 24, color: Colors.white, fontWeight: FontWeight.bold)),
            const Spacer(),
            _BubbleButton(
                color: const Color(0xFF2E7D32),
                icon: const Icon(Icons.download, size: 28, color: Colors.white),
                label: tr('Télécharger'),
                onPressed: () async {
                  final messenger = ScaffoldMessenger.of(context);
                  try {
                    final path = await _saveToDownloads(bytes, '${owner}_$label');
                    messenger.showSnackBar(SnackBar(
                      content: Text('${tr('Enregistré :')} $path', style: const TextStyle(fontSize: 16)),
                      action: SnackBarAction(label: tr('Afficher'), onPressed: () => _reveal(path)),
                    ));
                  } on FileSystemException catch (e) {
                    messenger.showSnackBar(SnackBar(content: Text('${tr('Échec de l\'enregistrement :')} ${e.message}')));
                  }
                },
            ),
            const SizedBox(width: 12),
            _BubbleButton(
              icon: const Icon(Icons.close, size: 28, color: Colors.white),
              label: tr('Fermer'),
              onPressed: () => Navigator.pop(ctx),
            ),
          ]),
        ),
        Expanded(
          child: InteractiveViewer(
            maxScale: 8,
            child: Center(child: Image.memory(bytes, fit: BoxFit.contain)),
          ),
        ),
      ]),
    ),
  );
}

const _countryKeys = {'Pays émetteur', 'Nationalité'};

/// "Algeria" — same ISO-3 → name logic as the visitor app.
String _countryLabel(String iso3) => CountryResolver.resolve(iso3);

/// Same look as the visitor app dashboard tiles: zoom + glow on hover/press, white bubbles.
class _BubbleButton extends StatefulWidget {
  const _BubbleButton({required this.icon, required this.label, required this.onPressed, this.color});
  final Widget icon;
  final String label;
  final VoidCallback? onPressed;
  final Color? color;

  @override
  State<_BubbleButton> createState() => _BubbleButtonState();
}

class _BubbleButtonState extends State<_BubbleButton> {
  bool _active = false;

  Widget _bubble(double size) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(color: Colors.white.withAlpha(26), shape: BoxShape.circle),
      );

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onPressed != null;
    final active = enabled && _active;
    final bg = enabled ? (widget.color ?? Theme.of(context).colorScheme.primary) : Colors.grey.shade400;
    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : MouseCursor.defer,
      onEnter: (_) => setState(() => _active = true),
      onExit: (_) => setState(() => _active = false),
      child: GestureDetector(
        onTap: widget.onPressed,
        onTapDown: (_) => setState(() => _active = true),
        onTapCancel: () => setState(() => _active = false),
        onTapUp: (_) => setState(() => _active = false),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          height: 60,
          transform: Matrix4.diagonal3Values(active ? 1.04 : 1.0, active ? 1.04 : 1.0, 1),
          transformAlignment: Alignment.center,
          clipBehavior: Clip.hardEdge,
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(16),
            boxShadow: [
              if (enabled)
                BoxShadow(color: bg.withAlpha(active ? 160 : 77), blurRadius: active ? 28 : 12, offset: const Offset(0, 6)),
            ],
          ),
          child: Stack(children: [
            Positioned(top: -30, right: -20, child: _bubble(80)),
            Positioned(bottom: -40, left: -20, child: _bubble(70)),
            Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  AnimatedScale(scale: active ? 1.14 : 1.0, duration: const Duration(milliseconds: 200), child: widget.icon),
                  const SizedBox(width: 10),
                  Text(widget.label,
                      style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white)),
                ]),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

class _CountryValue extends StatelessWidget {
  final String iso3;
  const _CountryValue(this.iso3);

  @override
  Widget build(BuildContext context) {
    final flag = CountryResolver.flagAsset(iso3);
    return Row(children: [
      if (flag != null) ...[
        ClipRRect(
          borderRadius: BorderRadius.circular(3),
          child: Image.asset(flag, width: 36, height: 27, fit: BoxFit.cover,
              errorBuilder: (_, _, _) => const SizedBox.shrink()),
        ),
        const SizedBox(width: 10),
      ],
      Flexible(
        child: SelectableText(_countryLabel(iso3), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
      ),
    ]);
  }
}

final _arabic = RegExp(r'[؀-ۿ]');

pw.Document buildPdf(CardData card, pw.Font font, pw.Font bold) {
  final doc = pw.Document(theme: pw.ThemeData.withFont(base: font, bold: bold));
  final now = DateTime.now();
  final stamp = '${_fr(now)} ${_two(now.hour)}:${_two(now.minute)}';
  final rtl = appLang.value == 'ar';

  // MultiPage: the table flows onto a second page instead of being dropped
  // when it does not fit (what a single pw.Page silently does).
  doc.addPage(pw.MultiPage(
    pageFormat: PdfPageFormat.a4,
    margin: const pw.EdgeInsets.all(40),
    textDirection: rtl ? pw.TextDirection.rtl : pw.TextDirection.ltr,
    build: (_) => [
      pw.Text(tr('Informations biométriques'), style: pw.TextStyle(font: bold, fontSize: 22, color: PdfColors.blue800)),
      pw.Text('${tr('Lues depuis la puce du document le')} $stamp',
          style: const pw.TextStyle(fontSize: 11, color: PdfColors.grey700)),
      pw.Divider(color: PdfColors.blue800, thickness: 1.5),
      pw.SizedBox(height: 12),
      if (card.photoJpeg == null)
        pw.Container(
          width: 150,
          height: 195,
          decoration: pw.BoxDecoration(border: pw.Border.all(color: PdfColors.grey500)),
          child: pw.Center(child: pw.Text(tr('Photo indisponible'), style: const pw.TextStyle(fontSize: 10))),
        )
      else
        pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
          pw.Container(
            width: 150,
            height: 195,
            decoration: pw.BoxDecoration(border: pw.Border.all(color: PdfColors.grey500)),
            child: pw.Image(pw.MemoryImage(card.photoJpeg!), fit: pw.BoxFit.contain),
          ),
          pw.Text(tr('Photo'), style: const pw.TextStyle(fontSize: 10, color: PdfColors.grey700)),
        ]),
      pw.SizedBox(height: 16),
      // Rows instead of pw.Table: Table ignores RTL, which clipped the Arabic labels.
      for (final e in card.fields.entries)
        pw.Container(
          padding: const pw.EdgeInsets.symmetric(vertical: 5),
          decoration: const pw.BoxDecoration(
              border: pw.Border(bottom: pw.BorderSide(color: PdfColors.grey300))),
          child: pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
            pw.Expanded(
              flex: 2,
              child: pw.Text(tr(e.key), style: const pw.TextStyle(fontSize: 11, color: PdfColors.grey700)),
            ),
            pw.SizedBox(width: 8),
            pw.Expanded(
              flex: 3,
              child: pw.Builder(builder: (_) {
                final v = _countryKeys.contains(e.key) ? _countryLabel(e.value) : tr(e.value);
                return pw.Text(v,
                    style: pw.TextStyle(font: bold, fontSize: 12),
                    textAlign: rtl ? pw.TextAlign.right : pw.TextAlign.left,
                    textDirection: _arabic.hasMatch(v) ? pw.TextDirection.rtl : pw.TextDirection.ltr);
              }),
            ),
          ]),
        ),
      // Signature (and any other image) as the last table rows.
      for (final img in card.images.entries)
        pw.Container(
          padding: const pw.EdgeInsets.symmetric(vertical: 5),
          decoration: const pw.BoxDecoration(
              border: pw.Border(bottom: pw.BorderSide(color: PdfColors.grey300))),
          child: pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
            pw.Expanded(
              flex: 2,
              child: pw.Text(tr(img.key), style: const pw.TextStyle(fontSize: 11, color: PdfColors.grey700)),
            ),
            pw.SizedBox(width: 8),
            pw.Expanded(
              flex: 3,
              child: pw.Align(
                alignment: rtl ? pw.Alignment.centerRight : pw.Alignment.centerLeft,
                child: pw.Container(
                  width: 200,
                  height: 100,
                  decoration: pw.BoxDecoration(border: pw.Border.all(color: PdfColors.grey500)),
                  child: pw.Image(pw.MemoryImage(img.value), fit: pw.BoxFit.contain),
                ),
              ),
            ),
          ]),
        ),
    ],
  ));
  return doc;
}
