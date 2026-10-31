import 'dart:async';
import 'dart:convert';

import 'builtin_table.dart';
import 'params.dart';
import 'presets.dart';
import 'transport.dart';

/// 本体がなくても画面を試せる模擬本体（ファームの '@' コマンドと同じ返事をする。音は出ない）
class MockDevice implements LineTransport {
  static const int numUser = 8, numButtons = 5, numBanks = 3;
  static const List<int> defaultTones = [0, 1, 2, 3, 4, 20, 6, 8, 10, 18, 82, 83, 84, 86, 88];
  static const List<String> _richNames = ['Piano', 'Bright Piano', 'Honky-tonk', 'Strings', 'Slow Strings', 'Synth Strings', 'Choir Aahs', 'Voice Lead'];
  final _out = StreamController<String>.broadcast();
  final List<String> userNames = List.generate(numUser, (k) => kSynthPresets[k].$1);
  final List<List<int>> userParams = List.generate(numUser, (k) => List<int>.from(kSynthPresets[k].$2));
  final List<List<int>> userExt = List.generate(numUser, (k) => List<int>.from(kSynthPresets[k].$3));
  List<int> tones = List.of(defaultTones);
  // 「保存」した内容
  late List<String> _savedNames = List.of(userNames);
  late List<List<int>> _savedParams = [for (final p in userParams) List.of(p)];
  late List<List<int>> _savedExt = [for (final p in userExt) List.of(p)];
  late List<int> _savedTones = List.of(tones);
  bool _hasSaved = false;
  int kb = 0;
  int _sounding = 0;
  final List<String> sent = []; // テスト用: 受け取った行

  int get base => kBuiltinInstruments.length;
  int get numAll => base + numUser;

  @override
  Stream<String> get lines => _out.stream;
  @override
  String get label => 'デモ（本体なし）';

  String nameOf(int i) => i < base ? kBuiltinInstruments[i].$1 : userNames[i - base];
  List<int> paramsOf(int i) => i < base ? kBuiltinInstruments[i].$2 : userParams[i - base];
  List<int> extOf(int i) {
    if (i >= base) return userExt[i - base];
    final x = List<int>.from(kSynthExtDefault);
    x[32] = _richNames.indexOf(kBuiltinInstruments[i].$1) + 1; // 作り込みがあれば引き継ぐ
    x[33] = kBuiltinLevel[i]; // 大きさの補正も引き継ぐ
    return x;
  }

  void _reply(String s) => scheduleMicrotask(() {
        if (!_out.isClosed) _out.add(s);
      });

  void _status() {
    final cost = toneCost(paramsOf(kb), extOf(kb));
    final pct = (6 + _sounding * cost * 32000 / 250e6 / 2 * 100).round();
    _reply('CPU $pct% (peak ${pct + 2}%)  voices $_sounding/32  HQ  250MHz  core0 50%  underruns +0 (total 0)  guard 0');
  }

  @override
  void sendLine(String line) {
    sent.add(line);
    if (!line.startsWith('@')) return;
    final sp = line.indexOf(' ');
    final cmd = sp < 0 ? line.substring(1) : line.substring(1, sp);
    final arg = sp < 0 ? '' : line.substring(sp + 1);
    switch (cmd) {
      case 'hello':
        _reply('@hello proto=$kPatchProto fw=demo inst=$base user=$numUser params=$kNumParams buttons=$numButtons banks=$numBanks base=$base ext=$kNumExt');
      case 'names':
        for (var i = 0; i < numAll; i++) {
          _reply('@name $i ${nameOf(i)}');
        }
        _reply('@end names');
      case 'get':
        final i = int.tryParse(arg) ?? -1;
        if (i < 0 || i >= numAll) return _reply('@err get: bad index');
        _reply('@patch $i|${nameOf(i)}|${paramsOf(i).join(',')}|${extOf(i).join(',')}');
      case 'set':
        final parts = arg.split('|');
        final slot = int.tryParse(parts.isNotEmpty ? parts[0] : '') ?? -1;
        if (parts.length < 3 || parts.length > 4 || slot < 0 || slot >= numUser) return _reply('@err set: format');
        final vals = parts[2].split(',').map((s) => int.tryParse(s)).toList();
        if (vals.length != kNumParams || vals.contains(null)) return _reply('@err set: need 36 values');
        if (parts.length == 4) {
          final ext = parts[3].split(',').map((s) => int.tryParse(s)).toList();
          if (ext.length != kNumExt || ext.contains(null)) return _reply('@err set: need 40 ext values');
          userExt[slot] = clampExt(ext.cast<int>());
        }
        var name = parts[1];
        while (utf8.encode(name).length > 15) {
          name = name.substring(0, name.length - 1);
        }
        userNames[slot] = name;
        userParams[slot] = clampParams(vals.cast<int>());
        _reply('@ok set $slot');
      case 'kb':
        kb = int.tryParse(arg) ?? 0;
        _reply('@ok kb $kb');
      case 'on':
        _sounding = (_sounding + 1).clamp(0, 32);
        _status();
      case 'off':
        _sounding = (_sounding - 1).clamp(0, 32);
        _status();
      case 'assign':
        if (arg.isEmpty) return _reply('@assign ${tones.join(',')}');
        final t = arg.split(',').map(int.tryParse).toList();
        if (t.length != numButtons * numBanks || t.contains(null)) return _reply('@err assign: need 15 values');
        if (t.any((x) => x! < 0 || x >= numAll)) return _reply('@err assign: bad index');
        tones = t.cast<int>();
        _reply('@ok assign');
      case 'save':
        _savedNames = List.of(userNames);
        _savedParams = [for (final p in userParams) List.of(p)];
        _savedExt = [for (final p in userExt) List.of(p)];
        _savedTones = List.of(tones);
        _hasSaved = true;
        Future.delayed(const Duration(milliseconds: 80), () => _reply('@ok save'));
      case 'load':
        if (!_hasSaved) return _reply('@err load: nothing saved');
        userNames.setAll(0, _savedNames);
        for (var k = 0; k < numUser; k++) {
          userParams[k] = List.of(_savedParams[k]);
          userExt[k] = List.of(_savedExt[k]);
        }
        tones = List.of(_savedTones);
        _reply('@ok load');
      case 'defaults':
        for (var k = 0; k < numUser; k++) {
          userNames[k] = kSynthPresets[k].$1;
          userParams[k] = List<int>.from(kSynthPresets[k].$2);
          userExt[k] = List<int>.from(kSynthPresets[k].$3);
        }
        tones = List.of(defaultTones);
        _reply('@ok defaults');
      default:
        _reply('@err unknown command $cmd');
    }
  }

  @override
  Future<void> close() async => _out.close();
}
