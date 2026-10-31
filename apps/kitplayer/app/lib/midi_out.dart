// MIDI 出力（と、本体を操作したことを知るための入力）と、スリープ防止
//  Windows: winmm を直接。送る時刻を正確にするため、送信は別の Isolate（画面の描画と別のスレッド）で行う
//  Mac:     flutter_midi_command に CoreMIDI の時刻（mach 時刻）を指定して予約する
//  入力: 本体は鍵盤・ペダル・スティックの操作を USB MIDI で PC へ送ってくる（ch1 のノート・CC・ベンド）
import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:flutter_midi_command/flutter_midi_command.dart';

// ---------------- 時計（ミリ秒）。送る時刻はこの時計で指定する ----------------
// Windows は送信の Isolate と同じ時計を使うため、OS の高精度カウンタ（QueryPerformanceCounter）
final Stopwatch _sw = Stopwatch()..start();
int Function(Pointer<Int64>)? _qpc;
Pointer<Int64>? _qpcBuf;
double _qpcPerMs = 0;
double nowMs() {
  if (Platform.isWindows) {
    if (_qpc == null) {
      final k = DynamicLibrary.open('kernel32.dll');
      _qpc = k.lookupFunction<Int32 Function(Pointer<Int64>), int Function(Pointer<Int64>)>('QueryPerformanceCounter');
      final freq = k.lookupFunction<Int32 Function(Pointer<Int64>), int Function(Pointer<Int64>)>('QueryPerformanceFrequency');
      _qpcBuf = calloc<Int64>();
      freq(_qpcBuf!);
      _qpcPerMs = _qpcBuf!.value / 1000.0;
    }
    _qpc!(_qpcBuf!);
    return _qpcBuf!.value / _qpcPerMs;
  }
  return _sw.elapsedMicroseconds / 1000.0;
}

abstract class MidiOut {
  /// 送れる出力の名前
  Future<List<String>> ports();
  Future<bool> open(String name);
  void close();
  String? get openName;

  /// atMs（nowMs の時刻）に送る。今より前なら今すぐ。送れなかったら onError
  void send(Uint8List d, double atMs);

  /// 予約してある分を取り消す（取り消せない出力では何もしない）
  void flushPending();

  /// 取り消しができるか（できなければ、予約の分が出きったあとにもう一度音を止める）
  bool get canFlush;

  /// 何ミリ秒先まで予約して送れるか
  double get lookaheadMs;

  /// 送れなかった（抜けた）ときに呼ぶ
  void Function()? onError;

  /// 本体から届いた MIDI（1 メッセージずつ）
  void Function(Uint8List d)? onInput;

  /// 本体からの入力を受け取れているか（入力の名前。null = 受け取れていない）
  String? get inName;

  /// 確認用: 送った数と遅れ
  Future<String?> stats() async => null;

  static MidiOut create({bool dry = false}) {
    if (Platform.isWindows) return WinMidiOut(dry: dry);
    return dry ? DryMidiOut() : MacMidiOut();
  }
}

/// PC の中のソフト音源・仮想ポート（本体ではない）
bool isSoftPort(String n) => const ["Microsoft GS Wavetable", "IAC", "Network", "loopMIDI", "Session", "Bluetooth"].any(n.contains);

/// 出力と同じ機器の入力を選ぶ（同じ名前、末尾の番号を除いて同じ名前、の順）
int pickInputFor(String outName, List<String> ins) {
  String base(String s) => s.replaceFirst(RegExp(r'[\s.]*\d+$'), '').trim();
  final i = ins.indexOf(outName);
  if (i >= 0) return i;
  return ins.indexWhere((s) => s.isNotEmpty && base(s) == base(outName));
}

// ---------------- Windows（winmm） ----------------
final class _MidiOutCaps extends Struct {
  @Uint16()
  external int wMid;
  @Uint16()
  external int wPid;
  @Uint32()
  external int vDriverVersion;
  @Array(32)
  external Array<Uint16> szPname;
  @Uint16()
  external int wTechnology;
  @Uint16()
  external int wVoices;
  @Uint16()
  external int wNotes;
  @Uint16()
  external int wChannelMask;
  @Uint32()
  external int dwSupport;
}

final class _MidiInCaps extends Struct {
  @Uint16()
  external int wMid;
  @Uint16()
  external int wPid;
  @Uint32()
  external int vDriverVersion;
  @Array(32)
  external Array<Uint16> szPname;
  @Uint32()
  external int dwSupport;
}

final class _MidiHdr extends Struct {
  external Pointer<Uint8> lpData;
  @Uint32()
  external int dwBufferLength;
  @Uint32()
  external int dwBytesRecorded;
  @IntPtr()
  external int dwUser;
  @Uint32()
  external int dwFlags;
  external Pointer<Void> lpNext;
  @IntPtr()
  external int reserved;
  @Uint32()
  external int dwOffset;
  @Array(8)
  external Array<IntPtr> dwReserved;
}

class _WinMM {
  static final _lib = DynamicLibrary.open('winmm.dll');
  static final getNumDevs = _lib.lookupFunction<Uint32 Function(), int Function()>('midiOutGetNumDevs');
  static final getDevCaps =
      _lib.lookupFunction<Uint32 Function(IntPtr, Pointer<_MidiOutCaps>, Uint32), int Function(int, Pointer<_MidiOutCaps>, int)>('midiOutGetDevCapsW');
  static final openOut = _lib.lookupFunction<Uint32 Function(Pointer<IntPtr>, Uint32, IntPtr, IntPtr, Uint32), int Function(Pointer<IntPtr>, int, int, int, int)>(
      'midiOutOpen');
  static final shortMsg = _lib.lookupFunction<Uint32 Function(IntPtr, Uint32), int Function(int, int)>('midiOutShortMsg');
  static final prepare = _lib.lookupFunction<Uint32 Function(IntPtr, Pointer<_MidiHdr>, Uint32), int Function(int, Pointer<_MidiHdr>, int)>('midiOutPrepareHeader');
  static final unprepare =
      _lib.lookupFunction<Uint32 Function(IntPtr, Pointer<_MidiHdr>, Uint32), int Function(int, Pointer<_MidiHdr>, int)>('midiOutUnprepareHeader');
  static final longMsg = _lib.lookupFunction<Uint32 Function(IntPtr, Pointer<_MidiHdr>, Uint32), int Function(int, Pointer<_MidiHdr>, int)>('midiOutLongMsg');
  static final reset = _lib.lookupFunction<Uint32 Function(IntPtr), int Function(int)>('midiOutReset');
  static final closeOut = _lib.lookupFunction<Uint32 Function(IntPtr), int Function(int)>('midiOutClose');
  static final timeBeginPeriod = _lib.lookupFunction<Uint32 Function(Uint32), int Function(int)>('timeBeginPeriod');
  // 入力
  static final inGetNumDevs = _lib.lookupFunction<Uint32 Function(), int Function()>('midiInGetNumDevs');
  static final inGetDevCaps =
      _lib.lookupFunction<Uint32 Function(IntPtr, Pointer<_MidiInCaps>, Uint32), int Function(int, Pointer<_MidiInCaps>, int)>('midiInGetDevCapsW');
  static final openIn = _lib.lookupFunction<Uint32 Function(Pointer<IntPtr>, Uint32, IntPtr, IntPtr, Uint32), int Function(Pointer<IntPtr>, int, int, int, int)>(
      'midiInOpen');
  static final startIn = _lib.lookupFunction<Uint32 Function(IntPtr), int Function(int)>('midiInStart');
  static final stopIn = _lib.lookupFunction<Uint32 Function(IntPtr), int Function(int)>('midiInStop');
  static final resetIn = _lib.lookupFunction<Uint32 Function(IntPtr), int Function(int)>('midiInReset');
  static final closeIn = _lib.lookupFunction<Uint32 Function(IntPtr), int Function(int)>('midiInClose');

  static String _name(Array<Uint16> a) {
    final cs = <int>[];
    for (int k = 0; k < 32; ++k) {
      final c = a[k];
      if (c == 0) break;
      cs.add(c);
    }
    return String.fromCharCodes(cs);
  }

  static List<String> list() {
    final n = getNumDevs();
    final caps = calloc<_MidiOutCaps>();
    final names = <String>[];
    for (int i = 0; i < n; ++i) {
      names.add(getDevCaps(i, caps, sizeOf<_MidiOutCaps>()) != 0 ? '' : _name(caps.ref.szPname));
    }
    calloc.free(caps);
    return names;
  }

  static List<String> listIn() {
    final n = inGetNumDevs();
    final caps = calloc<_MidiInCaps>();
    final names = <String>[];
    for (int i = 0; i < n; ++i) {
      names.add(inGetDevCaps(i, caps, sizeOf<_MidiInCaps>()) != 0 ? '' : _name(caps.ref.szPname));
    }
    calloc.free(caps);
    return names;
  }

  static bool send(int h, Uint8List d) {
    if (d[0] == 0xF0) {
      final buf = calloc<Uint8>(d.length);
      buf.asTypedList(d.length).setAll(0, d);
      final hdr = calloc<_MidiHdr>();
      hdr.ref.lpData = buf;
      hdr.ref.dwBufferLength = d.length;
      hdr.ref.dwBytesRecorded = d.length;
      var r = prepare(h, hdr, sizeOf<_MidiHdr>());
      if (r == 0) {
        r = longMsg(h, hdr, sizeOf<_MidiHdr>());
        for (int w = 0; r == 0 && (hdr.ref.dwFlags & 1) == 0 && w < 1000; ++w) {
          sleep(const Duration(milliseconds: 1)); // 送り終わるまで（MHDR_DONE）
        }
        unprepare(h, hdr, sizeOf<_MidiHdr>());
      }
      calloc.free(hdr);
      calloc.free(buf);
      return r == 0;
    }
    final m = d[0] | (d.length > 1 ? d[1] << 8 : 0) | (d.length > 2 ? d[2] << 16 : 0);
    return shortMsg(h, m) == 0;
  }
}

// 送信の Isolate: 届いた (時刻, バイト列) を時刻順に並べ、1ms ごとに時刻の来たものを送る
// 受け取るもの: ['h', ハンドル] / ['s', 時刻, Uint8List] / ['f']（予約を消す）/ ['st', SendPort]（統計）
// 返すもの: ['err']（送れなかった）
void _senderMain(List<Object> args) {
  final toMain = args[0] as SendPort;
  final dry = args[1] as bool;
  final rx = ReceivePort();
  toMain.send(rx.sendPort);
  try {
    _WinMM.timeBeginPeriod(1); // タイマーを 1ms 刻みに（Windows の標準は 15.6ms）
  } catch (_) {}
  int h = 0;
  final times = <double>[];
  final data = <Uint8List>[];
  int sent = 0;
  double lateSum = 0, lateMax = 0;
  void flushDue() {
    final now = nowMs();
    int n = 0;
    while (n < times.length && times[n] <= now) {
      final late = now - times[n];
      if (late > 0) {
        lateSum += late;
        if (late > lateMax) lateMax = late;
      }
      ++sent;
      if (!dry && h != 0 && !_WinMM.send(h, data[n])) {
        h = 0;
        toMain.send(['err']);
      }
      ++n;
    }
    if (n > 0) {
      times.removeRange(0, n);
      data.removeRange(0, n);
    }
  }

  rx.listen((m) {
    final msg = m as List;
    switch (msg[0]) {
      case 's':
        final t = msg[1] as double;
        int lo = 0, hi = times.length; // 同じ時刻なら届いた順（後ろへ）
        while (lo < hi) {
          final mid = (lo + hi) >> 1;
          if (times[mid] <= t) {
            lo = mid + 1;
          } else {
            hi = mid;
          }
        }
        times.insert(lo, t);
        data.insert(lo, msg[2] as Uint8List);
        flushDue();
      case 'f':
        times.clear();
        data.clear();
      case 'h':
        h = msg[1] as int;
      case 'st':
        (msg[1] as SendPort).send(sent == 0 ? null : '送った $sent、遅れ 平均 ${(lateSum / sent).toStringAsFixed(2)}ms・最大 ${lateMax.toStringAsFixed(1)}ms');
    }
  });
  Timer.periodic(const Duration(milliseconds: 1), (_) => flushDue());
}

/// 本体からの入力（鍵盤など）。winmm は別のスレッドから呼んでくるので、NativeCallable.listener で受ける
class WinMidiIn {
  WinMidiIn(this.onData);
  final void Function(Uint8List d) onData;
  int _h = 0;
  String? name; // 開いている入力（null = 開いていない）
  NativeCallable<Void Function(IntPtr, Uint32, IntPtr, IntPtr, IntPtr)>? _cb;

  /// 出力 outName と同じ機器の入力を開く
  bool open(String outName) {
    close();
    try {
      final ins = _WinMM.listIn();
      final i = pickInputFor(outName, ins);
      if (i < 0) return false;
      _cb = NativeCallable<Void Function(IntPtr, Uint32, IntPtr, IntPtr, IntPtr)>.listener((int h, int msg, int inst, int p1, int p2) {
        if (msg != 0x3C3) return; // MIM_DATA（短いメッセージ）だけ
        final st = p1 & 0xFF;
        if (st < 0x80 || st >= 0xF0) return;
        final len = (st & 0xE0) == 0xC0 ? 2 : 3; // Cx / Dx は 2 バイト
        onData(Uint8List.fromList([st, (p1 >> 8) & 0x7F, (p1 >> 16) & 0x7F].sublist(0, len)));
      });
      final ph = calloc<IntPtr>();
      final r = _WinMM.openIn(ph, i, _cb!.nativeFunction.address, 0, 0x30000); // CALLBACK_FUNCTION
      _h = r == 0 ? ph.value : 0;
      calloc.free(ph);
      if (_h == 0 || _WinMM.startIn(_h) != 0) {
        close();
        return false;
      }
      name = ins[i];
      return true;
    } catch (_) {
      close();
      return false;
    }
  }

  void close() {
    if (_h != 0) {
      _WinMM.stopIn(_h);
      _WinMM.resetIn(_h);
      _WinMM.closeIn(_h);
    }
    _h = 0;
    name = null;
    _cb?.close();
    _cb = null;
  }
}

class WinMidiOut extends MidiOut {
  WinMidiOut({this.dry = false}) {
    _rx.listen((m) {
      if (m is SendPort) {
        _tx = m;
        for (final q in _queue) {
          m.send(q);
        }
        _queue.clear();
      } else if (m is List && m[0] == 'err') {
        onError?.call();
      }
    });
    Isolate.spawn(_senderMain, <Object>[_rx.sendPort, dry]);
  }
  final bool dry;
  final _rx = ReceivePort();
  SendPort? _tx;
  final List<List<Object>> _queue = []; // 送信の Isolate が立ち上がる前の分
  int _h = 0;
  String? _name;

  void _post(List<Object> m) => _tx == null ? _queue.add(m) : _tx!.send(m);

  @override
  Future<List<String>> ports() async => dry ? ['（送らない）'] : _WinMM.list().where((s) => s.isNotEmpty).toList();
  @override
  String? get openName => _name;
  @override
  double get lookaheadMs => 150;
  @override
  bool get canFlush => true;

  @override
  Future<bool> open(String name) async {
    close();
    if (dry) {
      _name = name;
      return true;
    }
    final i = _WinMM.list().indexOf(name);
    if (i < 0) return false;
    final ph = calloc<IntPtr>();
    final r = _WinMM.openOut(ph, i, 0, 0, 0);
    _h = r == 0 ? ph.value : 0;
    calloc.free(ph);
    if (_h == 0) return false;
    _name = name;
    _post(['h', _h]);
    _in.open(name);
    return true;
  }

  late final WinMidiIn _in = WinMidiIn((d) => onInput?.call(d));
  @override
  String? get inName => _in.name;

  @override
  void close() {
    _in.close();
    _post(['f']);
    _post(['h', 0]);
    if (_h != 0) {
      _WinMM.reset(_h);
      _WinMM.closeOut(_h);
    }
    _h = 0;
    _name = null;
  }

  @override
  void send(Uint8List d, double atMs) => _post(['s', atMs, d]);

  @override
  void flushPending() => _post(['f']);

  @override
  Future<String?> stats() async {
    final rp = ReceivePort();
    _post(['st', rp.sendPort]);
    final r = await rp.first.timeout(const Duration(seconds: 2), onTimeout: () => null);
    rp.close();
    return r as String?;
  }
}

// ---------------- Mac（CoreMIDI。flutter_midi_command に時刻を指定して送る） ----------------
final class _Timebase extends Struct {
  @Uint32()
  external int numer;
  @Uint32()
  external int denom;
}

class MacMidiOut extends MidiOut {
  final MidiCommand _cmd = MidiCommand();
  MidiDevice? _dev;
  final Map<String, MidiDevice> _byName = {};
  late final int Function() _machNow;
  double _ticksPerMs = 1e6; // mach 時刻の 1 ミリ秒
  int Function(int)? _flush;

  MacMidiOut() {
    final proc = DynamicLibrary.process();
    _machNow = proc.lookupFunction<Uint64 Function(), int Function()>('mach_absolute_time');
    final tbInfo = proc.lookupFunction<Int32 Function(Pointer<_Timebase>), int Function(Pointer<_Timebase>)>('mach_timebase_info');
    final tb = calloc<_Timebase>();
    if (tbInfo(tb) == 0 && tb.ref.numer != 0) _ticksPerMs = 1e6 * tb.ref.denom / tb.ref.numer;
    calloc.free(tb);
    try {
      final cm = DynamicLibrary.open('/System/Library/Frameworks/CoreMIDI.framework/CoreMIDI');
      _flush = cm.lookupFunction<Int32 Function(Uint32), int Function(int)>('MIDIFlushOutput');
    } catch (_) {}
    // 本体からの入力（connectToDevice で入力もつながる。1 パケット = 1 メッセージ）
    _cmd.onMidiPacketReceived?.listen((p) {
      final d = _dev;
      if (d != null && p.device.id == d.id && p.data.isNotEmpty) onInput?.call(p.data);
    });
  }

  @override
  String? get inName => _dev != null && _dev!.outputPorts.isNotEmpty ? _dev!.name : null;

  @override
  Future<List<String>> ports() async {
    final devs = await _cmd.devices ?? [];
    _byName.clear();
    for (final d in devs) {
      if (d.inputPorts.isEmpty || d.type == MidiDeviceType.ownVirtual) continue; // 送れない（出力だけの）機器・このアプリ自身の仮想ポート
      _byName[d.name] = d;
    }
    return _byName.keys.toList();
  }

  @override
  String? get openName => _dev?.name;
  @override
  double get lookaheadMs => 200;
  @override
  bool get canFlush => _flush != null;

  @override
  Future<bool> open(String name) async {
    close();
    await ports();
    final d = _byName[name];
    if (d == null) return false;
    try {
      await _cmd.connectToDevice(d);
    } catch (_) {
      return false;
    }
    _dev = d;
    return true;
  }

  @override
  void close() {
    final d = _dev;
    _dev = null;
    if (d != null) {
      try {
        _cmd.disconnectDevice(d);
      } catch (_) {}
    }
  }

  @override
  void send(Uint8List d, double atMs) {
    final dev = _dev;
    if (dev == null) return;
    final ahead = atMs - nowMs();
    final ts = _machNow() + (ahead > 0 ? (ahead * _ticksPerMs).round() : 0);
    _cmd.sendData(d, deviceId: dev.id, timestamp: ts);
  }

  @override
  void flushPending() {
    try {
      _flush?.call(0); // 0 = すべての出力先の予約を取り消す
    } catch (_) {}
  }
}

/// 確認用: 何も送らない出力（Mac 用。Windows は WinMidiOut(dry: true)）
class DryMidiOut extends MidiOut {
  int _sent = 0;
  @override
  Future<List<String>> ports() async => ['（送らない）'];
  @override
  Future<bool> open(String name) async => true;
  @override
  void close() {}
  @override
  String? get openName => '（送らない）';
  @override
  String? get inName => null;
  @override
  double get lookaheadMs => 0;
  @override
  bool get canFlush => true;
  @override
  void send(Uint8List d, double atMs) => ++_sent;
  @override
  void flushPending() {}
  @override
  Future<String?> stats() async => '送った $_sent';
}

// ---------------- スリープ防止 ----------------
class KeepAwake {
  static int _macId = 0;
  static void on() {
    try {
      if (Platform.isWindows) {
        final k = DynamicLibrary.open('kernel32.dll');
        final f = k.lookupFunction<Uint32 Function(Uint32), int Function(int)>('SetThreadExecutionState');
        f(0x80000000 | 0x00000001 | 0x00000002); // ES_CONTINUOUS | ES_SYSTEM_REQUIRED | ES_DISPLAY_REQUIRED
      } else if (Platform.isMacOS && _macId == 0) {
        final cf = DynamicLibrary.open('/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation');
        final iokit = DynamicLibrary.open('/System/Library/Frameworks/IOKit.framework/IOKit');
        final mk = cf.lookupFunction<Pointer<Void> Function(Pointer<Void>, Pointer<Utf8>, Uint32), Pointer<Void> Function(Pointer<Void>, Pointer<Utf8>, int)>(
            'CFStringCreateWithCString');
        final create = iokit.lookupFunction<Int32 Function(Pointer<Void>, Uint32, Pointer<Void>, Pointer<Uint32>),
            int Function(Pointer<Void>, int, Pointer<Void>, Pointer<Uint32>)>('IOPMAssertionCreateWithName');
        final type = 'PreventUserIdleDisplaySleep'.toNativeUtf8(), name = 'kitplayer'.toNativeUtf8();
        final id = calloc<Uint32>();
        if (create(mk(nullptr, type, 0x08000100), 255, mk(nullptr, name, 0x08000100), id) == 0) _macId = id.value;
        calloc.free(id);
        calloc.free(type);
        calloc.free(name);
      }
    } catch (_) {}
  }

  static void off() {
    try {
      if (Platform.isWindows) {
        final k = DynamicLibrary.open('kernel32.dll');
        k.lookupFunction<Uint32 Function(Uint32), int Function(int)>('SetThreadExecutionState')(0x80000000);
      } else if (Platform.isMacOS && _macId != 0) {
        final iokit = DynamicLibrary.open('/System/Library/Frameworks/IOKit.framework/IOKit');
        iokit.lookupFunction<Int32 Function(Uint32), int Function(int)>('IOPMAssertionRelease')(_macId);
        _macId = 0;
      }
    } catch (_) {}
  }
}
