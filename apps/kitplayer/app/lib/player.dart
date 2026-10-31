// 再生エンジン: プレイリスト、送る時刻の管理、一時停止・シークのときの状態の送り直し、
// チャンネルごとの音量（倍率・ミュート・ソロ）、表示用のチャンネルの状態
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'midi_out.dart';
import 'smf.dart';

const String kDefaultPort = 'TinyKeyboard';

class SongEntry {
  final String name, path;
  String section; // 属している枠の名前
  double dur = 0;
  String? err;
  SongEntry(this.name, this.path, this.section);
}

/// プレイリストの 1 行: 枠の見出し（song == null）か曲
class PlRow {
  String section;
  final SongEntry? song;
  PlRow.section(this.section) : song = null;
  PlRow.song(SongEntry s)
      : song = s,
        section = '';
}

// handsOn = 本体の鍵盤などが操作されたので止めている（操作が終わってしばらくたつと次の曲から再生）
enum PlayState { idle, loading, playing, paused, stopped, gap, waiting, handsOn }

/// 表示用のチャンネルの状態（実際に鳴っている時刻に合わせて更新）
class ChanView {
  int prog = 0;
  bool progSet = false;
  int vol = 100, expr = 127, pan = 64, mod = 0, rev = 0, cho = 0;
  int bend = 0, range = 2, rpnM = 127, rpnL = 127;
  final Map<int, int> notes = {};
  double level = 0; // 0..1（音を弾いたときに上がって、だんだん下がる）
}

class Player extends ChangeNotifier {
  Player({this.dryRun = false}) : out = MidiOut.create(dry: dryRun) {
    out.onError = () {
      log('送れませんでした');
      _lost();
    };
    out.onInput = onDeviceInput;
  }
  final bool dryRun;
  final MidiOut out;

  // ---------------- 設定（保存する） ----------------
  String folder = '';
  String portWanted = ''; // '' = 自動
  double gapSec = 2;
  bool repeat = true;
  bool autoplay = false;
  int master = 127; // 全体の音量（本体のマスターボリューム）
  bool yieldOnTouch = true; // 本体の鍵盤を押したら止める
  double yieldResumeSec = 30; // 操作が終わってから次の曲を始めるまで（0 = 自動では始めない）
  final Map<String, Map<String, dynamic>> _songTrims = {}; // 曲ごとのチャンネルの音量

  // ---------------- 状態 ----------------
  List<SongEntry> songs = [];
  int cur = -1;
  Song? song;
  PlayState state = PlayState.idle;
  double _songStart = 0, pausePos = 0, _gapUntil = 0, _quietUntil = 0;
  int _sendIdx = 0, _visIdx = 0, _loadToken = 0;
  bool connected = false;
  String? portName;
  int quality = -1; // 本体の音質モード（-1 = 不明）
  final List<String> logs = [];
  final List<ChanView> chans = List.generate(16, (_) => ChanView());

  // チャンネルごとの音量: 倍率（0〜1.5）、ミュート、ソロ
  final List<double> gain = List.filled(16, 1.0);
  final List<bool> mute = List.filled(16, false), solo = List.filled(16, false);
  final List<int> _fileVol = List.filled(16, 100); // 曲が送った CC7（送る側の時刻での値）

  /// 毎フレーム知らせる（鍵盤・メーター用。ウィジェットの作り直しはしない）
  final FrameNotifier frame = FrameNotifier();
  Timer? _ticker, _portPoll;

  // ---------------- 起動・設定の保存 ----------------
  Future<File> _settingsFile() async {
    final d = await getApplicationSupportDirectory();
    await d.create(recursive: true);
    return File('${d.path}${Platform.pathSeparator}kitplayer_settings.json');
  }

  Future<void> init({String? folderArg, bool? autoplayArg}) async {
    try {
      final f = await _settingsFile();
      if (await f.exists()) {
        final j = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
        folder = j['folder'] ?? '';
        playlistFile = j['playlist'] ?? '';
        portWanted = j['port'] ?? '';
        gapSec = (j['gap'] ?? 2).toDouble();
        repeat = j['repeat'] ?? true;
        autoplay = j['autoplay'] ?? false;
        master = j['master'] ?? 127;
        yieldOnTouch = j['yield'] ?? true;
        yieldResumeSec = (j['yieldSec'] ?? 30).toDouble();
        (j['trims'] as Map<String, dynamic>? ?? {}).forEach((k, v) => _songTrims[k] = Map<String, dynamic>.from(v));
      }
    } catch (_) {}
    if (folderArg != null) {
      folder = folderArg;
      playlistFile = '';
    }
    if (autoplayArg != null) autoplay = autoplayArg;
    _ticker = Timer.periodic(const Duration(milliseconds: 1), (_) => _tick());
    _portPoll = Timer.periodic(const Duration(seconds: 1), (_) => checkPort());
    await checkPort(first: true);
    // 前回のプレイリスト（無ければフォルダ）を開く
    if (playlistFile.isNotEmpty && File(playlistFile).existsSync()) {
      await loadPlaylistFile(playlistFile);
    } else if (folder.isNotEmpty && Directory(folder).existsSync()) {
      await loadFolder(folder);
    } else {
      log('「フォルダを開く」で「最適化後」フォルダを選ぶか、「曲を開く」で曲を選んでください');
    }
    if (autoplay && songs.isNotEmpty) startSong(0);
  }

  Future<void> saveSettings() async {
    try {
      final f = await _settingsFile();
      await f.writeAsString(jsonEncode({
        'folder': folder, 'playlist': playlistFile, 'port': portWanted, 'gap': gapSec, 'repeat': repeat, 'autoplay': autoplay, 'master': master,
        'yield': yieldOnTouch, 'yieldSec': yieldResumeSec, 'trims': _songTrims,
      }));
    } catch (_) {}
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _portPoll?.cancel();
    allNotesOff();
    out.close();
    KeepAwake.off();
    super.dispose();
  }

  void log(String m) {
    final t = DateTime.now();
    String p(int n) => n.toString().padLeft(2, '0');
    logs.insert(0, '${p(t.hour)}:${p(t.minute)}:${p(t.second)}  $m');
    if (logs.length > 300) logs.removeLast();
    notifyListeners();
  }

  // ---------------- プレイリスト ----------------
  // 行の並び（枠の見出し / 曲）。songs は曲の行だけを並べたもの（枠の名前付き）
  final List<PlRow> rows = [];
  String playlistFile = ''; // 保存先（'' = まだ無い）
  bool dirty = false; // 保存していない変更がある
  SongEntry? _curEntry; // 再生中の曲（並べ替えても追いかける）
  String? get curName => _curEntry?.name;

  static String _songName(String path) => path.split(RegExp(r'[\\/]')).last.replaceFirst(RegExp(r'\.midi?$', caseSensitive: false), '');
  static bool _isAbs(String p) => p.startsWith('/') || p.startsWith(r'\\') || RegExp(r'^[A-Za-z]:[\\/]').hasMatch(p);
  static String _dirOf(String p) {
    final i = p.lastIndexOf(RegExp(r'[\\/]'));
    return i < 0 ? '.' : p.substring(0, i);
  }

  /// rows から songs を作り直す（枠の名前を付け、再生中の曲の番号を追いかける）
  void _rebuildSongs() {
    final list = <SongEntry>[];
    String section = '';
    for (final r in rows) {
      if (r.song == null) {
        section = r.section;
      } else {
        r.song!.section = section;
        list.add(r.song!);
      }
    }
    songs = list;
    cur = _curEntry == null ? -1 : songs.indexOf(_curEntry!);
  }

  Future<void> _measure(Iterable<SongEntry> list) async {
    for (final s in list) {
      try {
        s.dur = parseSmf(await File(s.path).readAsBytes()).dur;
        s.err = null;
      } catch (e) {
        s.err = '$e';
      }
    }
  }

  Future<void> _setRows(List<PlRow> list, String file) async {
    stopAll(to: PlayState.idle);
    rows
      ..clear()
      ..addAll(list);
    playlistFile = file;
    dirty = false;
    _curEntry = null;
    song = null;
    _rebuildSongs();
    await _measure(songs);
    await saveSettings();
    notifyListeners();
  }

  /// フォルダを開く: playlist.txt があればその順番、無ければ中の .mid を名前順
  Future<void> loadFolder(String dir) async {
    folder = dir;
    final sep = Platform.pathSeparator;
    final pl = '$dir${sep}playlist.txt';
    if (File(pl).existsSync()) return loadPlaylistFile(pl);
    final paths = <String>[];
    await for (final e in Directory(dir).list(recursive: true, followLinks: false)) {
      if (e is File && RegExp(r'\.midi?$', caseSensitive: false).hasMatch(e.path)) paths.add(e.path);
    }
    paths.sort();
    log('playlist.txt が無いので名前順で ${paths.length} 曲');
    await _setRows([for (final p in paths) PlRow.song(SongEntry(_songName(p), p, ''))], pl);
    dirty = true;
    notifyListeners();
  }

  /// プレイリストのファイルを開く。1 行に 1 曲（ファイルからの相対パス、または絶対パス）。# から後はコメント
  Future<void> loadPlaylistFile(String file) async {
    final base = _dirOf(file), sep = Platform.pathSeparator;
    final mids = <String, String>{}; // 相対パス（/ 区切り）→ フルパス
    try {
      await for (final e in Directory(base).list(recursive: true, followLinks: false)) {
        if (e is File && RegExp(r'\.midi?$', caseSensitive: false).hasMatch(e.path)) mids[e.path.substring(base.length + 1).replaceAll(sep, '/')] = e.path;
      }
    } catch (_) {}
    final list = <PlRow>[];
    String text;
    try {
      text = await File(file).readAsString();
    } catch (e) {
      log('プレイリストを開けません: $file');
      return;
    }
    for (var line in const LineSplitter().convert(text.replaceFirst('﻿', ''))) {
      line = line.replaceFirst(RegExp(r'#.*'), '').trim();
      if (line.isEmpty) continue;
      String? path;
      if (_isAbs(line)) {
        if (File(line).existsSync()) path = line;
      } else {
        path = mids[line] ?? mids.entries.where((m) => _same(m.key, line)).map((m) => m.value).firstOrNull;
      }
      if (path == null) {
        log('プレイリストの曲が見つかりません: $line');
        continue;
      }
      list.add(PlRow.song(SongEntry(_songName(path), path, '')));
    }
    folder = base;
    await _setRows(list, file);
    log('${file.split(RegExp(r'[\\/]')).last} を開きました（${songs.length} 曲）');
  }

  /// プレイリストを保存する（file を省くと今の保存先）
  Future<bool> savePlaylist([String? file]) async {
    file ??= playlistFile;
    if (file.isEmpty) return false;
    final base = _dirOf(file), sep = Platform.pathSeparator;
    final b = StringBuffer('# kitplayer のプレイリスト（1 行に 1 曲。# から後はコメント）\n');
    for (final r in rows) {
      if (r.song == null) continue;
      final p = r.song!.path;
      b.write(p.startsWith('$base$sep') ? '${p.substring(base.length + 1).replaceAll(sep, '/')}\n' : '$p\n');
    }
    try {
      await File(file).writeAsString(b.toString());
    } catch (e) {
      log('保存できませんでした: $file');
      return false;
    }
    playlistFile = file;
    dirty = false;
    await saveSettings();
    log('保存しました: $file');
    notifyListeners();
    return true;
  }

  /// 新しい（空の）プレイリスト
  Future<void> newPlaylist() async {
    await _setRows([], '');
    dirty = false;
    notifyListeners();
  }

  void _edited() {
    dirty = true;
    _rebuildSongs();
    notifyListeners();
  }

  /// 曲を足す（at を省くと最後）。play なら足した最初の曲を再生
  Future<void> addFiles(List<String> paths, {int? at, bool play = false}) async {
    final added = [for (final p in paths) SongEntry(_songName(p), p, '')];
    await _measure(added);
    rows.insertAll(at ?? rows.length, [for (final s in added) PlRow.song(s)]);
    _edited();
    log('${added.length} 曲を足しました');
    if (play && added.isNotEmpty) startSong(songs.indexOf(added.first));
  }

  void removeRow(int row) {
    rows.removeAt(row);
    _edited();
  }

  void moveRow(int from, int to) {
    final r = rows.removeAt(from);
    rows.insert(to, r);
    _edited();
  }

  void playRow(int row) {
    final s = rows[row].song;
    if (s != null) startSong(songs.indexOf(s));
  }

  // Mac のファイル名は濁点が分かれている（NFD）ことがあるので、比べるときにそろえる
  static String _fold(String s) {
    const pairs = {'か': 'が', 'き': 'ぎ', 'く': 'ぐ', 'け': 'げ', 'こ': 'ご', 'さ': 'ざ', 'し': 'じ', 'す': 'ず', 'せ': 'ぜ', 'そ': 'ぞ', 'た': 'だ', 'ち': 'ぢ', 'つ': 'づ', 'て': 'で', 'と': 'ど', 'は': 'ば', 'ひ': 'び', 'ふ': 'ぶ', 'へ': 'べ', 'ほ': 'ぼ', 'カ': 'ガ', 'キ': 'ギ', 'ク': 'グ', 'ケ': 'ゲ', 'コ': 'ゴ', 'サ': 'ザ', 'シ': 'ジ', 'ス': 'ズ', 'セ': 'ゼ', 'ソ': 'ゾ', 'タ': 'ダ', 'チ': 'ヂ', 'ツ': 'ヅ', 'テ': 'デ', 'ト': 'ド', 'ハ': 'バ', 'ヒ': 'ビ', 'フ': 'ブ', 'ヘ': 'ベ', 'ホ': 'ボ', 'ウ': 'ヴ'};
    const handaku = {'は': 'ぱ', 'ひ': 'ぴ', 'ふ': 'ぷ', 'へ': 'ぺ', 'ほ': 'ぽ', 'ハ': 'パ', 'ヒ': 'ピ', 'フ': 'プ', 'ヘ': 'ペ', 'ホ': 'ポ'};
    final b = StringBuffer();
    final r = s.runes.toList();
    for (int i = 0; i < r.length; ++i) {
      final c = String.fromCharCode(r[i]);
      if (i + 1 < r.length && r[i + 1] == 0x3099 && pairs.containsKey(c)) {
        b.write(pairs[c]);
        ++i;
      } else if (i + 1 < r.length && r[i + 1] == 0x309A && handaku.containsKey(c)) {
        b.write(handaku[c]);
        ++i;
      } else {
        b.write(c);
      }
    }
    return b.toString();
  }

  static bool _same(String a, String b) => _fold(a) == _fold(b);

  double get totalSec => songs.fold(0.0, (a, s) => a + s.dur) + songs.length * gapSec;

  // ---------------- MIDI 出力 ----------------
  Future<String?> _pickPort() async {
    final ps = await out.ports();
    if (portWanted.isNotEmpty) return ps.contains(portWanted) ? portWanted : null;
    for (final p in ps) {
      if (p.contains(kDefaultPort)) return p;
    }
    final hw = ps.where((p) => !isSoftPort(p)).toList();
    return hw.length == 1 ? hw.first : null;
  }

  Future<List<String>> listPorts() => out.ports();
  bool _reconnecting = false;

  Future<void> checkPort({bool first = false}) async {
    if (dryRun) {
      if (!connected) {
        connected = true;
        portName = '（送らない）';
        notifyListeners();
      }
      return;
    }
    final want = await _pickPort();
    if (connected && (want == null || want != portName)) _lost();
    if (!connected && want != null && !_reconnecting) {
      _reconnecting = true;
      if (!first) await Future.delayed(const Duration(seconds: 2)); // 本体の起動を待つ
      final again = await _pickPort();
      if (again != null && await out.open(again)) {
        connected = true;
        portName = again;
        log(first ? '出力: $again' : 'つなぎ直しました: $again');
        log(out.inName == null ? '本体からの入力が見つからないので、鍵盤を押しても止まりません' : '入力: ${out.inName}（鍵盤を押したら止めます）');
        _sendMaster();
        if (state == PlayState.waiting) startSong(cur);
      }
      _reconnecting = false;
      notifyListeners();
    }
  }

  void _lost() {
    if (!connected) return;
    connected = false;
    out.close();
    portName = null;
    log('本体が見つからない / 抜けた');
    if (state == PlayState.playing || state == PlayState.gap) {
      state = PlayState.waiting;
      _clearNotes();
    }
    notifyListeners();
  }

  void setPortWanted(String p) {
    portWanted = p;
    saveSettings();
    if (connected) {
      allNotesOff();
      out.close();
      connected = false;
    }
    checkPort(first: true);
  }

  // 音量: ミュート・ソロ・倍率をかけた CC7
  double effGain(int ch) {
    if (mute[ch]) return 0;
    if (solo.contains(true) && !solo[ch]) return 0;
    return gain[ch];
  }

  int _effVol(int ch, int v) => (v * effGain(ch)).round().clamp(0, 127);

  void _send(Uint8List d, double atMs) {
    if (!connected) return;
    if (d[0] < 0x80) return; // 続きだけの F7 など
    if (d[0] == 0xF0 && d.last != 0xF7) return;
    var x = d;
    if ((d[0] & 0xF0) == 0xB0 && d.length > 2 && d[1] == 7) {
      final ch = d[0] & 15;
      _fileVol[ch] = d[2];
      x = Uint8List.fromList([d[0], 7, _effVol(ch, d[2])]);
    } else if (isGmReset(d)) {
      _fileVol.fillRange(0, 16, 100);
    }
    out.send(x, atMs);
  }

  void _sendNow(List<int> d, [double? at]) => _send(Uint8List.fromList(d), at ?? nowMs());

  /// 鳴っている音を全部止める。予約してある分は取り消す（取り消せない出力では、予約の分が出きったあとにもう一度止める）
  void allNotesOff() {
    out.flushPending();
    final now = nowMs(), again = !out.canFlush && out.lookaheadMs > 0 ? now + out.lookaheadMs + 20 : 0.0;
    for (int ch = 0; ch < 16; ++ch) {
      for (final m in [
        [0xB0 | ch, 64, 0], [0xB0 | ch, 123, 0], [0xB0 | ch, 120, 0]
      ]) {
        _sendNow(m, now);
        if (again > 0) _sendNow(m, again);
      }
    }
    _quietUntil = math.max(now, again) + 10;
  }

  double _quietTime() => math.max(nowMs(), _quietUntil);

  // 本体が操作されている間は最大、それ以外は設定した音量
  int masterSent = -1; // 最後に本体へ送った全体の音量（0〜127。確認用）
  void _sendMaster([double? at]) {
    masterSent = state == PlayState.handsOn ? 127 : master;
    final v = (masterSent * 16383 / 127).round();
    _sendNow([0xF0, 0x7F, 0x7F, 0x04, 0x01, v & 127, v >> 7, 0xF7], at);
  }

  void setMaster(int v) {
    master = v.clamp(0, 127);
    _sendMaster();
    notifyListeners();
  }

  // ---------------- チャンネルの音量 ----------------
  void setGain(int ch, double g) {
    gain[ch] = (g * 20).round() / 20.0;
    gain[ch] = gain[ch].clamp(0.0, 1.5);
    _applyVol(ch);
    _rememberTrims();
  }

  void toggleMute(int ch) {
    mute[ch] = !mute[ch];
    for (int c = 0; c < 16; ++c) {
      _applyVol(c);
    }
    _rememberTrims();
  }

  void toggleSolo(int ch) {
    solo[ch] = !solo[ch];
    for (int c = 0; c < 16; ++c) {
      _applyVol(c);
    }
    _rememberTrims();
  }

  void resetTrims() {
    gain.fillRange(0, 16, 1.0);
    mute.fillRange(0, 16, false);
    solo.fillRange(0, 16, false);
    for (int c = 0; c < 16; ++c) {
      _applyVol(c);
    }
    _rememberTrims();
  }

  void _applyVol(int ch) {
    if (state == PlayState.playing || state == PlayState.paused) _sendNow([0xB0 | ch, 7, _fileVol[ch]]);
    notifyListeners();
  }

  void _rememberTrims() {
    if (cur < 0 || cur >= songs.length) return;
    final key = songs[cur].name;
    final plain = gain.every((g) => g == 1.0) && !mute.contains(true) && !solo.contains(true);
    if (plain) {
      _songTrims.remove(key);
    } else {
      _songTrims[key] = {'gain': gain.toList(), 'mute': mute.toList(), 'solo': solo.toList()};
    }
    saveSettings();
  }

  void _loadTrims() {
    final t = cur >= 0 ? _songTrims[songs[cur].name] : null;
    for (int c = 0; c < 16; ++c) {
      gain[c] = t == null ? 1.0 : (t['gain'][c] as num).toDouble();
      mute[c] = t == null ? false : t['mute'][c] as bool;
      solo[c] = t == null ? false : t['solo'][c] as bool;
    }
  }

  bool get hasTrims => gain.any((g) => g != 1.0) || mute.contains(true) || solo.contains(true);

  // ---------------- 再生 ----------------
  double get songTime => state == PlayState.playing ? (nowMs() - _songStart) / 1000 : pausePos;

  Future<void> startSong(int i) async {
    if (songs.isEmpty) return;
    i = ((i % songs.length) + songs.length) % songs.length;
    allNotesOff();
    cur = i;
    _curEntry = songs[i];
    state = PlayState.loading; // 読み込み中は曲間の「次へ」を重ねて呼ばない
    final token = ++_loadToken;
    notifyListeners();
    Song loaded;
    try {
      loaded = parseSmf(await File(songs[i].path).readAsBytes());
    } catch (e) {
      if (token != _loadToken) return;
      log('読めません: ${songs[i].name}（$e）飛ばします');
      song = null;
      state = PlayState.gap;
      _gapUntil = nowMs() + 500;
      return;
    }
    if (token != _loadToken) return; // 読み込み中に別の曲が選ばれた
    song = loaded;
    _loadTrims();
    _resetView();
    if (!connected) {
      state = PlayState.waiting;
      notifyListeners();
      return;
    }
    final t0 = _quietTime();
    _sendNow([0xF0, 0x7E, 0x7F, 0x09, 0x01, 0xF7], t0); // GM リセット
    for (int ch = 0; ch < 16; ++ch) {
      _sendNow([0xB0 | ch, 7, 100], t0 + 1); // 曲が音量を送らないチャンネルにも倍率をかける
    }
    _sendMaster(t0 + 2);
    _sendIdx = 0;
    _visIdx = 0;
    _songStart = t0 + 300; // GM リセットのあと少し待つ
    state = PlayState.playing;
    KeepAwake.on();
    log('再生: ${songs[i].name}');
    notifyListeners();
  }

  void pause() {
    if (state != PlayState.playing || song == null) return;
    pausePos = math.max(0, songTime);
    state = PlayState.paused;
    allNotesOff();
    _sendIdx = song!.lowerBound(pausePos);
    _clearNotes();
    log('一時停止: ${songs[cur].name}');
    notifyListeners();
  }

  void resume() {
    if ((state != PlayState.paused && state != PlayState.stopped) || song == null) return;
    if (!connected) {
      log('本体が見つからないので再開できません');
      return;
    }
    final t0 = _quietTime();
    _sendIdx = song!.lowerBound(pausePos);
    _chase(_sendIdx, t0);
    _songStart = t0 + 50 - pausePos * 1000;
    state = PlayState.playing;
    KeepAwake.on();
    log('再開: ${songs[cur].name}（${fmtTime(pausePos)}）');
    notifyListeners();
  }

  void seekTo(double pos) {
    final s = song;
    if (s == null) return;
    final was = state;
    allNotesOff();
    pausePos = pos.clamp(0, s.dur);
    _sendIdx = s.lowerBound(pausePos);
    _rebuildViewTo(pausePos);
    if (was == PlayState.playing) {
      final t0 = _quietTime();
      _chase(_sendIdx, t0);
      _songStart = t0 + 50 - pausePos * 1000;
    } else if (was != PlayState.paused) {
      state = PlayState.paused;
    }
    notifyListeners();
  }

  void stopAll({PlayState to = PlayState.stopped}) {
    allNotesOff();
    if (song != null && to == PlayState.stopped) {
      pausePos = 0;
      _rebuildViewTo(0);
    }
    final wasHandsOn = state == PlayState.handsOn;
    state = to;
    if (wasHandsOn) _sendMaster(_quietTime()); // 最大にしていた音量を戻す
    KeepAwake.off();
    notifyListeners();
  }

  void next() => startSong(cur + 1);
  void prev() => startSong(cur - 1);
  void restart() => startSong(math.max(0, cur));

  // ---------------- 本体が操作されたら止める ----------------
  double _touchAt = 0; // 最後に操作された時刻
  final Set<int> _held = {}; // 押さえている鍵盤
  int _resumeIdx = 0; // 再開するときの曲

  /// 操作が終わってから再生を始めるまでの残り秒（handsOn のときだけ。押さえている間は null）
  double? get handsOnLeft {
    if (state != PlayState.handsOn || yieldResumeSec <= 0 || _held.isNotEmpty) return null;
    return math.max(0, yieldResumeSec - (nowMs() - _touchAt) / 1000);
  }

  /// 本体から届いた MIDI。鍵盤（ノートのオン・オフ）だけを見る
  /// （スティックのベンド・CC やペダルは、触っていなくても揺れて届くことがあるので見ない）
  void onDeviceInput(Uint8List d) {
    if (d.length < 3) return;
    final ty = d[0] & 0xF0;
    bool start; // 押した（止めるきっかけ）か、離しただけか
    if (ty == 0x90 && d[2] > 0) {
      _held.add(d[1]);
      start = true;
    } else if (ty == 0x80 || ty == 0x90) {
      _held.remove(d[1]);
      start = false;
    } else {
      return;
    }
    _touchAt = nowMs();
    if (!yieldOnTouch) return;
    if (state == PlayState.handsOn) {
      notifyListeners(); // 残り時間の表示を戻す
    } else if (start && (state == PlayState.playing || state == PlayState.gap || state == PlayState.loading)) {
      _yieldToDevice();
    }
  }

  void _yieldToDevice() {
    _resumeIdx = state == PlayState.loading ? cur : cur + 1; // 読み込み中ならその曲、それ以外は次の曲から
    if (state == PlayState.playing && song != null) {
      pausePos = math.max(0, songTime);
      _sendIdx = song!.lowerBound(pausePos);
    }
    ++_loadToken; // 読み込み中の曲は始めない
    state = PlayState.handsOn;
    allNotesOff();
    _clearNotes();
    // 鍵盤（ch1）が曲の音色のままにならないよう、音源を初期状態（ピアノ）に戻す
    final t0 = _quietTime();
    _sendNow([0xF0, 0x7E, 0x7F, 0x09, 0x01, 0xF7], t0);
    _sendNow([0xC0, 0], t0 + 1); // 本体の音色切替の位置も合わせる
    _sendMaster(t0 + 2); // 操作している間は音量を最大に（再生を始めるときに設定した音量へ戻す）
    _resetView();
    log('本体の鍵盤が押されたので止めました（ノート ${_held.isEmpty ? '?' : _held.last}）');
    notifyListeners();
  }

  void _resumeFromHandsOn() {
    _held.clear();
    log('再生を始めます');
    startSong(songs.isEmpty ? 0 : _resumeIdx % songs.length);
  }

  void togglePlay() {
    if (songs.isEmpty) return;
    if (state == PlayState.handsOn) {
      _resumeFromHandsOn();
    } else if (state == PlayState.playing) {
      pause();
    } else if (state == PlayState.paused || state == PlayState.stopped) {
      song != null ? resume() : startSong(math.max(0, cur));
    } else if (state == PlayState.idle) {
      startSong(math.max(0, cur));
    }
  }

  // 今の位置までの音色・CC・ベンド・プレッシャー・SysEx の最後の状態を送り直す（音は送らない）
  void _chase(int upto, double at) {
    final s = song!;
    final last = <String, int>{};
    final order = <int>[];
    for (int i = 0; i < upto; ++i) {
      final d = s.ev[i].d, ty = d[0] & 0xF0, ch = d[0] & 15;
      if (d[0] == 0xF0 || d[0] == 0xF7) {
        order.add(i);
      } else if (ty == 0xC0) {
        last['p$ch'] = i;
      } else if (ty == 0xE0) {
        last['b$ch'] = i;
      } else if (ty == 0xD0) {
        last['a$ch'] = i;
      } else if (ty == 0xB0 && d[1] < 120) {
        last['c${ch}_${d[1]}'] = i;
      }
    }
    order.addAll(last.values);
    order.sort();
    for (final i in order) {
      _send(s.ev[i].d, at);
    }
    _sendMaster(at);
  }

  // 1ms ごと: 予約できる範囲（または今）までのイベントを送る / 曲の終わり / 曲間
  void _tick() {
    final now = nowMs();
    final s = song;
    if (state == PlayState.playing && s != null) {
      final horizon = (now - _songStart + out.lookaheadMs) / 1000;
      while (_sendIdx < s.ev.length && s.ev[_sendIdx].t <= horizon) {
        final e = s.ev[_sendIdx++];
        _send(e.d, _songStart + e.t * 1000);
        if (state != PlayState.playing) return; // 送っている間に抜けた
      }
      if (_sendIdx >= s.ev.length && (now - _songStart) / 1000 >= s.dur + 1.5) {
        // 最後の音の残響を待ってから
        allNotesOff();
        if (cur + 1 >= songs.length && !repeat) {
          log('最後まで再生しました');
          stopAll();
          return;
        }
        state = PlayState.gap;
        _gapUntil = now + gapSec * 1000;
        _clearNotes();
        notifyListeners();
      }
    } else if (state == PlayState.gap && now >= _gapUntil) {
      next();
    } else if (state == PlayState.handsOn) {
      final idle = (now - _touchAt) / 1000;
      if (idle > 120) {
        // 離したことが届かなかった（ケーブルの抜き差しなど）ときに押さえたままにならないように
        _held.clear();
      }
      if (yieldResumeSec > 0 && _held.isEmpty && idle >= yieldResumeSec) _resumeFromHandsOn();
    }
  }

  // ---------------- 表示 ----------------
  void _resetView() {
    for (int i = 0; i < 16; ++i) {
      chans[i] = ChanView();
    }
    quality = -1;
  }

  void _clearNotes() {
    for (final c in chans) {
      c.notes.clear();
      c.level = 0;
    }
  }

  void _rebuildViewTo(double t) {
    _resetView();
    final s = song!;
    int i = 0;
    for (; i < s.ev.length && s.ev[i].t < t; ++i) {
      _applyView(s.ev[i].d, quiet: true);
    }
    _clearNotes();
    _visIdx = i;
  }

  void _applyView(Uint8List d, {bool quiet = false}) {
    if (d[0] == 0xF0) {
      if (isQualitySysEx(d)) {
        quality = d[5] != 0 ? 1 : 0;
      } else if (isGmReset(d)) {
        _resetView();
        quality = 0;
      }
      return;
    }
    if (d[0] < 0x80 || d[0] >= 0xF0) return;
    final ty = d[0] & 0xF0, c = chans[d[0] & 15];
    if (ty == 0x90 && d[2] > 0) {
      c.notes[d[1]] = d[2];
      if (!quiet) c.level = math.max(c.level, d[2] / 127 * c.vol / 127 * c.expr / 127 * effGain(d[0] & 15).clamp(0.0, 1.0));
    } else if (ty == 0x80 || ty == 0x90) {
      c.notes.remove(d[1]);
    } else if (ty == 0xC0) {
      c.prog = d[1];
      c.progSet = true;
    } else if (ty == 0xE0) {
      c.bend = ((d[2] << 7) | d[1]) - 8192;
    } else if (ty == 0xB0) {
      final n = d[1], v = d[2];
      switch (n) {
        case 1: c.mod = v;
        case 7: c.vol = v;
        case 10: c.pan = v;
        case 11: c.expr = v;
        case 91: c.rev = v;
        case 93: c.cho = v;
        case 101: c.rpnM = v;
        case 100: c.rpnL = v;
        case 6: if (c.rpnM == 0 && c.rpnL == 0) c.range = v;
        case 121: c.expr = 127; c.bend = 0; c.mod = 0;
        case 120 || 123: c.notes.clear();
      }
    }
  }

  double _lastFrame = 0;

  /// 画面の 1 フレームごとに呼ぶ: 今の時刻までのイベントを表示に反映して、メーターを下げる
  void onFrame() {
    final s = song;
    final now = nowMs();
    final dt = _lastFrame == 0 ? 0.016 : ((now - _lastFrame) / 1000).clamp(0.0, 0.1);
    _lastFrame = now;
    if (s != null && state == PlayState.playing) {
      final t = songTime;
      while (_visIdx < s.ev.length && s.ev[_visIdx].t <= t) {
        _applyView(s.ev[_visIdx++].d);
      }
    }
    final decay = math.pow(0.08, dt).toDouble(); // 1 秒で 8% まで下がる
    for (final c in chans) {
      c.level *= decay;
    }
    frame.ping();
  }

  // 確認用: 送るはずの時刻とのずれ
  Future<String?> timingReport() async {
    return out.stats();
  }
}

String fmtTime(double s) {
  final n = s.isFinite ? math.max(0, s.floor()) : 0;
  return '${n ~/ 60}:${(n % 60).toString().padLeft(2, '0')}';
}

/// 毎フレームの知らせ
class FrameNotifier extends ChangeNotifier {
  void ping() => notifyListeners();
}
