// プレイリストの編集（読み込み・並べ替え・削除・曲の追加・保存・読み直し）の確認
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kitplayer/player.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('プレイリストの編集と保存', () async {
    final tmp = await Directory.systemTemp.createTemp('kitplayer_test');
    final dir = tmp.path;
    final sep = Platform.pathSeparator;
    // 曲（中身は最小の MIDI ファイル）
    final mid = [0x4D, 0x54, 0x68, 0x64, 0, 0, 0, 6, 0, 0, 0, 1, 0, 96, 0x4D, 0x54, 0x72, 0x6B, 0, 0, 0, 12, 0, 0x90, 60, 100, 96, 0x80, 60, 0, 0, 0xFF, 0x2F, 0];
    await Directory('$dir$sepアニメ').create();
    for (final n in ['a.mid', 'b.mid', 'アニメ${sep}c.mid']) {
      await File('$dir$sep$n').writeAsBytes(mid);
    }
    final other = await Directory.systemTemp.createTemp('kitplayer_other');
    await File('${other.path}${sep}x.mid').writeAsBytes(mid);
    final list = '$dir${sep}playlist.txt';
    // 「# ---- … ----」の見出しはただのコメントとして読み飛ばす
    await File(list).writeAsString('# ---- 前半 ----\na.mid\nアニメ/c.mid\n# ---- 後半 ----\nb.mid\n');

    final p = Player(dryRun: true);
    await p.loadPlaylistFile(list);
    expect(p.songs.map((s) => s.name).toList(), ['a', 'c', 'b']);
    expect(p.rows.length, 3);

    p.moveRow(2, 0); // b を先頭へ
    expect(p.songs.map((s) => s.name).toList(), ['b', 'a', 'c']);
    await p.addFiles(['${other.path}${sep}x.mid']); // 別のフォルダの曲（絶対パスで保存される）
    p.removeRow(1); // a を外す
    expect(p.dirty, true);
    expect(p.songs.map((s) => s.name).toList(), ['b', 'c', 'x']);

    expect(await p.savePlaylist(), true);
    expect(p.dirty, false);
    final saved = await File(list).readAsString();
    expect(saved.contains('アニメ/c.mid'), true); // 同じフォルダの曲は相対パス
    expect(saved.contains('${other.path}${sep}x.mid'), true); // 別のフォルダは絶対パス
    expect(saved.contains('----'), false);

    final q = Player(dryRun: true);
    await q.loadPlaylistFile(list);
    expect(q.songs.map((s) => s.name).toList(), ['b', 'c', 'x']);
    await tmp.delete(recursive: true);
    await other.delete(recursive: true);
  });
}
