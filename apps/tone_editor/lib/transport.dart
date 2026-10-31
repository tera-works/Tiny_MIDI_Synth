import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_libserialport/flutter_libserialport.dart';

/// 1 行ずつやりとりする通信路（本体のシリアル / デモ用の模擬本体）
abstract class LineTransport {
  Stream<String> get lines;
  void sendLine(String line);
  Future<void> close();
  String get label;
}

/// COM ポートの候補
class PortInfo {
  final String name;
  final String description;
  final bool looksLikeKit; // TinyKeyboard（本体）らしい
  PortInfo(this.name, this.description, this.looksLikeKit);
}

List<PortInfo> listPorts() {
  final result = <PortInfo>[];
  for (final name in SerialPort.availablePorts) {
    String desc = '';
    bool kit = false;
    final p = SerialPort(name);
    try {
      // description は Windows の日本語の説明（ANSI）が文字化けするので、USB の製品名・メーカー名だけ使う
      final parts = [p.productName, p.manufacturer].whereType<String>().where((s) => s.isNotEmpty && !s.contains('�'));
      desc = parts.toSet().join(' / ');
      final lower = desc.toLowerCase();
      kit = lower.contains('tinykeyboard') || lower.contains('rp2040') || lower.contains('waveshare') || lower.contains('pico');
    } catch (_) {
      // 情報が読めないポートもある
    } finally {
      p.dispose();
    }
    result.add(PortInfo(name, desc, kit));
  }
  result.sort((a, b) => (b.looksLikeKit ? 1 : 0) - (a.looksLikeKit ? 1 : 0));
  return result;
}

/// USB シリアル（本体の USB CDC）
class SerialTransport implements LineTransport {
  final String portName;
  final SerialPort _port;
  late final SerialPortReader _reader;
  final _lines = StreamController<String>.broadcast();
  StreamSubscription<String>? _sub;

  SerialTransport._(this.portName) : _port = SerialPort(portName);

  static SerialTransport open(String portName) {
    final t = SerialTransport._(portName);
    if (!t._port.openReadWrite()) {
      final err = SerialPort.lastError;
      t._port.dispose();
      throw Exception('$portName を開けませんでした（${err?.message ?? '不明'}）。ほかのソフト（Arduino IDE のシリアルモニタ、kittest など）が使っていないか確認してください');
    }
    final cfg = SerialPortConfig()
      ..baudRate = 115200
      ..bits = 8
      ..stopBits = 1
      ..parity = SerialPortParity.none
      ..dtr = SerialPortDtr.on // TinyUSB は DTR が立っていないと「つながっていない」扱いになる
      ..rts = SerialPortRts.on;
    cfg.setFlowControl(SerialPortFlowControl.none);
    t._port.config = cfg;
    cfg.dispose();
    t._reader = SerialPortReader(t._port);
    t._sub = t._reader.stream
        .map((b) => b.toList())
        .transform(const Utf8Decoder(allowMalformed: true).cast<List<int>, String>())
        .transform(const LineSplitter())
        .listen((l) => _addLine(t, l), onError: (Object e) => t._lines.addError(e));
    return t;
  }

  static void _addLine(SerialTransport t, String l) {
    final s = l.trimRight();
    if (s.isNotEmpty) t._lines.add(s);
  }

  @override
  Stream<String> get lines => _lines.stream;

  @override
  String get label => portName;

  @override
  void sendLine(String line) {
    final bytes = Uint8List.fromList(utf8.encode('$line\n'));
    var off = 0;
    while (off < bytes.length) {
      final n = _port.write(Uint8List.sublistView(bytes, off), timeout: 500);
      if (n <= 0) throw Exception('送信できませんでした（本体が外れた可能性）');
      off += n;
    }
  }

  @override
  Future<void> close() async {
    await _sub?.cancel();
    _reader.close();
    _port.close();
    _port.dispose();
    await _lines.close();
  }
}
