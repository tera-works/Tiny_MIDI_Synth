import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tone_editor/builtin_table.dart';
import 'package:tone_editor/device.dart';
import 'package:tone_editor/main.dart';
import 'package:tone_editor/mock_device.dart';
import 'package:tone_editor/params.dart';
import 'package:tone_editor/presets.dart';

void main() {
  test('パラメータの定義: 番号の重複なし・内蔵の表が範囲内', () {
    final base = kParams.where((p) => !p.ext).toList();
    final ext = kParams.where((p) => p.ext).toList();
    expect(base.length, kNumParams);
    expect(base.map((p) => p.index).toSet().length, kNumParams);
    expect(ext.map((p) => p.index).toSet().length, ext.length);
    for (final d in ext) {
      expect(d.index < kNumExt, isTrue);
      expect(kSynthExtDefault[d.index] >= d.min && kSynthExtDefault[d.index] <= d.max, isTrue, reason: d.key);
    }
    for (final (name, v) in kBuiltinInstruments) {
      expect(v.length, kNumParams, reason: name);
      for (var i = 0; i < kNumParams; i++) {
        if (i > 0 && !kParams.firstWhere((d) => !d.ext && d.index == i).visibleFor(v[0])) continue; // その鳴らし方で使わない項目
        final (lo, hi) = kParamRange[i];
        expect(v[i] >= lo && v[i] <= hi, isTrue, reason: '$name の $i = ${v[i]}');
      }
    }
    expect(kBuiltinInstruments.length, 82);
  });

  test('重さのめやす: シンセは重ねるほど重い', () {
    final p = List<int>.from(kBuiltinInstruments[0].$2)..[0] = algoSyn;
    final x1 = List<int>.from(kSynthExtDefault)..[12] = 1;
    final x4 = List<int>.from(kSynthExtDefault)..[12] = 4;
    expect(toneCost(p, x4) > toneCost(p, x1) * 1.5, isTrue);
    expect(voicesFor(toneCost(p, x1)) >= voicesFor(toneCost(p, x4)), isTrue);
  });

  test('シンセのプリセット: 範囲内・名前 15 バイト以内・重すぎない', () {
    expect(kSynthPresets.length >= 8, isTrue);
    for (final (name, p, x) in kSynthPresets) {
      expect(p.length, kNumParams, reason: name);
      expect(x.length, kNumExt, reason: name);
      expect(clampParams(p), p, reason: '$name の基本パラメータが範囲外');
      expect(clampExt(x), x, reason: '$name の拡張パラメータが範囲外');
      expect(sanitizeName(name), name);
      expect(p[0], algoSyn, reason: name);
      expect(voicesFor(toneCost(p, x)) >= 12, isTrue, reason: '$name が重すぎる');
    }
  });

  test('名前は 15 バイト以内・区切り文字なし', () {
    expect(sanitizeName('My|Pad'), 'My Pad');
    expect(sanitizeName('あいうえおかきく').runes.length, 5); // 3 バイト × 5 = 15
    expect(sanitizeName('   '), 'User');
  });

  test('模擬本体とのやりとり（接続・読み書き・割り当て・保存・戻す・負荷）', () async {
    final dev = DeviceClient();
    final mock = MockDevice();
    await dev.connect(mock);
    expect(dev.connected, isTrue);
    expect(dev.info!.userBase, 82);
    final names = await dev.names();
    expect(names.length, 90);
    expect(names[0], 'Saw Lead');
    expect(names[82], 'Super Saw');

    final ep = await dev.getPatch(6); // E.Piano
    expect(ep.name, 'E.Piano');
    expect(ep.values, kBuiltinInstruments[6].$2);
    expect(ep.ext.length, kNumExt);

    final p = Patch('My EP', ep.values)
      ..values[24] = 99
      ..ext[12] = 3;
    await dev.setPatch(2, p);
    final back = await dev.getPatch(84);
    expect(back.name, 'My EP');
    expect(back.values[24], 99);
    expect(back.ext[12], 3);
    expect((await dev.names())[84], 'My EP');

    // 範囲外は収められる
    await dev.setPatch(3, Patch('x', List.filled(36, 999), List.filled(40, 999)));
    final c = await dev.getPatch(85);
    expect(c.values[0], algoSyn);
    expect(c.values[11], 150);
    expect(c.ext[12], 4);

    // 5 ボタン × 3 組。ドラム・Buzzer も割り当てられる
    expect((await dev.getAssign()).tones, MockDevice.defaultTones);
    final t = List<int>.generate(15, (i) => i);
    t[0] = 84;
    t[1] = 5;
    t[14] = 18;
    await dev.setAssign(Assignment(t));
    final a = await dev.getAssign();
    expect(a.tones, t);
    expect(a.at(0, 0), 84);
    expect(a.at(2, 4), 18);

    await expectLater(dev.setAssign(Assignment([0, 1, 2, 3, 4])), throwsA(isA<DeviceException>()));

    await dev.save();
    await dev.setPatch(2, Patch('changed', ep.values));
    await dev.loadSaved();
    expect((await dev.getPatch(84)).name, 'My EP');

    // 負荷の表示
    dev.noteOn(60, 100);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(dev.load, isNotNull);
    expect(dev.load!.voices, 1);
    dev.noteOff(60);

    await dev.defaults();
    expect((await dev.getPatch(84)).name, 'Analog Brass');
    await dev.disconnect();
    expect(dev.connected, isFalse);
  });

  testWidgets('画面: デモにつないで、音色を編集して本体（模擬）に届く', (tester) async {
    tester.view.physicalSize = const Size(1400, 4000); // 縦長にして、全項目を一度に作らせる
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final dev = DeviceClient();
    await tester.pumpWidget(ToneEditorApp(client: dev));
    await tester.tap(find.textContaining('本体なしで試す'));
    await tester.pumpAndSettle();
    expect(find.text('音色を作る'), findsOneWidget);
    expect(find.text('Super Saw'), findsWidgets);

    // 名前を変える → 少し待つと本体へ送られる
    await tester.enterText(find.byType(TextField).first, 'Lead X');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect((await dev.getPatch(82)).name, 'Lead X');
    expect(find.textContaining('まだ保存していません'), findsOneWidget);

    // 鳴らし方を FM に → FM の項目が出る
    await tester.tap(find.text('FM'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect(find.text('変調の周波数比'), findsOneWidget);
    expect(find.text('明るさ（カットオフ）'), findsNothing); // SUB の項目は隠れる
    expect((await dev.getPatch(82)).values[0], algoFm);

    // シンセに → 発振器・LFO が出る、重さのカードが出る
    await tester.tap(find.text('シンセ'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect(find.text('発振器 2'), findsOneWidget);
    expect(find.text('明るさ（カットオフ）'), findsOneWidget);
    expect(find.textContaining('重さ: 1 音'), findsOneWidget);
    expect((await dev.getPatch(82)).values[0], algoSyn);

    // プリセットを読み込む
    await tester.tap(find.text('シンセのプリセット'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('FM Bell').last);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect((await dev.getPatch(82)).name, 'FM Bell');
    expect((await dev.getPatch(82)).ext[9], kSynthPresets.firstWhere((e) => e.$1 == 'FM Bell').$3[9]);

    // 保存
    await tester.tap(find.text('本体に保存'));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();
    expect(find.text('本体に保存した内容と同じです'), findsOneWidget);

    // 割り当てのタブ
    await tester.tap(find.text('ボタンに割り当て'));
    await tester.pumpAndSettle();
    expect(find.text('TONE1'), findsNWidgets(3));
    expect(find.text('組 3'), findsOneWidget);
    expect(find.textContaining('音色ボタンを一度押すと'), findsOneWidget);

    // 切断すると接続の画面に戻る
    await tester.tap(find.text('切断'));
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    expect(find.text('本体につなぐ'), findsOneWidget);
  });
}
