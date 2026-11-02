import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';

import 'chip/card_reader.dart';
import 'chip/pcsc.dart';
import 'i18n.dart';

/// Black & white looping illustration: a douchette reading the MRZ
/// ([chip] false) or the card laid on the contactless reader ([chip] true).
class TutorialAnimation extends StatefulWidget {
  const TutorialAnimation({super.key, required this.chip});
  final bool chip;
  @override
  State<TutorialAnimation> createState() => _TutorialAnimationState();
}

class _TutorialAnimationState extends State<TutorialAnimation> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 2600))..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 360,
    height: 220,
    child: ClipRect(
      child: AnimatedBuilder(
        animation: _c,
        builder: (_, _) => CustomPaint(painter: widget.chip ? _ChipPainter(_c.value) : _ScanPainter(_c.value)),
      ),
    ),
  );
}

final _ink = Paint()
  ..color = Colors.black
  ..style = PaintingStyle.stroke
  ..strokeWidth = 3
  ..strokeJoin = StrokeJoin.round;
final _white = Paint()..color = Colors.white;
final _black = Paint()..color = Colors.black;
final _grey = Paint()..color = const Color(0xFFBDBDBD);

/// ID card seen from above, MRZ band at the bottom; [mrzLit] = MRZ rows
/// already read (drawn black instead of grey).
void _card(Canvas c, Rect r, {double mrzLit = 0}) {
  final rr = RRect.fromRectAndRadius(r, const Radius.circular(12));
  c.drawRRect(rr, _white);
  c.drawRRect(rr, _ink);
  final u = r.width / 20;
  c.drawRRect(RRect.fromLTRBR(r.left + u, r.top + u, r.left + 5 * u, r.top + 6.5 * u, const Radius.circular(4)), _grey);
  c.drawCircle(Offset(r.left + 3 * u, r.top + 3 * u), u * .9, _white);
  for (var i = 0; i < 3; i++) {
    c.drawRRect(
      RRect.fromLTRBR(
        r.left + 6 * u,
        r.top + (1.4 + i * 1.6) * u,
        r.right - (i == 1 ? 6 : 2) * u,
        r.top + (2.2 + i * 1.6) * u,
        const Radius.circular(3),
      ),
      _grey,
    );
  }
  // MRZ: three rows of "<<<" blocks.
  for (var row = 0; row < 3; row++) {
    final y = r.bottom - (3.4 - row * 1.05) * u;
    final p = row < mrzLit ? _black : _grey;
    for (var x = r.left + u; x < r.right - u * 1.2; x += u * .62) {
      c.drawRect(Rect.fromLTWH(x, y, u * .42, u * .62), p);
    }
  }
}

class _ScanPainter extends CustomPainter {
  _ScanPainter(this.t);
  final double t;

  @override
  void paint(Canvas c, Size s) {
    final card = Rect.fromLTWH(s.width * .18, s.height * .38, s.width * .64, s.height * .58);
    final u = card.width / 20;
    // Beam sweeps down then up over the three MRZ rows.
    final sweep = t < .5 ? t * 2 : 2 - t * 2;
    final top = card.bottom - 3.6 * u, bottom = card.bottom - .6 * u;
    final beamY = top + (bottom - top) * sweep;
    _card(c, card, mrzLit: sweep * 3.2);

    // Douchette above the card, pointing down, slight bob.
    final head = Offset(s.width / 2, 34 + sin(t * 2 * pi) * 3);
    final beam = Path()
      ..moveTo(head.dx - 10, head.dy + 34)
      ..lineTo(card.left + u * .6, beamY)
      ..lineTo(card.right - u * .6, beamY)
      ..lineTo(head.dx + 10, head.dy + 34)
      ..close();
    c.drawPath(beam, Paint()..color = Colors.black.withAlpha(28));
    c.drawLine(
      Offset(card.left + u * .6, beamY),
      Offset(card.right - u * .6, beamY),
      Paint()
        ..color = Colors.black
        ..strokeWidth = 3,
    );
    final gun = RRect.fromLTRBR(head.dx - 34, head.dy - 6, head.dx + 34, head.dy + 34, const Radius.circular(10));
    c.drawRRect(gun, _white);
    c.drawRRect(gun, _ink);
    final handle = Path()
      ..moveTo(head.dx + 20, head.dy + 2)
      ..lineTo(head.dx + 78, head.dy - 22)
      ..lineTo(head.dx + 86, head.dy - 6)
      ..lineTo(head.dx + 30, head.dy + 20);
    c.drawPath(handle, _white);
    c.drawPath(handle, _ink);
    c.drawRect(Rect.fromLTWH(head.dx - 16, head.dy + 26, 32, 6), _black);
  }

  @override
  bool shouldRepaint(_ScanPainter old) => old.t != t;
}

class _ChipPainter extends CustomPainter {
  _ChipPainter(this.t);
  final double t;

  @override
  void paint(Canvas c, Size s) {
    // Reader seen from above, contactless logo in the middle.
    final reader = Rect.fromCenter(center: Offset(s.width / 2, s.height * .6), width: 150, height: 150);
    final rr = RRect.fromRectAndRadius(reader, const Radius.circular(16));
    c.drawRRect(rr, _black);
    final pad = reader.deflate(14);
    c.drawRRect(
      RRect.fromRectAndRadius(pad, const Radius.circular(10)),
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3,
    );
    final logo = pad.center;
    for (var i = 1; i <= 3; i++) {
      c.drawArc(
        Rect.fromCircle(center: logo.translate(-18, 0), radius: i * 11.0),
        -pi / 4,
        pi / 2,
        false,
        Paint()
          ..color = Colors.white
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3,
      );
    }

    // Card: slides down onto the pad (0–.45), rests (–.85), fades (–1).
    final drop = Curves.easeOutCubic.transform((t / .45).clamp(0, 1));
    final cardW = 170.0, cardH = 108.0;
    final rest = Offset(s.width / 2 - cardW / 2, reader.center.dy - cardH / 2);
    final from = rest.translate(70, -150);
    final pos = Offset.lerp(from, rest, drop)!;
    final alpha = t > .85 ? 1 - (t - .85) / .15 : 1.0;
    c.saveLayer(Offset.zero & s, Paint()..color = Colors.white.withValues(alpha: alpha));
    _card(c, pos & Size(cardW, cardH));
    c.restore();

    // Waves around the card once it is down.
    if (t > .45 && t < .85) {
      final k = ((t - .45) / .4 * 2) % 1;
      for (final side in [-1, 1]) {
        c.drawArc(
          Rect.fromCircle(center: reader.center, radius: cardW / 2 + 10 + k * 26),
          side < 0 ? pi - .5 : -.5,
          1,
          false,
          Paint()
            ..color = Colors.black.withValues(alpha: 1 - k)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 3,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_ChipPainter old) => old.t != t;
}

/// "Lay the card on the reader" popup: keeps trying [read] until the chip
/// answers, then pops with the [CardData]; null when cancelled.
Future<CardData?> showChipReadDialog(BuildContext context, Future<CardData> Function() read) =>
    showDialog<CardData>(context: context, barrierDismissible: false, builder: (_) => _ChipReadDialog(read));

class _ChipReadDialog extends StatefulWidget {
  const _ChipReadDialog(this.read);
  final Future<CardData> Function() read;
  @override
  State<_ChipReadDialog> createState() => _ChipReadDialogState();
}

class _ChipReadDialogState extends State<_ChipReadDialog> {
  String? _msg;
  bool _done = false;

  @override
  void initState() {
    super.initState();
    _loop();
  }

  // ponytail: one attempt every 1.5 s; a read stuck in the OS smart card
  // service is abandoned after 45 s (by the caller's timeout) and retried.
  Future<void> _loop() async {
    while (mounted) {
      String? msg;
      try {
        final card = await widget.read();
        if (!mounted) return;
        setState(() => _done = true); // success animation, then close by itself
        await Future.delayed(const Duration(milliseconds: 1600));
        if (mounted) Navigator.of(context).pop(card);
        return;
      } on TimeoutException {
        msg = 'Le lecteur ne répond pas : retirez la carte, réinsérez-la et réessayez.';
      } on PcscException catch (e) {
        // No card yet is the normal waiting state, not an error.
        msg = e.message.startsWith('Aucune carte') ? null : e.message;
      } catch (e) {
        msg = 'Lecture impossible : posez la carte sur le lecteur et réessayez.';
      }
      if (!mounted) return;
      setState(() => _msg = msg);
      await Future.delayed(const Duration(milliseconds: 1500));
    }
  }

  @override
  Widget build(BuildContext context) => Dialog(
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
    child: Container(
      width: 460,
      padding: const EdgeInsets.all(32),
      child: _done
          ? Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(width: 360, height: 220, child: Center(child: _SuccessCheck())),
                const SizedBox(height: 20),
                Text(tr('Lecture réussie'), style: const TextStyle(fontSize: 26, fontWeight: FontWeight.bold)),
                const SizedBox(height: 40),
              ],
            )
          : Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const TutorialAnimation(chip: true),
                const SizedBox(height: 20),
                Text(
                  tr('Posez la carte sur le lecteur'),
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 12),
                Text(
                  tr('À plat, sur le dessus du lecteur sans contact : la lecture démarre toute seule.'),
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 17),
                ),
                const SizedBox(height: 20),
                const SizedBox(width: 160, child: LinearProgressIndicator(minHeight: 3)),
                if (_msg != null) ...[
                  const SizedBox(height: 16),
                  Text(
                    tr(_msg!),
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 16, color: Color(0xFFC62828)),
                  ),
                ],
                const SizedBox(height: 28),
                SizedBox(
                  height: 60,
                  width: double.infinity,
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: Colors.grey.shade600,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                    ),
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close, size: 26),
                    label: Text(tr('Annuler'), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  ),
                ),
              ],
            ),
    ),
  );
}

/// Green circle that pops in, then a tick drawn stroke by stroke.
class _SuccessCheck extends StatelessWidget {
  const _SuccessCheck();
  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
    tween: Tween(begin: 0, end: 1),
    duration: const Duration(milliseconds: 900),
    builder: (_, t, _) => Transform.scale(
      scale: Curves.elasticOut.transform((t / .6).clamp(0, 1)) * .4 + .6,
      child: CustomPaint(size: const Size(150, 150), painter: _CheckPainter(t)),
    ),
  );
}

class _CheckPainter extends CustomPainter {
  _CheckPainter(this.t);
  final double t;

  @override
  void paint(Canvas c, Size s) {
    final center = s.center(Offset.zero);
    c.drawCircle(
      center,
      s.width / 2 * Curves.easeOut.transform((t / .5).clamp(0, 1)),
      Paint()..color = const Color(0xFF2E7D32),
    );
    final k = ((t - .4) / .6).clamp(0.0, 1.0);
    if (k == 0) return;
    final a = Offset(s.width * .28, s.height * .52),
        b = Offset(s.width * .44, s.height * .68),
        e = Offset(s.width * .74, s.height * .36);
    final path = Path()..moveTo(a.dx, a.dy);
    final p1 = (k / .4).clamp(0.0, 1.0);
    path.lineTo(a.dx + (b.dx - a.dx) * p1, a.dy + (b.dy - a.dy) * p1);
    if (k > .4) {
      final p2 = (k - .4) / .6;
      path.lineTo(b.dx + (e.dx - b.dx) * p2, b.dy + (e.dy - b.dy) * p2);
    }
    c.drawPath(
      path,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 12
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(_CheckPainter old) => old.t != t;
}
