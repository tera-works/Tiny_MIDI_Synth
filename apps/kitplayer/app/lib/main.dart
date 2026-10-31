// kitplayer — midikit で最適化した MIDI ファイルを midi_keyboard_kit_synth に流し続ける展示用プレーヤー（GUI 版）
//
// ・「フォルダを開く」で「最適化後」フォルダ、または「曲を開く」で曲を選ぶ（次からは起動すると前のプレイリストを自動で読む）
// ・16 チャンネルを 1 画面に表示: 本体で鳴る音色・GM の音色・レベル・音量・パン・エクスプレッション・ベンド・
//   モジュレーション・リバーブ・コーラス・押さえている鍵盤
// ・チャンネルごとの音量はドラッグ（ホイール・ダブルクリックで 100%）。スピーカーのボタン = ミュート、S = ソロ。曲ごとに覚える
// ・「プレイリスト」のタブで、曲の追加・削除・並べ替え（ドラッグ）をして保存できる
// ・本体が抜けたら待ち、挿し直されたら自動でつなぎ直して、その曲を頭から再生する
// キー: スペース = 一時停止 / 再開、n / → = 次、b / ← = 前、r = 頭から、s = 停止
// 確認用の起動オプション: --dry（MIDI を送らない） --folder パス --autoplay --report ファイル --exit-after 秒
//                         --screenshot ファイル --shot-after 秒（画面を PNG で保存） --tab 1（プレイリストのタブで起動）
//                         --sim-touch 秒（本体の鍵盤を押したことにする）
// ・本体の鍵盤が押されたら止める。操作が終わってしばらくたつと次の曲から再生（設定で変えられる）
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import 'instruments.dart';
import 'player.dart';

const kChColors = [
  Color(0xFFFF6B6B), Color(0xFFFFA94D), Color(0xFFFFD43B), Color(0xFFA9E34B), Color(0xFF51CF66), Color(0xFF20C997), Color(0xFF22B8CF), Color(0xFF4DABF7),
  Color(0xFF748FFC), Color(0xFF9775FA), Color(0xFFE599F7), Color(0xFFF783AC), Color(0xFFFF8787), Color(0xFFFFC078), Color(0xFF8CE99A), Color(0xFF66D9E8),
];
const kBg = Color(0xFF0F1115), kPanel = Color(0xFF171A21), kPanel2 = Color(0xFF1E222B), kLine = Color(0xFF2A2F3A);
const kText = Color(0xFFE8EAF0), kSub = Color(0xFF9AA3B5), kAccent = Color(0xFF5FB3FF), kGood = Color(0xFF46C27A), kBad = Color(0xFFEF5A5A);
const kLcd = Color(0xFFB8E04A), kLcdBg = Color(0xFF14180C);

void main(List<String> args) {
  String? arg(String k) {
    final i = args.indexOf(k);
    return i >= 0 && i + 1 < args.length ? args[i + 1] : null;
  }

  final player = Player(dryRun: args.contains('--dry'));
  runApp(KitPlayerApp(player: player, initialTab: int.tryParse(arg('--tab') ?? '') ?? 0));
  player.init(folderArg: arg('--folder'), autoplayArg: args.contains('--autoplay') ? true : null);
  final shot = arg('--screenshot');
  if (shot != null) {
    Timer(Duration(milliseconds: ((double.tryParse(arg('--shot-after') ?? '') ?? 5) * 1000).round()), () async {
      final b = _shotKey.currentContext?.findRenderObject() as RenderRepaintBoundary?;
      final img = await b?.toImage(pixelRatio: 2);
      final png = await img?.toByteData(format: ui.ImageByteFormat.png);
      if (png != null) File(shot).writeAsBytesSync(png.buffer.asUint8List());
    });
  }
  // 確認用: 本体の鍵盤を押した（離した）ことにする
  final touch = double.tryParse(arg('--sim-touch') ?? '');
  if (touch != null) {
    Timer(Duration(milliseconds: (touch * 1000).round()), () {
      player.onDeviceInput(Uint8List.fromList([0x90, 60, 127]));
      Timer(const Duration(milliseconds: 300), () => player.onDeviceInput(Uint8List.fromList([0x80, 60, 0])));
    });
  }
  final exitAfter = double.tryParse(arg('--exit-after') ?? '');
  final report = arg('--report');
  if (exitAfter != null) {
    Timer(Duration(milliseconds: (exitAfter * 1000).round()), () async {
      if (report != null) {
        final r = await player.timingReport();
        File(report).writeAsStringSync('${r ?? '（記録なし）'}\n${player.logs.reversed.join('\n')}\n');
      }
      exit(0);
    });
  }
}

final _shotKey = GlobalKey();

class KitPlayerApp extends StatelessWidget {
  final Player player;
  final int initialTab;
  const KitPlayerApp({super.key, required this.player, this.initialTab = 0});
  @override
  // 読み上げ用の情報（セマンティクス）は作らない。Windows で画面を読むソフトが動いていると、
  // Flutter の読み上げの橋渡し（AXTree の更新）が失敗して落ちることがあるため
  Widget build(BuildContext context) => ExcludeSemantics(child: RepaintBoundary(key: _shotKey, child: MaterialApp(
        title: 'kitplayer',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          brightness: Brightness.dark,
          scaffoldBackgroundColor: kBg,
          colorScheme: const ColorScheme.dark(primary: kAccent, surface: kPanel),
          sliderTheme: const SliderThemeData(trackHeight: 3, thumbShape: RoundSliderThumbShape(enabledThumbRadius: 7), overlayShape: RoundSliderOverlayShape(overlayRadius: 12)),
        ),
        home: PlayerPage(player: player, initialTab: initialTab),
      )));
}

class PlayerPage extends StatefulWidget {
  final Player player;
  final int initialTab;
  const PlayerPage({super.key, required this.player, this.initialTab = 0});
  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  final _focus = FocusNode();
  Player get p => widget.player;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker((_) => p.onFrame())..start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    _focus.dispose();
    super.dispose();
  }

  KeyEventResult _onKey(FocusNode n, KeyEvent e) {
    if (e is! KeyDownEvent) return KeyEventResult.ignored;
    final k = e.logicalKey;
    if (k == LogicalKeyboardKey.space) {
      p.togglePlay();
    } else if (k == LogicalKeyboardKey.keyN || k == LogicalKeyboardKey.arrowRight) {
      p.next();
    } else if (k == LogicalKeyboardKey.keyB || k == LogicalKeyboardKey.arrowLeft) {
      p.prev();
    } else if (k == LogicalKeyboardKey.keyR) {
      p.restart();
    } else if (k == LogicalKeyboardKey.keyS) {
      p.stopAll();
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) => Focus(
        focusNode: _focus,
        autofocus: true,
        onKeyEvent: _onKey,
        child: Scaffold(
          body: DefaultTextStyle(
            style: const TextStyle(color: kText, fontSize: 12),
            child: DefaultTabController(
              length: 2,
              initialIndex: widget.initialTab,
              child: ListenableBuilder(
                listenable: p,
                builder: (context, _) => Column(children: [
                  TopPanel(p: p, onFolder: _pickFolder, onFiles: _openFiles, onSettings: _settings),
                  Container(
                    height: 32,
                    alignment: Alignment.centerLeft,
                    color: kPanel2,
                    child: TabBar(
                      isScrollable: true,
                      tabAlignment: TabAlignment.start,
                      labelPadding: const EdgeInsets.symmetric(horizontal: 18),
                      dividerHeight: 0,
                      onTap: (_) => _focus.requestFocus(),
                      tabs: [
                        const Tab(height: 32, text: 'チャンネル'),
                        Tab(height: 32, text: 'プレイリスト（${p.songs.length} 曲${p.dirty ? '・未保存' : ''}）'),
                      ],
                    ),
                  ),
                  Expanded(
                    child: TabBarView(physics: const NeverScrollableScrollPhysics(), children: [
                      ChannelTable(p: p),
                      PlaylistTab(p: p, onAddFiles: _addFiles, onFolder: _pickFolder, onOpenList: _openPlaylist, onSaveAs: _savePlaylistAs, refocus: _focus.requestFocus),
                    ]),
                  ),
                  StatusBar(p: p, onLog: _showLog),
                ]),
              ),
            ),
          ),
        ),
      );

  static const _midiTypes = [XTypeGroup(label: 'MIDI ファイル', extensions: ['mid', 'midi'], uniformTypeIdentifiers: ['public.midi-audio'])];
  static const _listTypes = [XTypeGroup(label: 'プレイリスト', extensions: ['txt'], uniformTypeIdentifiers: ['public.plain-text'])];

  Future<void> _pickFolder() async {
    final dir = await getDirectoryPath(confirmButtonText: 'このフォルダを再生');
    if (dir != null) await p.loadFolder(dir);
    _focus.requestFocus();
  }

  // 曲を開く: プレイリストに足して、すぐ再生する
  Future<void> _openFiles() async {
    final fs = await openFiles(acceptedTypeGroups: _midiTypes, confirmButtonText: '開いて再生');
    if (fs.isNotEmpty) await p.addFiles([for (final f in fs) f.path], play: true);
    _focus.requestFocus();
  }

  // プレイリストに曲を足す（再生はしない）
  Future<void> _addFiles() async {
    final fs = await openFiles(acceptedTypeGroups: _midiTypes, confirmButtonText: '追加');
    if (fs.isNotEmpty) await p.addFiles([for (final f in fs) f.path]);
    _focus.requestFocus();
  }

  Future<void> _openPlaylist() async {
    final f = await openFile(acceptedTypeGroups: _listTypes, initialDirectory: p.folder.isEmpty ? null : p.folder);
    if (f != null) await p.loadPlaylistFile(f.path);
    _focus.requestFocus();
  }

  Future<void> _savePlaylistAs() async {
    final loc = await getSaveLocation(
        suggestedName: p.playlistFile.isEmpty ? 'playlist.txt' : p.playlistFile.split(RegExp(r'[\\/]')).last,
        initialDirectory: p.folder.isEmpty ? null : p.folder,
        acceptedTypeGroups: _listTypes);
    if (loc != null) {
      final path = loc.path.toLowerCase().endsWith('.txt') ? loc.path : '${loc.path}.txt';
      await p.savePlaylist(path);
    }
    _focus.requestFocus();
  }

  Future<void> _showLog() async {
    await showDialog(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('ログ'),
        content: SizedBox(
          width: 600,
          height: 420,
          child: ListView(children: [for (final l in p.logs) Text(l, style: const TextStyle(fontSize: 12, fontFeatures: [FontFeature.tabularFigures()]))]),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(c), child: const Text('閉じる'))],
      ),
    );
    _focus.requestFocus();
  }

  Future<void> _settings() async {
    final ports = await p.listPorts();
    if (!mounted) return;
    await showDialog(context: context, builder: (c) => SettingsDialog(p: p, ports: ports));
    _focus.requestFocus();
  }
}

// ---------------- 上段: 曲の情報・操作 ----------------
class TopPanel extends StatelessWidget {
  final Player p;
  final VoidCallback onFolder, onFiles, onSettings;
  const TopPanel({super.key, required this.p, required this.onFolder, required this.onFiles, required this.onSettings});

  @override
  Widget build(BuildContext context) {
    final playing = p.state == PlayState.playing;
    final title = p.curName ?? (p.songs.isEmpty ? '「フォルダを開く」か「曲を開く」で曲を選んでください' : '▶ を押すと始まります');
    String section() {
      if (p.state == PlayState.handsOn) {
        final left = p.handsOnLeft;
        if (p.yieldResumeSec <= 0) return '本体が操作されたので止めています（▶ で次の曲から再生）';
        return left == null ? '本体が操作されています。操作が終わって ${p.yieldResumeSec.round()} 秒たつと次の曲から再生します' : '本体が操作されたので止めています。あと ${left.ceil()} 秒で次の曲から再生します';
      }
      return switch (p.state) {
        PlayState.gap => '次の曲まで ${p.gapSec.toStringAsFixed(p.gapSec % 1 == 0 ? 0 : 1)} 秒',
        PlayState.waiting => '本体が見つかりません。USB を挿すと、この曲を頭から再生します',
        PlayState.loading => '読み込み中…',
        _ => '',
      };
    }

    return Container(
      color: kPanel,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // 液晶風の表示
        Expanded(
          child: Container(
            height: 92,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(color: kLcdBg, borderRadius: BorderRadius.circular(8), border: Border.all(color: const Color(0xFF3A4420))),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              AnimatedBuilder(
                animation: p.frame, // 残り秒を数える
                builder: (_, _) => Text(section(), maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        color: p.state == PlayState.waiting ? kBad : (p.state == PlayState.handsOn ? const Color(0xFFFFD43B) : kLcd.withValues(alpha: .75)),
                        fontSize: 12,
                        fontWeight: FontWeight.w600)),
              ),
              Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: kLcd, fontSize: 26, fontWeight: FontWeight.w800, height: 1.2)),
              const Spacer(),
              AnimatedBuilder(
                animation: p.frame,
                builder: (_, _) {
                  final s = p.song;
                  final t = s == null ? 0.0 : math.min(s.dur, math.max(0.0, p.songTime));
                  return Row(children: [
                    _lcd('BPM', s == null ? '---' : s.bpmAt(t).round().toString()),
                    _lcd('TIME', '${fmtTime(t)} / ${fmtTime(s?.dur ?? 0)}'),
                    _lcd('曲', p.songs.isEmpty ? '--' : '${p.cur + 1} / ${p.songs.length}'),
                    _lcd('音質', p.quality == 1 ? '高音質' : (p.quality == 0 ? '普通' : '--')),
                    Flexible(child: _lcd('本体', p.connected ? (p.portName ?? '') : '見つかりません', bad: !p.connected)),
                  ]);
                },
              ),
            ]),
          ),
        ),
        const SizedBox(width: 12),
        // 操作
        SizedBox(
          width: 640,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              _btn(Icons.skip_previous, '前の曲（b / ←）', p.songs.isEmpty ? null : p.prev),
              const SizedBox(width: 6),
              SizedBox(
                width: 140,
                height: 34,
                child: FilledButton.icon(
                  onPressed: p.songs.isEmpty ? null : p.togglePlay,
                  icon: Icon(playing ? Icons.pause : Icons.play_arrow, size: 20),
                  label: Text(playing ? '一時停止' : (p.state == PlayState.paused || p.state == PlayState.handsOn ? '再開' : '再生')),
                ),
              ),
              const SizedBox(width: 6),
              _btn(Icons.skip_next, '次の曲（n / →）', p.songs.isEmpty ? null : p.next),
              _btn(Icons.replay, '頭から（r）', p.song == null ? null : p.restart),
              _btn(Icons.stop, '停止（s）', p.song == null ? null : () => p.stopAll()),
              const Spacer(),
              TextButton.icon(onPressed: onFolder, icon: const Icon(Icons.folder_open, size: 18), label: const Text('フォルダを開く')),
              TextButton.icon(onPressed: onFiles, icon: const Icon(Icons.audio_file, size: 18), label: const Text('曲を開く')),
              IconButton(onPressed: onSettings, tooltip: '設定', icon: const Icon(Icons.settings, size: 20)),
            ]),
            AnimatedBuilder(
              animation: p.frame,
              builder: (_, _) => _Seek(p: p),
            ),
            Row(children: [
              const SizedBox(width: 8),
              const Text('全体の音量', style: TextStyle(color: kSub)),
              Expanded(
                child: Slider(value: p.master.toDouble(), min: 0, max: 127, onChanged: (v) => p.setMaster(v.round())),
              ),
              SizedBox(width: 36, child: Text('${(p.master / 127 * 100).round()}%', style: const TextStyle(color: kSub))),
              TextButton(onPressed: p.hasTrims ? p.resetTrims : null, child: const Text('チャンネルの音量を戻す')),
            ]),
          ]),
        ),
      ]),
    );
  }

  Widget _lcd(String label, String value, {bool bad = false}) => Padding(
        padding: const EdgeInsets.only(right: 18),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Text('$label ', style: TextStyle(color: kLcd.withValues(alpha: .6), fontSize: 11)),
          Flexible(
            child: Text(value, maxLines: 1, overflow: TextOverflow.ellipsis,
                style: TextStyle(color: bad ? kBad : kLcd, fontSize: 15, fontWeight: FontWeight.w700, fontFeatures: const [FontFeature.tabularFigures()])),
          ),
        ]),
      );

  Widget _btn(IconData i, String tip, VoidCallback? f) => IconButton(onPressed: f, tooltip: tip, icon: Icon(i, size: 22), visualDensity: VisualDensity.compact);
}

class _Seek extends StatefulWidget {
  final Player p;
  const _Seek({required this.p});
  @override
  State<_Seek> createState() => _SeekState();
}

class _SeekState extends State<_Seek> {
  double? _drag;
  @override
  Widget build(BuildContext context) {
    final s = widget.p.song;
    final dur = math.max(1.0, s?.dur ?? 1);
    final v = (_drag ?? widget.p.songTime).clamp(0.0, dur);
    return Row(children: [
      SizedBox(width: 40, child: Text(fmtTime(v), textAlign: TextAlign.right, style: const TextStyle(color: kSub))),
      Expanded(
        child: Slider(
          value: v,
          max: dur,
          onChanged: s == null ? null : (x) => setState(() => _drag = x),
          onChangeEnd: s == null
              ? null
              : (x) {
                  widget.p.seekTo(x);
                  setState(() => _drag = null);
                },
        ),
      ),
      SizedBox(width: 40, child: Text(fmtTime(s?.dur ?? 0), style: const TextStyle(color: kSub))),
    ]);
  }
}

// ---------------- 中央: 16 チャンネル ----------------
// 列の幅
const double wCh = 70, wInst = 200, wLev = 64, wVol = 118, wMS = 28, wPan = 52, wExp = 52, wPb = 58, wSm = 40;

class ChannelTable extends StatelessWidget {
  final Player p;
  const ChannelTable({super.key, required this.p});
  @override
  Widget build(BuildContext context) {
    final used = p.song?.chans.toSet() ?? <int>{};
    return Column(children: [
      Container(
        height: 22,
        color: kPanel2,
        padding: const EdgeInsets.symmetric(horizontal: 6),
        child: const DefaultTextStyle(
          style: TextStyle(color: kSub, fontSize: 11, fontWeight: FontWeight.w600),
          child: Row(children: [
            SizedBox(width: wCh, child: Text('  CH')),
            SizedBox(width: wInst, child: Text('音色（本体 / GM）')),
            SizedBox(width: wLev, child: Text('レベル')),
            SizedBox(width: wVol, child: Text('音量（ドラッグ）')),
            SizedBox(width: wMS, child: Text('ソロ')),
            SizedBox(width: wPan, child: Text('パン')),
            SizedBox(width: wExp, child: Text('Exp')),
            SizedBox(width: wPb, child: Text('ベンド')),
            SizedBox(width: wSm, child: Text('Mod')),
            SizedBox(width: wSm, child: Text('Rev')),
            SizedBox(width: wSm, child: Text('Cho')),
            Expanded(child: Text('  鍵盤')),
          ]),
        ),
      ),
      for (int ch = 0; ch < 16; ++ch) Expanded(child: ChannelRow(p: p, ch: ch, used: used.contains(ch))),
    ]);
  }
}

class ChannelRow extends StatelessWidget {
  final Player p;
  final int ch;
  final bool used;
  const ChannelRow({super.key, required this.p, required this.ch, required this.used});

  @override
  Widget build(BuildContext context) => Container(
        decoration: BoxDecoration(color: ch.isEven ? kPanel : kBg, border: const Border(bottom: BorderSide(color: kLine, width: .5))),
        padding: const EdgeInsets.symmetric(horizontal: 6),
        child: Opacity(
          opacity: used ? 1 : 0.38,
          child: AnimatedBuilder(
            animation: p.frame,
            builder: (_, _) {
              final c = p.chans[ch];
              final drum = ch == 9;
              final inst = drum ? 'Drum Kit' : (c.progSet ? synthInstName(c.prog) : '（音色の指定前）');
              final gm = drum ? 'ドラム' : (c.progSet ? 'GM ${c.prog + 1} ${kGmNames[c.prog & 127]}' : '');
              final semi = c.bend / 8192 * c.range;
              return Row(children: [
                SizedBox(
                  width: wCh,
                  child: Row(children: [
                    _MuteButton(muted: p.mute[ch], silenced: p.effGain(ch) == 0, onTap: () => p.toggleMute(ch)),
                    const SizedBox(width: 6),
                    Container(width: 8, height: 8, decoration: BoxDecoration(color: kChColors[ch], borderRadius: BorderRadius.circular(2))),
                    const SizedBox(width: 5),
                    Text('${ch + 1}', style: const TextStyle(color: kSub, fontWeight: FontWeight.w700, fontFeatures: [FontFeature.tabularFigures()])),
                  ]),
                ),
                SizedBox(
                  width: wInst,
                  child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(inst, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontWeight: FontWeight.w700, color: c.progSet || drum ? kText : kSub)),
                    if (gm.isNotEmpty) Text(gm, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: kSub, fontSize: 10, height: 1.1)),
                  ]),
                ),
                SizedBox(width: wLev, child: _Bar(value: c.level, color: kGood)),
                SizedBox(width: wVol, child: _VolCell(p: p, ch: ch)),
                SizedBox(
                  width: wMS,
                  child: Align(alignment: Alignment.centerLeft, child: _Toggle('S', p.solo[ch], const Color(0xFFFFD43B), () => p.toggleSolo(ch))),
                ),
                SizedBox(width: wPan, child: _Bar(value: (c.pan - 64) / 64, center: true, color: kAccent)),
                SizedBox(width: wExp, child: _Bar(value: c.expr / 127, color: kAccent)),
                SizedBox(
                  width: wPb,
                  child: Stack(alignment: Alignment.center, children: [
                    _Bar(value: c.bend / 8192, center: true, color: const Color(0xFFFFA94D)),
                    if (semi.abs() >= 0.05)
                      Text('${semi > 0 ? '+' : ''}${semi.toStringAsFixed(1)}', style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: kText)),
                  ]),
                ),
                SizedBox(width: wSm, child: _Bar(value: c.mod / 127, color: const Color(0xFF9775FA))),
                SizedBox(width: wSm, child: _Bar(value: c.rev / 127, color: const Color(0xFF20C997))),
                SizedBox(width: wSm, child: _Bar(value: c.cho / 127, color: const Color(0xFF20C997))),
                const SizedBox(width: 6),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: CustomPaint(painter: KeyboardPainter(c.notes, kChColors[ch]), size: Size.infinite),
                  ),
                ),
              ]);
            },
          ),
        ),
      );
}

/// 横の棒（center = true なら中央から左右へ）
class _Bar extends StatelessWidget {
  final double value;
  final bool center;
  final Color color;
  const _Bar({required this.value, required this.color, this.center = false});
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(right: 8),
        child: SizedBox(height: 8, child: CustomPaint(painter: _BarPainter(value, center, color), size: Size.infinite)),
      );
}

class _BarPainter extends CustomPainter {
  final double v;
  final bool center;
  final Color color;
  _BarPainter(this.v, this.center, this.color);
  @override
  void paint(Canvas c, Size s) {
    final r = RRect.fromRectAndRadius(Offset.zero & s, const Radius.circular(2));
    c.drawRRect(r, Paint()..color = kPanel2);
    final p = Paint()..color = color;
    if (center) {
      final mid = s.width / 2, x = mid + v.clamp(-1.0, 1.0) * mid;
      c.drawRect(Rect.fromLTRB(math.min(mid, x), 0, math.max(mid, x) + (v.abs() < 0.02 ? 2 : 0), s.height), p);
      c.drawRect(Rect.fromLTWH(mid - .5, 0, 1, s.height), Paint()..color = kSub);
    } else {
      c.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(0, 0, s.width * v.clamp(0.0, 1.0), s.height), const Radius.circular(2)), p);
    }
  }

  @override
  bool shouldRepaint(_BarPainter o) => o.v != v || o.color != color;
}

/// 音量: 曲が送った音量 × このチャンネルの倍率。ドラッグで倍率（0〜150%）、ホイールで 5% ずつ、ダブルクリックで 100%
class _VolCell extends StatelessWidget {
  final Player p;
  final int ch;
  const _VolCell({required this.p, required this.ch});
  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, box) {
        final w = box.maxWidth - 8;
        void setFromX(double x) => p.setGain(ch, (x / w * 1.5).clamp(0.0, 1.5));
        final g = p.gain[ch], eff = p.effGain(ch), fileVol = p.chans[ch].vol / 127;
        return Listener(
          onPointerSignal: (e) {
            if (e is PointerScrollEvent) p.setGain(ch, g + (e.scrollDelta.dy < 0 ? 0.05 : -0.05));
          },
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (d) => setFromX(d.localPosition.dx),
            onHorizontalDragUpdate: (d) => setFromX(d.localPosition.dx),
            onDoubleTap: () => p.setGain(ch, 1.0),
            child: Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Stack(alignment: Alignment.centerLeft, children: [
                SizedBox(height: 16, child: CustomPaint(painter: _VolPainter(fileVol * eff / 1.5, g / 1.5, eff == 0), size: Size.infinite)),
                Padding(
                  padding: const EdgeInsets.only(left: 4),
                  child: Text('${(g * 100).round()}%',
                      style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: g == 1.0 ? kText : const Color(0xFFFFD43B), fontFeatures: const [FontFeature.tabularFigures()])),
                ),
              ]),
            ),
          ),
        );
      });
}

class _VolPainter extends CustomPainter {
  final double level, knob;
  final bool silent;
  _VolPainter(this.level, this.knob, this.silent);
  @override
  void paint(Canvas c, Size s) {
    c.drawRRect(RRect.fromRectAndRadius(Offset.zero & s, const Radius.circular(3)), Paint()..color = kPanel2);
    c.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(0, 0, s.width * level.clamp(0.0, 1.0), s.height), const Radius.circular(3)),
        Paint()..color = silent ? kBad.withValues(alpha: .35) : kAccent.withValues(alpha: .45));
    final x = s.width * (1 / 1.5); // 100% の位置
    c.drawRect(Rect.fromLTWH(x - .5, 0, 1, s.height), Paint()..color = kSub.withValues(alpha: .6));
    final k = s.width * knob.clamp(0.0, 1.0);
    c.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(k - 2, 0, 4, s.height), const Radius.circular(1)), Paint()..color = kText);
  }

  @override
  bool shouldRepaint(_VolPainter o) => o.level != level || o.knob != knob || o.silent != silent;
}

/// チャンネルのミュート。muted = このチャンネルをミュート、silenced = ほかのチャンネルのソロで鳴っていない
class _MuteButton extends StatelessWidget {
  final bool muted, silenced;
  final VoidCallback onTap;
  const _MuteButton({required this.muted, required this.silenced, required this.onTap});
  @override
  Widget build(BuildContext context) => Tooltip(
        message: muted ? 'ミュート中（クリックで戻す）' : (silenced ? 'ほかのチャンネルのソロで鳴っていない' : 'ミュート'),
        waitDuration: const Duration(milliseconds: 600),
        child: GestureDetector(
          onTap: onTap,
          child: Container(
            width: 26,
            height: 20,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: muted ? kBad : kPanel2,
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: muted ? kBad : kLine),
            ),
            child: CustomPaint(size: const Size(16, 14), painter: _SpeakerPainter(off: muted || silenced, color: muted ? Colors.white : (silenced ? kBad : kSub))),
          ),
        ),
      );
}

/// スピーカーの絵（off なら × 印、そうでなければ音の波）
class _SpeakerPainter extends CustomPainter {
  final bool off;
  final Color color;
  _SpeakerPainter({required this.off, required this.color});
  @override
  void paint(Canvas c, Size s) {
    final fill = Paint()..color = color;
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4
      ..strokeCap = StrokeCap.round;
    final h = s.height, cy = h / 2;
    c.drawPath(
        Path()
          ..moveTo(1, cy - h * .18)
          ..lineTo(4, cy - h * .18)
          ..lineTo(8, cy - h * .42)
          ..lineTo(8, cy + h * .42)
          ..lineTo(4, cy + h * .18)
          ..lineTo(1, cy + h * .18)
          ..close(),
        fill);
    if (off) {
      c.drawLine(Offset(10.5, cy - 3), Offset(15, cy + 3), stroke);
      c.drawLine(Offset(15, cy - 3), Offset(10.5, cy + 3), stroke);
    } else {
      c.drawArc(Rect.fromCircle(center: Offset(8, cy), radius: 3.5), -0.9, 1.8, false, stroke);
      c.drawArc(Rect.fromCircle(center: Offset(8, cy), radius: 6.5), -0.9, 1.8, false, stroke);
    }
  }

  @override
  bool shouldRepaint(_SpeakerPainter o) => o.off != off || o.color != color;
}

class _Toggle extends StatelessWidget {
  final String label;
  final bool on;
  final Color color;
  final VoidCallback onTap;
  const _Toggle(this.label, this.on, this.color, this.onTap);
  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: onTap,
        child: Container(
          width: 18,
          height: 16,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: on ? color : kPanel2,
            borderRadius: BorderRadius.circular(3),
            border: Border.all(color: on ? color : kLine),
          ),
          child: Text(label, style: TextStyle(fontSize: 10, fontWeight: FontWeight.w800, color: on ? Colors.black : kSub)),
        ),
      );
}

/// 88 鍵（A0〜C8）。押さえている鍵盤をチャンネルの色で（強く弾いた音ほど濃く）。範囲外の音は端に寄せる
class KeyboardPainter extends CustomPainter {
  final Map<int, int> notes;
  final Color color;
  KeyboardPainter(Map<int, int> n, this.color) : notes = Map.of(n);
  static const lo = 21, hi = 108;
  static bool _black(int n) => const [1, 3, 6, 8, 10].contains(n % 12);
  static final List<int> _whites = [for (int n = lo; n <= hi; ++n) if (!_black(n)) n];

  @override
  void paint(Canvas c, Size s) {
    final on = <int, int>{};
    notes.forEach((n, v) => on[n.clamp(lo, hi)] = v);
    final ww = s.width / _whites.length;
    final white = Paint()..color = const Color(0xFFE9ECF2), black = Paint()..color = const Color(0xFF262A33), line = Paint()..color = const Color(0xFF8A93A6);
    Paint lit(int v) => Paint()..color = color.withValues(alpha: .45 + .55 * v / 127);
    for (int k = 0; k < _whites.length; ++k) {
      final n = _whites[k], r = Rect.fromLTWH(k * ww, 0, ww, s.height);
      c.drawRect(r, white);
      final v = on[n];
      if (v != null) c.drawRect(r, lit(v));
      c.drawRect(Rect.fromLTWH(k * ww, 0, .6, s.height), line);
    }
    int k = 0;
    for (int n = lo; n <= hi; ++n) {
      if (!_black(n)) {
        ++k;
        continue;
      }
      final r = Rect.fromLTWH(k * ww - ww * .32, 0, ww * .64, s.height * .6);
      c.drawRect(r, black);
      final v = on[n];
      if (v != null) c.drawRect(r, lit(v));
    }
    // C の位置（オクターブの目印）
    if (ww > 5 && s.height > 18) {
      for (int i = 0; i < _whites.length; ++i) {
        if (_whites[i] % 12 != 0) continue;
        final tp = TextPainter(text: TextSpan(text: 'C${_whites[i] ~/ 12 - 1}', style: const TextStyle(fontSize: 8, color: Color(0xFF8A93A6))), textDirection: TextDirection.ltr)..layout();
        tp.paint(c, Offset(i * ww + 1.5, s.height - tp.height));
      }
    }
  }

  @override
  bool shouldRepaint(KeyboardPainter o) => o.color != color || o.notes.length != notes.length || o.notes.entries.any((e) => notes[e.key] != e.value);
}

// ---------------- プレイリストのタブ: 並べ替え・曲の追加・削除・保存 ----------------
class PlaylistTab extends StatelessWidget {
  final Player p;
  final VoidCallback onAddFiles, onFolder, onOpenList, onSaveAs, refocus;
  const PlaylistTab({super.key, required this.p, required this.onAddFiles, required this.onFolder, required this.onOpenList, required this.onSaveAs, required this.refocus});

  @override
  Widget build(BuildContext context) {
    final file = p.playlistFile.isEmpty ? '（まだ保存していません）' : p.playlistFile;
    return Container(
      color: kBg,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        // 操作
        Container(
          color: kPanel,
          padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
          child: Wrap(spacing: 6, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
            FilledButton.tonalIcon(onPressed: onAddFiles, icon: const Icon(Icons.add, size: 18), label: const Text('曲を追加')),
            const SizedBox(width: 12),
            OutlinedButton.icon(onPressed: onFolder, icon: const Icon(Icons.folder_open, size: 18), label: const Text('フォルダを開く')),
            OutlinedButton.icon(onPressed: onOpenList, icon: const Icon(Icons.file_open_outlined, size: 18), label: const Text('プレイリストを開く')),
            OutlinedButton.icon(
              onPressed: () async {
                if (p.dirty && p.rows.isNotEmpty) {
                  final ok = await showDialog<bool>(
                    context: context,
                    builder: (c) => AlertDialog(
                      content: const Text('保存していない変更があります。新しいプレイリストにしますか？'),
                      actions: [
                        TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('やめる')),
                        FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('新しくする')),
                      ],
                    ),
                  );
                  refocus();
                  if (ok != true) return;
                }
                await p.newPlaylist();
              },
              icon: const Icon(Icons.note_add_outlined, size: 18),
              label: const Text('新規'),
            ),
            const SizedBox(width: 12),
            FilledButton.icon(
              onPressed: p.playlistFile.isEmpty ? onSaveAs : (p.dirty ? () => p.savePlaylist() : null),
              icon: const Icon(Icons.save, size: 18),
              label: const Text('保存'),
            ),
            OutlinedButton.icon(onPressed: onSaveAs, icon: const Icon(Icons.save_as_outlined, size: 18), label: const Text('名前を付けて保存')),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 12, 4),
          child: Row(children: [
            Expanded(child: Text('保存先: $file${p.dirty ? '（未保存の変更あり）' : ''}', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: p.dirty ? const Color(0xFFFFD43B) : kSub, fontSize: 11))),
            Text('${p.songs.length} 曲・1 周 約 ${(p.totalSec / 60).round()} 分　${p.repeat ? '最後まで行ったら最初から' : '最後まで行ったら止める'}', style: const TextStyle(color: kSub, fontSize: 11)),
          ]),
        ),
        // 行（ドラッグで並べ替え）
        Expanded(
          child: p.rows.isEmpty
              ? const Center(child: Text('「曲を追加」か「フォルダを開く」で曲を入れてください', style: TextStyle(color: kSub)))
              : ReorderableListView.builder(
                  buildDefaultDragHandles: false,
                  padding: const EdgeInsets.only(bottom: 12),
                  itemCount: p.rows.length,
                  onReorderItem: p.moveRow,
                  itemBuilder: (context, i) {
                    final r = p.rows[i];
                    final handle = ReorderableDragStartListener(
                      index: i,
                      child: const MouseRegion(cursor: SystemMouseCursors.grab, child: Padding(padding: EdgeInsets.symmetric(horizontal: 8), child: Icon(Icons.drag_indicator, size: 18, color: kSub))),
                    );
                    final s = r.song!, n = p.songs.indexOf(s), curr = n == p.cur;
                    return Container(
                      key: ObjectKey(r),
                      margin: const EdgeInsets.symmetric(horizontal: 8),
                      height: 30,
                      decoration: BoxDecoration(color: curr ? kAccent.withValues(alpha: .22) : (n.isEven ? kPanel : kBg), borderRadius: BorderRadius.circular(4)),
                      child: GestureDetector(
                        onDoubleTap: () => p.playRow(i),
                        child: Row(children: [
                          handle,
                          SizedBox(width: 28, child: Text('${n + 1}', textAlign: TextAlign.right, style: const TextStyle(color: kSub, fontFeatures: [FontFeature.tabularFigures()]))),
                          IconButton(
                            tooltip: 'この曲を再生（ダブルクリックでも）',
                            visualDensity: VisualDensity.compact,
                            icon: Icon(curr && p.state == PlayState.playing ? Icons.graphic_eq : Icons.play_arrow, size: 18, color: curr ? kAccent : kSub),
                            onPressed: () => p.playRow(i),
                          ),
                          SizedBox(
                            width: 280,
                            child: Text(s.name + (s.err != null ? '（読めない）' : ''),
                                maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontWeight: curr ? FontWeight.w700 : FontWeight.w500, fontSize: 13, color: s.err != null ? kBad : kText)),
                          ),
                          SizedBox(width: 50, child: Text(fmtTime(s.dur), style: const TextStyle(color: kSub, fontFeatures: [FontFeature.tabularFigures()]))),
                          Expanded(child: Text(s.path, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Color(0xFF6B7385), fontSize: 11))),
                          IconButton(tooltip: 'プレイリストから外す（ファイルは消さない）', visualDensity: VisualDensity.compact, icon: const Icon(Icons.close, size: 16, color: kSub), onPressed: () => p.removeRow(i)),
                        ]),
                      ),
                    );
                  },
                ),
        ),
      ]),
    );
  }
}

// ---------------- 下: ステータス ----------------
class StatusBar extends StatelessWidget {
  final Player p;
  final VoidCallback onLog;
  const StatusBar({super.key, required this.p, required this.onLog});
  @override
  Widget build(BuildContext context) => Container(
        height: 24,
        color: kPanel2,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        child: Row(children: [
          Expanded(child: Text(p.logs.isEmpty ? '' : p.logs.first, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: kSub, fontSize: 11))),
          const Text('Space 一時停止/再開　n/→ 次　b/← 前　r 頭から　s 停止　', style: TextStyle(color: kSub, fontSize: 11)),
          InkWell(onTap: onLog, child: const Text('ログ', style: TextStyle(color: kAccent, fontSize: 11))),
        ]),
      );
}

// ---------------- 設定 ----------------
class SettingsDialog extends StatefulWidget {
  final Player p;
  final List<String> ports;
  const SettingsDialog({super.key, required this.p, required this.ports});
  @override
  State<SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends State<SettingsDialog> {
  @override
  Widget build(BuildContext context) {
    final p = widget.p;
    final items = <String>{'', ...widget.ports, if (p.portWanted.isNotEmpty) p.portWanted};
    return AlertDialog(
      title: const Text('設定'),
      content: SizedBox(
        width: 460,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Row(children: [
            const Expanded(child: Text('出力先')),
            DropdownButton<String>(
              value: p.portWanted,
              items: [
                for (final n in items)
                  DropdownMenuItem(value: n, child: Text(n.isEmpty ? '自動（$kDefaultPort）' : (widget.ports.contains(n) ? n : '$n（見つからない）'))),
              ],
              onChanged: (v) => setState(() => p.setPortWanted(v ?? '')),
            ),
          ]),
          Row(children: [
            const Expanded(child: Text('曲間（秒）')),
            SizedBox(
              width: 200,
              child: Slider(
                value: p.gapSec,
                min: 0,
                max: 10,
                divisions: 20,
                label: p.gapSec.toStringAsFixed(1),
                onChanged: (v) => setState(() {
                  p.gapSec = v;
                  p.saveSettings();
                }),
              ),
            ),
            SizedBox(width: 36, child: Text(p.gapSec.toStringAsFixed(1))),
          ]),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('最後まで行ったら最初から繰り返す'),
            value: p.repeat,
            onChanged: (v) => setState(() {
              p.repeat = v;
              p.saveSettings();
            }),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('起動したら前のフォルダを自動で再生する'),
            value: p.autoplay,
            onChanged: (v) => setState(() {
              p.autoplay = v;
              p.saveSettings();
            }),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('本体の鍵盤を押したら止める'),
            subtitle: Text(p.dryRun ? '（送らないモードでは働きません）' : (p.connected && p.out.inName == null ? '本体からの入力が見つかりません' : '鍵盤を押すと止まります（スティック・ペダルでは止まりません）'),
                style: const TextStyle(color: kSub, fontSize: 12)),
            value: p.yieldOnTouch,
            onChanged: (v) => setState(() {
              p.yieldOnTouch = v;
              p.saveSettings();
            }),
          ),
          Row(children: [
            const Expanded(child: Text('操作が終わってから次の曲を始めるまで')),
            DropdownButton<double>(
              value: const [10.0, 20.0, 30.0, 60.0, 120.0, 300.0, 0.0].contains(p.yieldResumeSec) ? p.yieldResumeSec : 30.0,
              items: [
                for (final s in const [10.0, 20.0, 30.0, 60.0, 120.0, 300.0, 0.0])
                  DropdownMenuItem(value: s, child: Text(s == 0 ? '自動では始めない' : (s < 60 ? '${s.round()} 秒' : '${(s / 60).round()} 分'))),
              ],
              onChanged: p.yieldOnTouch
                  ? (v) => setState(() {
                        p.yieldResumeSec = v ?? 30;
                        p.saveSettings();
                      })
                  : null,
            ),
          ]),
          Align(alignment: Alignment.centerLeft, child: Text('フォルダ:${p.folder.isEmpty ? '（未選択）' : p.folder}', style: const TextStyle(color: kSub, fontSize: 12))),
        ]),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('閉じる'))],
    );
  }
}
