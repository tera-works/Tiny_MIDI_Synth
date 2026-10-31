import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 試聴用の鍵盤（2 オクターブ）。マウスで押すか、PC のキーボード（Z〜M / Q〜I の段）で弾ける
class PianoKeyboard extends StatefulWidget {
  final int lowNote; // 左端の C
  final void Function(int note) onDown;
  final void Function(int note) onUp;
  const PianoKeyboard({super.key, required this.lowNote, required this.onDown, required this.onUp});
  @override
  State<PianoKeyboard> createState() => _PianoKeyboardState();
}

// PC のキー → 左端の C からの半音
final Map<LogicalKeyboardKey, int> _keyMap = {
  LogicalKeyboardKey.keyZ: 0, LogicalKeyboardKey.keyS: 1, LogicalKeyboardKey.keyX: 2, LogicalKeyboardKey.keyD: 3,
  LogicalKeyboardKey.keyC: 4, LogicalKeyboardKey.keyV: 5, LogicalKeyboardKey.keyG: 6, LogicalKeyboardKey.keyB: 7,
  LogicalKeyboardKey.keyH: 8, LogicalKeyboardKey.keyN: 9, LogicalKeyboardKey.keyJ: 10, LogicalKeyboardKey.keyM: 11,
  LogicalKeyboardKey.keyQ: 12, LogicalKeyboardKey.digit2: 13, LogicalKeyboardKey.keyW: 14, LogicalKeyboardKey.digit3: 15,
  LogicalKeyboardKey.keyE: 16, LogicalKeyboardKey.keyR: 17, LogicalKeyboardKey.digit5: 18, LogicalKeyboardKey.keyT: 19,
  LogicalKeyboardKey.digit6: 20, LogicalKeyboardKey.keyY: 21, LogicalKeyboardKey.digit7: 22, LogicalKeyboardKey.keyU: 23,
  LogicalKeyboardKey.keyI: 24,
};

class _PianoKeyboardState extends State<PianoKeyboard> {
  final Set<int> _down = {};
  final Map<int, int> _pointerNote = {};
  final FocusNode _focus = FocusNode(debugLabel: 'piano');
  static const _whiteSteps = [0, 2, 4, 5, 7, 9, 11];
  static const _blackAfter = {0: 1, 1: 3, 3: 6, 4: 8, 5: 10}; // 白鍵の番号（オクターブ内）→ その右の黒鍵

  @override
  void dispose() {
    for (final n in _down) {
      widget.onUp(n);
    }
    _focus.dispose();
    super.dispose();
  }

  void _press(int n) {
    if (_down.add(n)) {
      widget.onDown(n);
      setState(() {});
    }
  }

  void _release(int n) {
    if (_down.remove(n)) {
      widget.onUp(n);
      setState(() {});
    }
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    final off = _keyMap[e.logicalKey];
    if (off == null) return KeyEventResult.ignored;
    final n = widget.lowNote + off;
    if (e is KeyDownEvent) _press(n);
    if (e is KeyUpEvent) _release(n);
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    const octaves = 2;
    const whiteCount = octaves * 7 + 1;
    return Focus(
      focusNode: _focus,
      onKeyEvent: _onKey,
      child: LayoutBuilder(builder: (context, c) {
        final w = c.maxWidth / whiteCount;
        final h = c.maxHeight;
        final keys = <Widget>[];
        // 白鍵
        for (var i = 0; i < whiteCount; i++) {
          final note = widget.lowNote + (i ~/ 7) * 12 + _whiteSteps[i % 7];
          keys.add(Positioned(
            left: i * w, top: 0, width: w, height: h,
            child: _key(note, false, scheme, label: note % 12 == 0 ? 'C${note ~/ 12 - 1}' : null),
          ));
        }
        // 黒鍵
        for (var i = 0; i < whiteCount - 1; i++) {
          final b = _blackAfter[i % 7];
          if (b == null) continue;
          final note = widget.lowNote + (i ~/ 7) * 12 + b;
          keys.add(Positioned(left: (i + 1) * w - w * 0.32, top: 0, width: w * 0.64, height: h * 0.6, child: _key(note, true, scheme)));
        }
        return GestureDetector(
          onTap: () => _focus.requestFocus(),
          child: Stack(children: keys),
        );
      }),
    );
  }

  Widget _key(int note, bool black, ColorScheme scheme, {String? label}) {
    final pressed = _down.contains(note);
    final color = pressed ? scheme.primary : (black ? const Color(0xFF222222) : Colors.white);
    return Listener(
      onPointerDown: (e) {
        _focus.requestFocus();
        _pointerNote[e.pointer] = note;
        _press(note);
      },
      onPointerUp: (e) { final n = _pointerNote.remove(e.pointer); if (n != null) _release(n); },
      onPointerCancel: (e) { final n = _pointerNote.remove(e.pointer); if (n != null) _release(n); },
      child: Container(
        decoration: BoxDecoration(
          color: color,
          border: Border.all(color: Colors.black54, width: 0.8),
          borderRadius: const BorderRadius.vertical(bottom: Radius.circular(4)),
        ),
        alignment: Alignment.bottomCenter,
        padding: const EdgeInsets.only(bottom: 4),
        child: label == null ? null : Text(label, style: TextStyle(fontSize: 10, color: pressed ? Colors.white : Colors.black54)),
      ),
    );
  }
}
