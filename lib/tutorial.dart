import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'chip/card_reader.dart';
import 'chip/pcsc.dart';
import 'i18n.dart';

/// Tutorial illustration (layers drawn with Stitch, animated here): the
/// douchette sweeping its laser over the MRZ ([chip] false), or the card
/// laid onto the contactless reader, LED and waves lighting up.
class TutorialAnimation extends StatefulWidget {
  const TutorialAnimation({super.key, required this.chip});
  final bool chip;
  @override
  State<TutorialAnimation> createState() => _TutorialAnimationState();
}

class _TutorialAnimationState extends State<TutorialAnimation> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(
    vsync: this,
    duration: Duration(milliseconds: widget.chip ? 3200 : 2400),
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 360,
    height: 260,
    child: ClipRect(
      child: AnimatedBuilder(animation: _c, builder: (_, _) => widget.chip ? _chip(_c.value) : _scan(_c.value)),
    ),
  );

  static Widget _img(String n, double w) => Image.asset('assets/tutorial/$n.png', width: w);

  // Card centred under the laser; MRZ band = 70–90 % of its height.
  static const _card = Rect.fromLTWH(60, 92, 240, 157);

  Widget _scan(double t) {
    final sweep = Curves.easeInOut.transform(t < .5 ? t * 2 : 2 - t * 2);
    final mrzTop = _card.top + _card.height * .70, mrzBottom = _card.top + _card.height * .90;
    final y = mrzTop + (mrzBottom - mrzTop) * sweep;
    return Stack(
      children: [
        Positioned.fromRect(rect: _card, child: _img('card', _card.width)),
        Positioned.fill(
          child: CustomPaint(painter: _LaserPainter(const Offset(180, 8), _card.left + 10, _card.right - 10, y)),
        ),
      ],
    );
  }

  Widget _chip(double t) {
    const reader = Rect.fromLTWH(121, 10, 118, 231);
    final drop = Curves.easeInOutCubic.transform((t / .35).clamp(0, 1));
    final reading = t > .38 && t < .9;
    final fade = t > .9 ? 1 - (t - .9) / .1 : 1.0;
    const rest = Offset(80, 100);
    final pos = Offset.lerp(const Offset(80, -110), rest, drop)!;
    final lift = 1 - drop; // 1 = in the air
    return Stack(
      children: [
        Positioned.fromRect(rect: reader, child: _img('reader', reader.width)),
        // LED: grey until the card is down, then glowing green.
        Positioned(
          left: reader.left + reader.width * .498 - 7,
          top: reader.top + reader.height * .278 - 7,
          child: Container(
            width: 14,
            height: 14,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: reading ? const Color(0xFF4CAF50) : const Color(0xFF5F6368),
              boxShadow: [if (reading) const BoxShadow(color: Color(0xFF69F0AE), blurRadius: 14, spreadRadius: 3)],
            ),
          ),
        ),
        Opacity(
          opacity: fade,
          child: Stack(
            children: [
              // Shadow on the reader, further away while the card is lifted.
              Positioned(
                left: pos.dx + 6 + lift * 10,
                top: pos.dy + 8 + lift * 30,
                child: Container(
                  width: 200,
                  height: 131,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(14),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: .3 - lift * .22),
                        blurRadius: 10 + lift * 24,
                      ),
                    ],
                  ),
                ),
              ),
              Positioned(
                left: pos.dx,
                top: pos.dy,
                child: Transform.scale(scale: 1 + lift * .12, child: _img('card', 200)),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Red laser fan from [from] down to a line across the MRZ at [y].
class _LaserPainter extends CustomPainter {
  _LaserPainter(this.from, this.left, this.right, this.y);
  final Offset from;
  final double left, right, y;

  @override
  void paint(Canvas c, Size s) {
    final fan = Path()
      ..moveTo(from.dx, from.dy)
      ..lineTo(left, y)
      ..lineTo(right, y)
      ..close();
    c.drawPath(
      fan,
      Paint()
        ..shader = ui.Gradient.linear(from, Offset(from.dx, y), [const Color(0x00FF1744), const Color(0x44FF1744)]),
    );
    c.drawLine(
      Offset(left, y),
      Offset(right, y),
      Paint()
        ..color = const Color(0xFFFF1744)
        ..strokeWidth = 2.5
        ..maskFilter = const MaskFilter.blur(BlurStyle.solid, 3),
    );
  }

  @override
  bool shouldRepaint(_LaserPainter old) => old.y != y;
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
