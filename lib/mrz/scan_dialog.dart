import 'dart:async';

import 'package:flutter/material.dart';

import '../i18n.dart';
import 'mrz_parser.dart';

/// Waits for one MRZ from a douchette (keyboard wedge typing into a hidden
/// field) and pops with the [MrzResult].
/// Copied from the visitor app's _DocumentScanDialog.
Future<MrzResult?> showMrzScanDialog(BuildContext context) =>
    showDialog<MrzResult>(context: context, builder: (_) => const _MrzScanDialog());

class _MrzScanDialog extends StatefulWidget {
  const _MrzScanDialog();
  @override
  State<_MrzScanDialog> createState() => _MrzScanDialogState();
}

class _MrzScanDialogState extends State<_MrzScanDialog> {
  final _node = FocusNode();
  final _ctrl = TextEditingController();
  String _acc = '';
  String _raw = ''; // shown when a scan doesn't parse, to see what the douchette sent
  Timer? _accTimer;
  bool _done = false;

  @override
  void initState() {
    super.initState();
    // A douchette types into whatever has focus: keep it on the hidden field.
    _node.addListener(() {
      if (!_node.hasFocus && mounted && !_done) {
        Future.delayed(const Duration(milliseconds: 100), () {
          if (mounted && !_node.hasFocus) _node.requestFocus();
        });
      }
    });
  }

  void _submit(MrzResult mrz) {
    if (_done || !mounted) return;
    _done = true;
    Navigator.of(context).pop(mrz);
  }

  /// Each MRZ line arrives as its own "Enter": accumulate until it parses.
  void _onLine(String line) {
    if (_done || line.isEmpty) return;
    _accTimer?.cancel();
    _accTimer = Timer(const Duration(seconds: 2), () => _acc = '');
    _acc = (_acc.isNotEmpty && line.contains(_acc)) ? line : _acc + line;
    final mrz = MrzParser.parse(_acc);
    if (mrz != null && mrz.isValid) {
      _accTimer?.cancel();
      _submit(mrz);
      return;
    }
    setState(() => _raw = _acc);
    if (_acc.length >= 90) _acc = ''; // garbage: don't block the next scan
    _ctrl.clear();
    _node.requestFocus();
  }

  @override
  void dispose() {
    _accTimer?.cancel();
    _node.dispose();
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        child: TapRegion(
          onTapOutside: (_) => _node.requestFocus(),
          child: Container(
            width: 460,
            padding: const EdgeInsets.all(32),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Opacity(
                opacity: 0,
                child: SizedBox(
                  width: 1,
                  height: 1,
                  child: TextField(
                    focusNode: _node,
                    controller: _ctrl,
                    autofocus: true,
                    textInputAction: TextInputAction.none,
                    onSubmitted: (v) => _onLine(v.trim()),
                  ),
                ),
              ),
              const Icon(Icons.document_scanner, size: 80, color: Color(0xFF1565C0)),
              const SizedBox(height: 24),
              Text(tr('En attente du scan…'), style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
              const SizedBox(height: 12),
              Text(tr('Passez la zone MRZ du document sous la douchette.'),
                  textAlign: TextAlign.center, style: const TextStyle(fontSize: 17)),
              const SizedBox(height: 24),
              const SizedBox(width: 160, child: LinearProgressIndicator(minHeight: 3)),
              if (_raw.isNotEmpty) ...[
                const SizedBox(height: 16),
                SelectableText(_raw, textAlign: TextAlign.center, style: const TextStyle(fontSize: 14, color: Colors.black54)),
              ],
              const SizedBox(height: 28),
              SizedBox(
                height: 60,
                width: double.infinity,
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(
                      backgroundColor: Colors.grey.shade600,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))),
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close, size: 26),
                  label: Text(tr('Annuler'), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                ),
              ),
            ]),
          ),
        ),
      );
}
