// Windows: 本体の入力を開けるかの確認（入力を開くだけ。本体へは何も送らない）
// 本体がつながっていないときは飛ばす。KITPLAYER_LISTEN=秒 を付けると、その間に届いたものを表示する
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kitplayer/midi_out.dart';

void main() {
  test('本体の入力を開いて閉じる', () async {
    if (!Platform.isWindows) return;
    final got = <String>[];
    final inp = WinMidiIn((d) => got.add(d.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ')));
    final ok = inp.open('TinyKeyboard.1');
    if (!ok) {
      markTestSkipped('本体の入力が見つからない');
      return;
    }
    expect(inp.name, 'TinyKeyboard.1');
    final sec = int.tryParse(Platform.environment['KITPLAYER_LISTEN'] ?? '') ?? 1;
    await Future.delayed(Duration(seconds: sec));
    inp.close();
    expect(inp.name, null);
    // ignore: avoid_print
    print('届いたもの: ${got.isEmpty ? '（なし）' : got.join(' / ')}');
    // 開き直せる（閉じたあとに残っていない）
    expect(inp.open('TinyKeyboard.1'), true);
    inp.close();
  });

  test('出力と同じ機器の入力を選ぶ', () {
    expect(pickInputFor('TinyKeyboard.1', ['Foo', 'TinyKeyboard.1']), 1);
    expect(pickInputFor('TinyKeyboard.1', ['TinyKeyboard']), 0);
    expect(pickInputFor('TinyKeyboard.1', ['Foo']), -1);
  });
}
