import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/l10n.dart';
import '../providers/easter_egg_provider.dart';
import '../theme/app_typography.dart';
import '../utils/rick_roll_audio_stub.dart'
    if (dart.library.js_interop) '../utils/rick_roll_audio_web.dart';
import '../utils/rick_roll_tune.dart';

/// What the Konami code gets you.
///
/// Rendered by [KonamiListener] from `MaterialApp.builder`, so it covers every
/// screen at once. The app is *below* this widget in that stack, which is why
/// "the site dims behind him" is a single [Opacity] here rather than a change
/// to any of the 25 screens — none of which is touched, rebuilt, or remounted.
///
/// Everything is drawn: no image ships, nothing is fetched, and the sprite is
/// ours. See rick_roll_tune.dart for why the sound is synthesized too.
class RickRollOverlay extends ConsumerStatefulWidget {
  const RickRollOverlay({super.key});

  @override
  ConsumerState<RickRollOverlay> createState() => _RickRollOverlayState();
}

class _RickRollOverlayState extends ConsumerState<RickRollOverlay>
    with TickerProviderStateMixin {
  /// The dance: fast enough to read as dancing, and the beat the sprite's two
  /// frames alternate on.
  late final AnimationController _dance;

  /// The background hue drift. Deliberately an order of magnitude slower than
  /// the dance — a full-screen rainbow cycling at dance speed is a strobe, and
  /// a strobe is a photosensitivity hazard, not a joke.
  late final AnimationController _hue;

  RickRollPlayback? _audio;
  Timer? _autoDismiss;

  /// Escape has to be *ours* while the roll is up, and the only way to get
  /// first refusal on a key in Flutter is to hold primary focus: dispatch
  /// starts at the focused node and bubbles outward, so a handler that does
  /// not own focus always runs after the map's Escape shortcut and the refine
  /// panel's. (Consuming it from the HardwareKeyboard handler in
  /// [KonamiListener] looks like it would work and does not — the focus tree
  /// is dispatched to regardless of what those handlers return.)
  final FocusNode _focus = FocusNode(debugLabel: 'RickRollOverlay');

  /// Whatever had focus when the code fired — a chat composer, most likely.
  /// Taking focus is a means to an end, not a thing we want to leave behind,
  /// so it goes back when the joke is over.
  FocusNode? _restoreFocusTo;

  @override
  void initState() {
    super.initState();
    _restoreFocusTo = FocusManager.instance.primaryFocus;
    // After the frame: the node has to be attached before it can be focused.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
    _dance = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 480),
    )..repeat();
    _hue = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 6),
    )..repeat();

    // This widget owns the sound for exactly as long as it is on screen:
    // started here, stopped in dispose. Nothing else can start or stop it, so
    // the picture and the audio cannot get out of step.
    _audio = playRickRollHook();
    _autoDismiss = Timer(kRickRollHookDuration, _dismiss);
  }

  @override
  void dispose() {
    _autoDismiss?.cancel();
    // No ref.read here — reading a provider during dispose throws. Stopping
    // the audio is this widget's own business anyway.
    _audio?.stop();
    _dance.dispose();
    _hue.dispose();
    _focus.dispose();
    // Hand focus back on the next frame — requesting it mid-teardown, while
    // this node is still unwinding, is not a safe moment. Guarded on context
    // because whatever held focus may itself be gone by now.
    final restore = _restoreFocusTo;
    if (restore != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (restore.context != null) restore.requestFocus();
      });
    }
    super.dispose();
  }

  void _dismiss() {
    if (!mounted) return;
    ref.read(rickRollProvider.notifier).stop();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Positioned.fill(
      // We render above the root Navigator, where there is no Material and no
      // Overlay — routes bring their own. A transparent Material supplies the
      // text defaults; anything needing an Overlay (a Tooltip, an InkWell's
      // splash) would throw up here, which is why the close control below is
      // hand-built rather than an IconButton.
      child: Material(
        type: MaterialType.transparency,
        child: CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.escape): _dismiss,
          },
          child: Focus(
            focusNode: _focus,
            // Not a stop on the way round the app with Tab — it exists only to
            // own the key. Same shape the trip page uses for its panel.
            skipTraversal: true,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _dismiss,
              child: Stack(
                fit: StackFit.expand,
                alignment: Alignment.center,
                children: [
                  // The roll itself, drawn over the live app.
                  Opacity(
                    opacity: 0.82,
                    child: AnimatedBuilder(
                      animation: Listenable.merge([_dance, _hue]),
                      builder: (context, _) => CustomPaint(
                        painter: _RickRollPainter(
                          dance: _dance.value,
                          hue: _hue.value,
                        ),
                      ),
                    ),
                  ),
                  // Caption at full strength so it stays legible whatever hue is
                  // passing underneath it.
                  Align(
                    alignment: const Alignment(0, 0.82),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            l10n.rickRollCaption,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              fontFamily: AppFonts.display,
                              // The display face ships 500 and 600; naming the
                              // weight keeps the web build off synthetic
                              // faux-bold.
                              fontWeight: FontWeight.w500,
                              fontSize: 44,
                              height: 1.1,
                              color: Colors.white,
                              shadows: _captionShadows,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            l10n.rickRollDismissHint,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              fontFamily: AppFonts.ui,
                              fontSize: 14,
                              letterSpacing: 0.6,
                              color: Colors.white,
                              shadows: _captionShadows,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  // An explicit way out, for anyone who does not think to press a
                  // key or tap the background. Hand-built rather than an
                  // IconButton: no Material for the splash, no Overlay for the
                  // tooltip. The label rides Semantics instead.
                  SafeArea(
                    child: Align(
                      alignment: Alignment.topRight,
                      child: Semantics(
                        button: true,
                        label: l10n.commonClose,
                        child: GestureDetector(
                          onTap: _dismiss,
                          child: Container(
                            margin: const EdgeInsets.all(12),
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.45),
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(
                              Icons.close,
                              color: Colors.white,
                              size: 22,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

const List<Shadow> _captionShadows = [
  Shadow(color: Colors.black, blurRadius: 12),
  Shadow(color: Colors.black54, blurRadius: 2, offset: Offset(0, 2)),
];

// ---------------------------------------------------------------------------
// The sprite.
//
// A rectangle table rather than an image asset, for three reasons: every
// Flutter asset is precached by the service worker for every visitor on every
// deploy (so a picture nobody asked for would cost everybody), a drawn figure
// is unambiguously ours and needs no row in assets/images/LICENSES.md, and it
// scales to any screen without a second resolution.
//
// Coordinates are cells in a [_gridW] x [_gridH] grid, drawn into whatever box
// the painter is given.
// ---------------------------------------------------------------------------

const double _gridW = 16;
const double _gridH = 26;

class _Cell {
  final double x, y, w, h;
  const _Cell(this.x, this.y, this.w, this.h);
}

const Color _hairColor = Color(0xFFE8622A);
const Color _skinColor = Color(0xFFF2C9A0);
const Color _inkColor = Color(0xFF2A1A12);
const Color _coatColor = Color(0xFF23272E);
const Color _shirtColor = Color(0xFFF5F5F5);
const Color _trouserColor = Color(0xFF2F3A56);
const Color _shoeColor = Color(0xFF14161A);

// Parts that do not change between frames.
const List<_Cell> _hair = [
  _Cell(4, 2, 8, 3), // the mass
  _Cell(6, 0, 5, 2), // the quiff
  _Cell(4, 5, 1, 2), // sideburns
  _Cell(11, 5, 1, 2),
];
const List<_Cell> _head = [
  _Cell(5, 5, 6, 5), // face
  _Cell(7, 10, 2, 1), // neck
];
const List<_Cell> _face = [
  _Cell(6, 6, 1, 1), // eyes
  _Cell(9, 6, 1, 1),
  _Cell(7, 8, 2, 1), // mouth
];
const List<_Cell> _coat = [_Cell(4, 11, 8, 7)];
const List<_Cell> _shirt = [_Cell(7, 11, 2, 5)];

// Frame 0: right arm up, legs together. Frame 1: left arm up, legs apart.
const List<List<_Cell>> _sleeves = [
  [
    _Cell(2, 12, 2, 2),
    _Cell(1, 14, 2, 3),
    _Cell(12, 11, 2, 2),
    _Cell(13, 8, 2, 3)
  ],
  [
    _Cell(2, 11, 2, 2),
    _Cell(1, 8, 2, 3),
    _Cell(12, 12, 2, 2),
    _Cell(13, 14, 2, 3)
  ],
];
const List<List<_Cell>> _hands = [
  [_Cell(1, 17, 2, 1), _Cell(13, 7, 2, 1)],
  [_Cell(1, 7, 2, 1), _Cell(13, 17, 2, 1)],
];
const List<List<_Cell>> _legs = [
  [_Cell(5, 18, 3, 6), _Cell(8, 18, 3, 6)],
  [_Cell(4, 18, 3, 6), _Cell(9, 18, 3, 6)],
];
const List<List<_Cell>> _shoes = [
  [_Cell(4, 24, 4, 2), _Cell(8, 24, 4, 2)],
  [_Cell(3, 24, 4, 2), _Cell(9, 24, 4, 2)],
];

class _RickRollPainter extends CustomPainter {
  /// Dance phase, 0..1. Drives the bob, the lean, and which of the two arm/leg
  /// frames is showing.
  final double dance;

  /// Background hue phase, 0..1.
  final double hue;

  const _RickRollPainter({required this.dance, required this.hue});

  @override
  void paint(Canvas canvas, Size size) {
    final bounds = Offset.zero & size;

    // Rainbow ground.
    canvas.drawRect(
      bounds,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            for (var i = 0; i < 6; i++)
              HSVColor.fromAHSV(1, (hue * 360 + i * 60) % 360, 0.62, 0.88)
                  .toColor(),
          ],
        ).createShader(bounds),
    );

    // Fit the sprite into the middle of whatever box we were given, leaving
    // room at the bottom for the caption.
    final cell =
        math.min(size.width / (_gridW * 2.2), size.height / (_gridH * 1.9));
    final spriteW = _gridW * cell;
    final spriteH = _gridH * cell;
    final bob = math.sin(dance * 2 * math.pi) * cell * 0.7;
    final lean = math.sin(dance * 2 * math.pi) * 0.05;
    final frame = dance < 0.5 ? 0 : 1;

    canvas.save();
    canvas.translate(size.width / 2, size.height / 2 - spriteH * 0.08 + bob);
    canvas.rotate(lean);
    canvas.translate(-spriteW / 2, -spriteH / 2);

    void fill(List<_Cell> cells, Color color) {
      final paint = Paint()..color = color;
      for (final c in cells) {
        canvas.drawRect(
          Rect.fromLTWH(c.x * cell, c.y * cell, c.w * cell, c.h * cell),
          paint,
        );
      }
    }

    fill(_legs[frame], _trouserColor);
    fill(_shoes[frame], _shoeColor);
    fill(_sleeves[frame], _coatColor);
    fill(_hands[frame], _skinColor);
    fill(_coat, _coatColor);
    fill(_shirt, _shirtColor);
    fill(_head, _skinColor);
    fill(_hair, _hairColor);
    fill(_face, _inkColor);

    canvas.restore();
  }

  @override
  bool shouldRepaint(_RickRollPainter old) =>
      old.dance != dance || old.hue != hue;
}
