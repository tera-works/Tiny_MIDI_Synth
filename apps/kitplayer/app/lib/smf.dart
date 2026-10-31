// 標準 MIDI ファイルの読み込み（全トラックを時刻順にまとめ、時刻は秒）
import 'dart:typed_data';

class MidiEv {
  final double t; // 秒
  final Uint8List d; // 送るバイト列（SysEx は F0 から）
  const MidiEv(this.t, this.d);
}

class Song {
  final List<MidiEv> ev;
  final double dur;
  final List<int> chans; // 音を鳴らすチャンネル
  final List<List<double>> tempo; // [秒, BPM]
  Song(this.ev, this.dur, this.chans, this.tempo);

  double bpmAt(double t) {
    double b = 120;
    for (final s in tempo) {
      if (s[0] > t) break;
      b = s[1];
    }
    return b;
  }

  // 時刻 t 以上の最初のイベント
  int lowerBound(double t) {
    int lo = 0, hi = ev.length;
    while (lo < hi) {
      final m = (lo + hi) >> 1;
      if (ev[m].t < t) {
        lo = m + 1;
      } else {
        hi = m;
      }
    }
    return lo;
  }
}

class _Raw {
  final int tick, tr, ord;
  final Uint8List d;
  _Raw(this.tick, this.tr, this.ord, this.d);
}

Song parseSmf(Uint8List b) {
  final bd = ByteData.sublistView(b);
  String tag(int p) => String.fromCharCodes(b.sublist(p, p + 4));
  if (b.length < 14 || tag(0) != 'MThd') throw const FormatException('MIDI ファイルではありません');
  final hl = bd.getUint32(4), ntrk = bd.getUint16(10), div = bd.getUint16(12);
  if (div & 0x8000 != 0) throw const FormatException('SMPTE 形式には未対応');
  final raw = <_Raw>[];
  final tempos = <List<int>>[];
  int pos = 8 + hl;
  for (int tr = 0; tr < ntrk && pos + 8 <= b.length;) {
    final len = bd.getUint32(pos + 4);
    if (tag(pos) != 'MTrk') {
      pos += 8 + len;
      continue;
    }
    int i = pos + 8, t = 0, rs = 0, ord = 0;
    final end = (pos + 8 + len) < b.length ? pos + 8 + len : b.length;
    int rv() {
      int v = 0;
      while (i < end) {
        final c = b[i++];
        v = (v << 7) | (c & 127);
        if (c & 128 == 0) break;
      }
      return v;
    }

    while (i < end) {
      t += rv();
      if (i >= end) break;
      final c = b[i];
      if (c == 0xFF) {
        if (i + 1 >= end) break;
        final m = b[i + 1];
        i += 2;
        final l = rv();
        if (m == 0x51 && l == 3 && i + 3 <= end) tempos.add([t, (b[i] << 16) | (b[i + 1] << 8) | b[i + 2]]);
        i += l;
        continue;
      }
      if (c == 0xF0 || c == 0xF7) {
        i++;
        final l = rv();
        if (i + l > end) break;
        final body = b.sublist(i, i + l);
        i += l;
        Uint8List d;
        if (c == 0xF0) {
          d = Uint8List(l + 1);
          d[0] = 0xF0;
          d.setRange(1, l + 1, body);
        } else {
          d = body; // F7 は中身をそのまま
        }
        raw.add(_Raw(t, tr, ord++, d));
        continue;
      }
      if (c & 0x80 != 0) {
        rs = c;
        i++;
      }
      if (rs == 0) break;
      final nd = ((rs & 0xF0) == 0xC0 || (rs & 0xF0) == 0xD0) ? 1 : 2;
      if (i + nd > end) break;
      final d = nd == 1 ? Uint8List.fromList([rs, b[i]]) : Uint8List.fromList([rs, b[i], b[i + 1]]);
      i += nd;
      raw.add(_Raw(t, tr, ord++, d));
    }
    pos += 8 + len;
    tr++;
  }
  tempos.sort((x, y) => x[0].compareTo(y[0]));
  final segs = <List<num>>[
    [0, 0.0, 500000]
  ]; // [tick, 秒, μs/四分音符]
  for (final tp in tempos) {
    final l = segs.last;
    if (tp[0] == l[0]) {
      l[2] = tp[1];
    } else {
      segs.add([tp[0], (l[1] as double) + (tp[0] - l[0]) * l[2] / 1e6 / div, tp[1]]);
    }
  }
  double sec(int tk) {
    int lo = 0, hi = segs.length - 1;
    while (lo < hi) {
      final m = (lo + hi + 1) >> 1;
      if (segs[m][0] <= tk) {
        lo = m;
      } else {
        hi = m - 1;
      }
    }
    final s = segs[lo];
    return (s[1] as double) + (tk - s[0]) * s[2] / 1e6 / div;
  }

  raw.sort((x, y) {
    if (x.tick != y.tick) return x.tick.compareTo(y.tick);
    if (x.tr != y.tr) return x.tr.compareTo(y.tr);
    return x.ord.compareTo(y.ord);
  });
  final ev = [for (final r in raw) MidiEv(sec(r.tick), r.d)];
  final chans = <int>{};
  for (final e in ev) {
    if ((e.d[0] & 0xF0) == 0x90 && e.d.length > 2 && e.d[2] > 0) chans.add(e.d[0] & 15);
  }
  final tempo = [
    for (final s in segs) [s[1] as double, 60e6 / s[2]]
  ];
  return Song(ev, ev.isEmpty ? 0 : ev.last.t, chans.toList()..sort(), tempo);
}

bool isQualitySysEx(Uint8List d) => d[0] == 0xF0 && d.length >= 7 && d[1] == 0x7D && d[2] == 0x4B && d[3] == 0x53 && d[4] == 0x01;
bool isGmReset(Uint8List d) =>
    d[0] == 0xF0 && d.length > 4 && ((d[1] == 0x7E && d[3] == 0x09) || (d[1] == 0x41 && d[4] == 0x12) || (d[1] == 0x43 && d[3] == 0x4C));
