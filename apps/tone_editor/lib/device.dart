import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'params.dart';
import 'transport.dart';

/// 本体の情報（@hello の返事）
class DeviceInfo {
  final int proto, numInst, numUser, numParams, numButtons, numBanks, userBase;
  final String firmware;
  DeviceInfo(this.proto, this.firmware, this.numInst, this.numUser, this.numParams, this.numButtons, this.numBanks, this.userBase);
}

class Patch {
  String name;
  List<int> values; // 基本 36 個
  List<int> ext; // 拡張 40 個（シンセ・作り込みの借用）
  Patch(this.name, List<int> v, [List<int>? x])
      : values = List<int>.from(v),
        ext = List<int>.from(x ?? kSynthExtDefault);
  Patch copy() => Patch(name, values, ext);
  int get algo => values[0];
}

/// 本体の負荷（2 秒ごとの状態表示から）
class LoadStatus {
  final int avg, peak, voices, limit;
  LoadStatus(this.avg, this.peak, this.voices, this.limit);
}

/// 音色の割り当て: TONE1〜5 × 3 組（[組 × 5 + ボタン]）。組 1 は拡張基板なしの同時押しでも使う
class Assignment {
  static const int buttons = 5, banks = 3;
  List<int> tones;
  Assignment(List<int> t) : tones = List<int>.from(t);
  int at(int bank, int button) => tones[bank * buttons + button];
  void set(int bank, int button, int inst) => tones[bank * buttons + button] = inst;
}

class DeviceException implements Exception {
  final String message;
  DeviceException(this.message);
  @override
  String toString() => message;
}

/// 本体との '@' コマンドのやりとり。1 度に 1 つずつ送り、返事を待つ
class DeviceClient extends ChangeNotifier {
  LineTransport? _t;
  StreamSubscription<String>? _sub;
  DeviceInfo? info;
  final List<String> log = []; // 本体からの行（'@' 以外の状態表示も）
  LoadStatus? load; // 本体の負荷（最後に届いた状態表示）
  _Pending? _pending;
  static final _cpuRe = RegExp(r'^CPU (\d+)% \(peak (\d+)%\)\s+voices (\d+)/(\d+)');
  Future<void> _queue = Future.value();

  bool get connected => _t != null && info != null;
  String get label => _t?.label ?? '';

  Future<void> connect(LineTransport t) async {
    await disconnect();
    _t = t;
    _sub = t.lines.listen(_onLine, onError: (Object e) {
      _addLog('! $e');
      disconnect();
    });
    try {
      final r = await _request('@hello', (l) => l.startsWith('@hello '), timeout: const Duration(seconds: 3));
      final m = <String, String>{};
      for (final kv in r.last.substring(7).split(' ')) {
        final i = kv.indexOf('=');
        if (i > 0) m[kv.substring(0, i)] = kv.substring(i + 1);
      }
      int n(String k) => int.tryParse(m[k] ?? '') ?? -1;
      final di = DeviceInfo(n('proto'), m['fw'] ?? '?', n('inst'), n('user'), n('params'), n('buttons'), n('banks'), n('base'));
      if (di.proto != kPatchProto || di.numParams != kNumParams || n('ext') != kNumExt) {
        throw DeviceException('本体のファームの版が合いません（本体 proto=${di.proto} / このアプリ proto=$kPatchProto）。'
            'ファーム（2026-09-30h 以降）とアプリを同じ版にしてください');
      }
      info = di;
      notifyListeners();
    } catch (e) {
      await disconnect();
      if (e is TimeoutException) {
        throw DeviceException('返事がありません。音色エディタに対応したファーム（2026-09-30d 以降）が書き込まれているか確認してください');
      }
      rethrow;
    }
  }

  Future<void> disconnect() async {
    final t = _t;
    final sub = _sub;
    _t = null;
    _sub = null;
    info = null;
    final p = _pending;
    _pending = null;
    if (p != null && !p.completer.isCompleted) p.completer.completeError(DeviceException('切断しました'));
    notifyListeners(); // 画面は先に「つながっていない」に戻す（後片付けを待たない）
    try {
      await sub?.cancel().timeout(const Duration(seconds: 1));
      await t?.close().timeout(const Duration(seconds: 1));
    } catch (_) {}
  }

  void _addLog(String l) {
    log.add(l);
    if (log.length > 300) log.removeRange(0, log.length - 300);
  }

  void _onLine(String line) {
    _addLog(line);
    final m = _cpuRe.firstMatch(line);
    if (m != null) {
      load = LoadStatus(int.parse(m[1]!), int.parse(m[2]!), int.parse(m[3]!), int.parse(m[4]!));
      notifyListeners();
    }
    final p = _pending;
    if (p == null || !line.startsWith('@')) return;
    if (line.startsWith('@err')) {
      _pending = null;
      p.completer.completeError(DeviceException('本体: ${line.substring(5)}'));
      return;
    }
    if (p.accept(line)) p.lines.add(line);
    if (p.isEnd(line)) {
      _pending = null;
      p.completer.complete(p.lines);
    }
  }

  /// 1 行送って、isEnd を満たす行が来るまで待つ（順番待ちあり）
  Future<List<String>> _request(String line, bool Function(String) isEnd,
      {bool Function(String)? accept, Duration timeout = const Duration(seconds: 3)}) {
    final done = Completer<List<String>>();
    _queue = _queue.then((_) async {
      final t = _t;
      if (t == null) {
        done.completeError(DeviceException('本体につながっていません'));
        return;
      }
      final p = _Pending(isEnd, accept ?? (l) => true);
      _pending = p;
      try {
        t.sendLine(line);
        final r = await p.completer.future.timeout(timeout);
        done.complete(r);
      } catch (e) {
        if (identical(_pending, p)) _pending = null;
        done.completeError(e);
      }
    });
    return done.future;
  }

  /// 返事を待たずに送る（試聴の鍵盤）
  void _fire(String line) {
    _queue = _queue.then((_) {
      try {
        _t?.sendLine(line);
      } catch (e) {
        _addLog('! $e');
      }
    });
  }

  Future<List<String>> names() async {
    final r = await _request('@names', (l) => l == '@end names', accept: (l) => l.startsWith('@name '), timeout: const Duration(seconds: 5));
    final names = <String>[];
    for (final l in r) {
      final rest = l.substring(6);
      final sp = rest.indexOf(' ');
      final i = int.parse(rest.substring(0, sp));
      while (names.length <= i) {
        names.add('');
      }
      names[i] = rest.substring(sp + 1);
    }
    return names;
  }

  Future<Patch> getPatch(int index) async {
    final r = await _request('@get $index', (l) => l.startsWith('@patch $index|'));
    final parts = r.last.split('|');
    if (parts.length != 4) throw DeviceException('本体の返事が読めません: ${r.last}');
    final vals = parts[2].split(',').map(int.parse).toList();
    final ext = parts[3].split(',').map(int.parse).toList();
    return Patch(parts[1], vals, ext);
  }

  /// ユーザー音色の枠 slot を書き換える（本体の RAM。フラッシュへは save）
  Future<void> setPatch(int slot, Patch p) async {
    final name = sanitizeName(p.name);
    await _request('@set $slot|$name|${clampParams(p.values).join(',')}|${clampExt(p.ext).join(',')}', (l) => l == '@ok set $slot');
  }

  Future<void> selectOnKeyboard(int index) => _request('@kb $index', (l) => l == '@ok kb $index');
  void noteOn(int note, int velocity) => _fire('@on $note $velocity');
  void noteOff(int note) => _fire('@off $note');

  Future<Assignment> getAssign() async {
    final r = await _request('@assign', (l) => l.startsWith('@assign '));
    final t = r.last.substring(8).split(',').where((x) => x.isNotEmpty).map(int.parse).toList();
    if (t.length != Assignment.buttons * Assignment.banks) throw DeviceException('本体の返事が読めません: ${r.last}');
    return Assignment(t);
  }

  Future<void> setAssign(Assignment a) => _request('@assign ${a.tones.join(',')}', (l) => l == '@ok assign');

  Future<void> save() => _request('@save', (l) => l == '@ok save', timeout: const Duration(seconds: 6));
  Future<void> loadSaved() => _request('@load', (l) => l == '@ok load', timeout: const Duration(seconds: 5));
  Future<void> defaults() => _request('@defaults', (l) => l == '@ok defaults', timeout: const Duration(seconds: 5));

  @override
  void dispose() {
    disconnect();
    super.dispose();
  }
}

class _Pending {
  final bool Function(String) isEnd;
  final bool Function(String) accept;
  final List<String> lines = [];
  final Completer<List<String>> completer = Completer();
  _Pending(this.isEnd, this.accept);
}

/// 名前: '|' と改行を除き、UTF-8 で 15 バイト以内（文字の途中で切らない）
String sanitizeName(String s) {
  var t = s.replaceAll(RegExp(r'[|\r\n\t]'), ' ').trim();
  if (t.isEmpty) t = 'User';
  while (utf8.encode(t).length > 15) {
    t = String.fromCharCodes(t.runes.toList()..removeLast());
  }
  return t;
}
