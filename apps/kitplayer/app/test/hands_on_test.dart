// 本体の鍵盤が押されたら止めて、操作が終わってしばらくたつと次の曲から再生する、の確認（MIDI は送らない）
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kitplayer/player.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('本体の操作で止まり、離してしばらくたつと次の曲へ', () async {
    final tmp = await Directory.systemTemp.createTemp('kitplayer_hands');
    final sep = Platform.pathSeparator;
    // 4 秒の曲（ノートを 1 拍ずつ）
    final trk = <int>[];
    for (int i = 0; i < 8; ++i) {
      trk.addAll([0, 0x90, 60, 100, 96, 0x80, 60, 0]);
    }
    trk.addAll([0, 0xFF, 0x2F, 0]);
    final mid = [0x4D, 0x54, 0x68, 0x64, 0, 0, 0, 6, 0, 0, 0, 1, 0, 96, 0x4D, 0x54, 0x72, 0x6B, 0, 0, 0, trk.length, ...trk];
    for (final n in ['a.mid', 'b.mid', 'c.mid']) {
      await File('${tmp.path}$sep$n').writeAsBytes(mid);
    }
    final p = Player(dryRun: true);
    await p.init(folderArg: tmp.path, autoplayArg: false);
    p.yieldOnTouch = true;
    p.yieldResumeSec = 0.5;
    p.master = 80;
    p.startSong(0);
    await Future.delayed(const Duration(milliseconds: 400));
    expect(p.state, PlayState.playing);
    expect(p.masterSent, 80);

    // 止めている（一時停止）ときは何もしない
    p.pause();
    p.onDeviceInput(Uint8List.fromList([0x90, 60, 127]));
    expect(p.state, PlayState.paused);
    p.onDeviceInput(Uint8List.fromList([0x80, 60, 0]));
    p.resume();
    await Future.delayed(const Duration(milliseconds: 100));
    expect(p.state, PlayState.playing);

    // スティック（ベンド・モジュレーション）・ペダル・離しただけでは止まらない
    p.onDeviceInput(Uint8List.fromList([0xE0, 0, 100]));
    p.onDeviceInput(Uint8List.fromList([0xE0, 0, 64]));
    p.onDeviceInput(Uint8List.fromList([0xB0, 1, 90]));
    p.onDeviceInput(Uint8List.fromList([0xB0, 64, 127]));
    p.onDeviceInput(Uint8List.fromList([0xB0, 64, 0]));
    p.onDeviceInput(Uint8List.fromList([0x80, 70, 0]));
    p.onDeviceInput(Uint8List.fromList([0x90, 70, 0])); // ベロシティ 0 = 離した
    expect(p.state, PlayState.playing);

    // 鍵盤を押すと止まる。押さえている間は始めない
    p.onDeviceInput(Uint8List.fromList([0x90, 64, 127]));
    expect(p.state, PlayState.handsOn);
    expect(p.handsOnLeft, null);
    expect(p.masterSent, 127); // 操作している間は最大
    expect(p.master, 80); // 設定はそのまま
    await Future.delayed(const Duration(milliseconds: 800));
    expect(p.state, PlayState.handsOn);

    // 離して 0.5 秒たつと次の曲（b）から
    p.onDeviceInput(Uint8List.fromList([0x80, 64, 0]));
    expect(p.handsOnLeft, isNotNull);
    await Future.delayed(const Duration(milliseconds: 200));
    expect(p.state, PlayState.handsOn);
    await Future.delayed(const Duration(milliseconds: 600));
    expect(p.state, PlayState.playing);
    expect(p.curName, 'b');
    expect(p.masterSent, 80); // 再開したら元の音量

    // 操作中に「停止」を押しても元の音量に戻る
    p.onDeviceInput(Uint8List.fromList([0x90, 64, 127]));
    p.onDeviceInput(Uint8List.fromList([0x80, 64, 0]));
    expect(p.masterSent, 127);
    p.stopAll();
    expect(p.masterSent, 80);
    p.startSong(1);
    await Future.delayed(const Duration(milliseconds: 100));

    // 2 つ押さえて 1 つ離しても始めない。両方離して 0.5 秒で次の曲（c）
    p.onDeviceInput(Uint8List.fromList([0x90, 60, 127]));
    p.onDeviceInput(Uint8List.fromList([0x90, 64, 127]));
    expect(p.state, PlayState.handsOn);
    p.onDeviceInput(Uint8List.fromList([0x80, 60, 0]));
    await Future.delayed(const Duration(milliseconds: 800));
    expect(p.state, PlayState.handsOn);
    p.onDeviceInput(Uint8List.fromList([0x90, 64, 0]));
    await Future.delayed(const Duration(milliseconds: 800));
    expect(p.curName, 'c');

    // 「自動では始めない」なら ▶ を押すまで止めたまま
    p.yieldResumeSec = 0;
    p.onDeviceInput(Uint8List.fromList([0x90, 62, 127]));
    p.onDeviceInput(Uint8List.fromList([0x80, 62, 0]));
    expect(p.state, PlayState.handsOn);
    await Future.delayed(const Duration(milliseconds: 800));
    expect(p.state, PlayState.handsOn);
    p.togglePlay();
    await Future.delayed(const Duration(milliseconds: 100));
    expect(p.state, PlayState.playing);
    expect(p.curName, 'a'); // c の次は最初へ

    // 「本体の鍵盤を押したら止める」を切ると止まらない
    p.yieldOnTouch = false;
    p.onDeviceInput(Uint8List.fromList([0x90, 60, 127]));
    expect(p.state, PlayState.playing);

    p.dispose();
    await tmp.delete(recursive: true);
  });
}
