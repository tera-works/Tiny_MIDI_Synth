import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import 'builtin_table.dart';
import 'device.dart';
import 'mock_device.dart';
import 'param_widgets.dart';
import 'params.dart';
import 'presets.dart';
import 'piano.dart';
import 'transport.dart';

void main() => runApp(const ToneEditorApp());

class ToneEditorApp extends StatelessWidget {
  const ToneEditorApp({super.key, this.client});
  final DeviceClient? client; // テスト用に差し替えられる
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'キーボードキット 音色エディタ',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: const Color(0xFF3F6FD8), useMaterial3: true),
      darkTheme: ThemeData(colorSchemeSeed: const Color(0xFF3F6FD8), useMaterial3: true, brightness: Brightness.dark),
      home: HomePage(client: client),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key, this.client});
  final DeviceClient? client;
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with SingleTickerProviderStateMixin {
  late final DeviceClient dev = widget.client ?? DeviceClient();
  late final TabController tabs = TabController(length: 3, vsync: this);

  // 接続前
  List<PortInfo> ports = [];
  String? portName;
  bool busy = false;

  // 本体から読んだ内容
  List<String> names = [for (final b in kBuiltinInstruments) b.$1];
  List<Patch> user = [];
  Assignment assign = Assignment(List.of(MockDevice.defaultTones));
  int slot = 0;
  bool unsaved = false; // 本体の RAM には反映したが、フラッシュに保存していない
  bool audition = true; // 編集中の音色を本体の鍵盤で鳴らす
  int pianoLow = 48;
  int baseIndex = 0; // 読み込む元の楽器
  Timer? _sendTimer, _assignTimer;
  final _nameCtl = TextEditingController();

  int get userBase => dev.info?.userBase ?? kBuiltinInstruments.length;

  @override
  void initState() {
    super.initState();
    dev.addListener(_onDev);
    _refreshPorts();
  }

  @override
  void dispose() {
    _sendTimer?.cancel();
    _assignTimer?.cancel();
    dev.removeListener(_onDev);
    tabs.dispose();
    _nameCtl.dispose();
    super.dispose();
  }

  void _onDev() {
    if (mounted) setState(() {});
  }

  void _refreshPorts() {
    try {
      ports = listPorts();
    } catch (e) {
      ports = [];
    }
    if (portName == null || !ports.any((p) => p.name == portName)) {
      portName = ports.isNotEmpty ? ports.first.name : null;
    }
    setState(() {});
  }

  void _toast(String msg, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: error ? Theme.of(context).colorScheme.error : null,
      duration: Duration(seconds: error ? 6 : 2),
    ));
  }

  Future<void> _run(Future<void> Function() f) async {
    setState(() => busy = true);
    try {
      await f();
    } catch (e) {
      _toast('$e', error: true);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> connect({bool demo = false}) => _run(() async {
        final LineTransport t;
        if (demo) {
          t = MockDevice();
        } else {
          final name = portName;
          if (name == null) throw DeviceException('COM ポートを選んでください');
          t = SerialTransport.open(name);
        }
        await dev.connect(t);
        await _readAll();
        _toast('${dev.label} につながりました（ファーム ${dev.info!.firmware}）');
      });

  Future<void> _readAll() async {
    names = await dev.names();
    final u = <Patch>[];
    for (var k = 0; k < dev.info!.numUser; k++) {
      u.add(await dev.getPatch(userBase + k));
    }
    user = u;
    assign = await dev.getAssign();
    slot = slot.clamp(0, user.length - 1);
    _nameCtl.text = user[slot].name;
    unsaved = false;
    if (audition) await dev.selectOnKeyboard(userBase + slot);
    if (mounted) setState(() {});
  }

  // ---- 音色の編集 ----
  Patch get cur => user[slot];

  void _selectSlot(int k) {
    _flushSend();
    setState(() {
      slot = k;
      _nameCtl.text = user[k].name;
    });
    if (audition) _run(() => dev.selectOnKeyboard(userBase + k));
  }

  void _changed() {
    setState(() => unsaved = true);
    _sendTimer?.cancel();
    _sendTimer = Timer(const Duration(milliseconds: 120), _flushSend);
  }

  void _flushSend() {
    if (_sendTimer == null) return;
    _sendTimer?.cancel();
    _sendTimer = null;
    if (!dev.connected || user.isEmpty) return;
    final k = slot;
    final p = cur.copy();
    dev.setPatch(k, p).then((_) {
      if (mounted) setState(() => names[userBase + k] = sanitizeName(p.name));
    }).catchError((Object e) => _toast('$e', error: true));
  }

  void _setParam(ParamDef d, int v) {
    if (d.ext) {
      cur.ext[d.index] = d.clamp(v);
    } else {
      cur.values[d.index] = d.clamp(v);
    }
    _changed();
  }

  void _setAlgo(int a) {
    cur.values[0] = a;
    _changed();
  }

  int _valueOf(ParamDef d) => d.ext ? cur.ext[d.index] : cur.values[d.index];

  Future<void> _loadBase() => _run(() async {
        final p = await dev.getPatch(baseIndex);
        setState(() {
          user[slot] = Patch(sanitizeName(baseIndex < userBase ? p.name : cur.name), clampParams(p.values), clampExt(p.ext));
          _nameCtl.text = user[slot].name;
        });
        _changed();
      });

  void _loadPreset(String name, List<int> p, List<int> x) {
    setState(() {
      user[slot] = Patch(sanitizeName(name), clampParams(p), clampExt(x));
      _nameCtl.text = user[slot].name;
    });
    _changed();
  }

  Future<void> _exportPatch() => _run(() async {
        final loc = await getSaveLocation(suggestedName: '${cur.name}.tone.json', acceptedTypeGroups: [
          const XTypeGroup(label: '音色', extensions: ['json'])
        ]);
        if (loc == null) return;
        final json = const JsonEncoder.withIndent('  ').convert({
          'format': 'kit-tone',
          'proto': kPatchProto,
          'name': cur.name,
          'params': {for (final d in kParams) if (!d.ext) d.key: cur.values[d.index]},
          'ext': {for (final d in kParams) if (d.ext) d.key: cur.ext[d.index]},
        });
        await File(loc.path).writeAsString(json);
        _toast('書き出しました: ${loc.path}');
      });

  Future<void> _importPatch() => _run(() async {
        final f = await openFile(acceptedTypeGroups: [
          const XTypeGroup(label: '音色', extensions: ['json'])
        ]);
        if (f == null) return;
        final m = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
        if (m['format'] != 'kit-tone') throw DeviceException('音色のファイルではありません');
        final pm = ((m['params'] ?? {}) as Map).cast<String, dynamic>();
        final xm = ((m['ext'] ?? {}) as Map).cast<String, dynamic>();
        final v = List<int>.from(cur.values), x = List<int>.from(cur.ext);
        for (final d in kParams) {
          final src = d.ext ? xm : pm;
          if (src[d.key] is num) (d.ext ? x : v)[d.index] = (src[d.key] as num).round();
        }
        setState(() {
          user[slot] = Patch(sanitizeName('${m['name'] ?? cur.name}'), clampParams(v), clampExt(x));
          _nameCtl.text = user[slot].name;
        });
        _changed();
      });

  // ---- 割り当て ----
  void _assignChanged() {
    setState(() => unsaved = true);
    _assignTimer?.cancel();
    _assignTimer = Timer(const Duration(milliseconds: 200), _flushAssign);
  }

  void _flushAssign() {
    if (_assignTimer == null) return;
    _assignTimer?.cancel();
    _assignTimer = null;
    if (!dev.connected) return;
    dev.setAssign(assign).catchError((Object e) => _toast('$e', error: true));
  }

  Future<void> _saveToFlash() => _run(() async {
        _flushSend();
        _flushAssign();
        await dev.save();
        setState(() => unsaved = false);
        _toast('本体に保存しました（電源を切っても残ります）');
      });

  Future<void> _revert() => _run(() async {
        await dev.loadSaved();
        await _readAll();
        _toast('本体に保存した内容に戻しました');
      });

  Future<void> _factoryDefaults() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('初期状態に戻す'),
        content: const Text('ユーザー音色 8 つと、音色ボタン・同時押しの順番を初期状態に戻します。\n'
            '（「本体に保存」を押すまでは、保存してある内容は消えません）'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('やめる')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('戻す')),
        ],
      ),
    );
    if (ok != true) return;
    await _run(() async {
      await dev.defaults();
      await _readAll();
      setState(() => unsaved = true);
    });
  }

  // ================= 画面 =================
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('キーボードキット 音色エディタ'),
        actions: [
          if (dev.connected) ...[
            _loadChip(),
            const SizedBox(width: 8),
            Chip(avatar: const Icon(Icons.usb, size: 18), label: Text('${dev.label}  ファーム ${dev.info!.firmware}')),
            const SizedBox(width: 8),
            TextButton.icon(onPressed: busy ? null : () => dev.disconnect(), icon: const Icon(Icons.link_off), label: const Text('切断')),
            const SizedBox(width: 8),
          ],
        ],
        bottom: dev.connected
            ? TabBar(controller: tabs, tabs: const [
                Tab(icon: Icon(Icons.tune), text: '音色を作る'),
                Tab(icon: Icon(Icons.smart_button), text: 'ボタンに割り当て'),
                Tab(icon: Icon(Icons.terminal), text: '本体のログ'),
              ])
            : null,
      ),
      body: Stack(children: [
        dev.connected ? TabBarView(controller: tabs, children: [_editorTab(), _assignTab(), _logTab()]) : _connectPanel(),
        if (busy) const Positioned(left: 0, right: 0, top: 0, child: LinearProgressIndicator()),
      ]),
      bottomNavigationBar: dev.connected ? _saveBar() : null,
    );
  }

  Widget _connectPanel() {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Card(
          margin: const EdgeInsets.all(24),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text('本体につなぐ', style: Theme.of(context).textTheme.headlineSmall),
              const SizedBox(height: 8),
              const Text('本体を USB でつなぎ、COM ポートを選んで「接続」を押してください。\n'
                  'Arduino IDE のシリアルモニタや kittest は閉じておいてください（同じポートは 1 つのソフトしか使えません）。'),
              const SizedBox(height: 16),
              Row(children: [
                Expanded(
                  child: DropdownButton<String>(
                    isExpanded: true,
                    hint: const Text('COM ポートが見つかりません'),
                    value: portName,
                    items: [
                      for (final p in ports)
                        DropdownMenuItem(
                          value: p.name,
                          child: Text('${p.name}${p.description.isNotEmpty ? '  (${p.description})' : ''}${p.looksLikeKit ? '  ← 本体' : ''}'),
                        ),
                    ],
                    onChanged: (v) => setState(() => portName = v),
                  ),
                ),
                IconButton(tooltip: '探し直す', onPressed: _refreshPorts, icon: const Icon(Icons.refresh)),
              ]),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: busy || portName == null ? null : () => connect(),
                icon: const Icon(Icons.usb),
                label: const Text('接続'),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: busy ? null : () => connect(demo: true),
                icon: const Icon(Icons.science_outlined),
                label: const Text('本体なしで試す（デモ・音は出ません）'),
              ),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _saveBar() {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      elevation: 3,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(children: [
          Icon(unsaved ? Icons.edit_note : Icons.check_circle_outline, color: unsaved ? scheme.tertiary : scheme.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(unsaved ? '変更は本体に反映済みですが、まだ保存していません（電源を切ると元に戻ります）' : '本体に保存した内容と同じです'),
          ),
          TextButton(onPressed: busy ? null : _factoryDefaults, child: const Text('初期状態に戻す')),
          const SizedBox(width: 4),
          OutlinedButton.icon(onPressed: busy ? null : _revert, icon: const Icon(Icons.undo), label: const Text('保存した内容に戻す')),
          const SizedBox(width: 8),
          FilledButton.icon(onPressed: busy ? null : _saveToFlash, icon: const Icon(Icons.save), label: const Text('本体に保存')),
        ]),
      ),
    );
  }

  // ---- 音色を作る ----
  Widget _editorTab() {
    if (user.isEmpty) return const Center(child: Text('読み込み中…'));
    final algo = cur.values[0].clamp(0, 4);
    final groups = <ParamGroup, List<ParamDef>>{};
    for (final d in kParams) {
      if (!d.visibleFor(algo)) continue;
      groups.putIfAbsent(d.group, () => []).add(d);
    }
    return Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SizedBox(
        width: 230,
        child: ListView(children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text('ユーザー音色', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
          for (var k = 0; k < user.length; k++)
            ListTile(
              selected: k == slot,
              leading: CircleAvatar(radius: 14, child: Text('${k + 1}', style: const TextStyle(fontSize: 12))),
              title: Text(user[k].name, overflow: TextOverflow.ellipsis),
              subtitle: Text(_usedWhere(userBase + k), style: const TextStyle(fontSize: 11)),
              onTap: () => _selectSlot(k),
            ),
        ]),
      ),
      const VerticalDivider(width: 1),
      Expanded(
        child: ListView(padding: const EdgeInsets.all(16), children: [
          Wrap(spacing: 12, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
            SizedBox(
              width: 300,
              child: TextField(
                controller: _nameCtl,
                decoration: const InputDecoration(labelText: '名前（英数字 15 文字・日本語 5 文字まで）', border: OutlineInputBorder()),
                onChanged: (s) {
                  cur.name = sanitizeName(s);
                  _changed();
                },
              ),
            ),
            SizedBox(
              width: 260,
              child: DropdownButton<int>(
                isExpanded: true,
                value: baseIndex.clamp(0, names.length - 1),
                items: [
                  for (var i = 0; i < names.length; i++)
                    DropdownMenuItem(value: i, child: Text(i >= userBase ? '★ ${names[i]}' : '$i ${names[i]}', overflow: TextOverflow.ellipsis)),
                ],
                onChanged: (v) => setState(() => baseIndex = v ?? 0),
              ),
            ),
            OutlinedButton.icon(onPressed: busy ? null : _loadBase, icon: const Icon(Icons.download), label: const Text('この楽器を元にする')),
            MenuAnchor(
              builder: (context, ctl, _) => FilledButton.tonalIcon(
                onPressed: busy ? null : () => ctl.isOpen ? ctl.close() : ctl.open(),
                icon: const Icon(Icons.auto_awesome),
                label: const Text('シンセのプリセット'),
              ),
              menuChildren: [
                for (final (name, p, x) in kSynthPresets)
                  MenuItemButton(onPressed: () => _loadPreset(name, p, x), child: Text(name)),
              ],
            ),
            IconButton(tooltip: 'ファイルに書き出す', onPressed: busy ? null : _exportPatch, icon: const Icon(Icons.file_upload_outlined)),
            IconButton(tooltip: 'ファイルから読み込む', onPressed: busy ? null : _importPatch, icon: const Icon(Icons.file_open_outlined)),
          ]),
          const SizedBox(height: 16),
          _previewCard(),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('鳴らし方', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                Wrap(spacing: 8, runSpacing: 8, children: [
                  for (final a in [algoSyn, algoSub, algoFm, algoPluck, algoDrum])
                    ChoiceChip(
                      label: Text(kAlgoName[a]!),
                      avatar: Icon(const {
                        algoSyn: Icons.piano,
                        algoSub: Icons.graphic_eq,
                        algoFm: Icons.waves,
                        algoPluck: Icons.music_note,
                        algoDrum: Icons.album,
                      }[a], size: 18),
                      selected: algo == a,
                      onSelected: (_) => _setAlgo(a),
                    ),
                ]),
                const SizedBox(height: 6),
                Text(kAlgoHelp[algo]!, style: Theme.of(context).textTheme.bodySmall),
              ]),
            ),
          ),
          const SizedBox(height: 12),
          _loadCard(),
          LayoutBuilder(builder: (context, c) {
            final twoCols = c.maxWidth >= 1000;
            final w = twoCols ? (c.maxWidth - 12) / 2 : c.maxWidth;
            return Wrap(spacing: 12, children: [
              for (final g in ParamGroup.values)
                if (groups[g] != null)
                  SizedBox(
                    width: w,
                    child: Card(
                      margin: const EdgeInsets.only(top: 12),
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(kGroupTitle[g]!, style: Theme.of(context).textTheme.titleMedium),
                          for (final d in groups[g]!) ParamControl(def: d, value: _valueOf(d), onChanged: (v) => _setParam(d, v)),
                        ]),
                      ),
                    ),
                  ),
            ]);
          }),
        ]),
      ),
    ]);
  }

  // 重さのめやす（1 音の計算量と、この音色だけで弾ける音の数）
  Widget _loadCard() {
    final scheme = Theme.of(context).colorScheme;
    final cost = toneCost(cur.values, cur.ext);
    final n = voicesFor(cost);
    final ratio = cost / 171; // 内蔵の Saw Lead を 1 として
    final isSyn = cur.algo == algoSyn;
    final limit = isSyn ? cur.ext[23] : 0;
    final heavy = n < 32;
    final color = ratio >= 3 ? scheme.error : (ratio >= 1.8 ? Colors.orange : scheme.primary);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(children: [
          Icon(Icons.speed, color: color),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Text('重さ: 1 音 ×${ratio.toStringAsFixed(1)}', style: Theme.of(context).textTheme.titleMedium?.copyWith(color: color)),
                const SizedBox(width: 6),
                const Tooltip(message: '内蔵の Saw Lead（一番軽いシンセ音）を ×1.0 としたときの計算量。高音質の作り込みは高音質モードのときの値', child: Icon(Icons.help_outline, size: 16)),
              ]),
              const SizedBox(height: 4),
              SizedBox(width: 360, child: LinearProgressIndicator(value: (ratio / 4).clamp(0.0, 1.0), color: color)),
              const SizedBox(height: 4),
              Text(heavy
                  ? 'この音色だけなら $n 音くらいまで（本体の負荷 75% のめやす）。それより多く弾くと本体が自動で発音数を減らします'
                  : 'この音色だけなら 32 音すべて鳴らせます'),
              if (isSyn && limit > 0) Text('この音色の最大発音数: $limit 音', style: Theme.of(context).textTheme.bodySmall),
            ]),
          ),
          if (isSyn && n <= 16 && (limit == 0 || limit > n))
            FilledButton.tonal(
              onPressed: () {
                cur.ext[23] = n;
                _changed();
              },
              child: Text('最大発音数を $n 音にする'),
            ),
        ]),
      ),
    );
  }

  Widget _loadChip() {
    final l = dev.load;
    if (l == null) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    final color = l.peak >= 90 ? scheme.error : (l.peak >= 75 ? Colors.orange : scheme.primary);
    return Tooltip(
      message: '本体の処理の重さ（2 秒ごと。平均と一番重い瞬間）と、鳴っている音の数。90% を超えると本体が自動で発音数を減らします',
      child: Chip(
        avatar: Icon(Icons.memory, size: 18, color: color),
        label: Text('負荷 ${l.avg}%（最大 ${l.peak}%）  ${l.voices}/${l.limit} 音'),
      ),
    );
  }

  String _usedWhere(int inst) {
    final w = <String>[];
    for (var k = 0; k < Assignment.banks; k++) {
      for (var b = 0; b < Assignment.buttons; b++) {
        if (assign.at(k, b) == inst) w.add('組${k + 1}-TONE${b + 1}');
      }
    }
    return w.isEmpty ? '割り当てなし' : w.join('・');
  }

  Widget _previewCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Text('試聴', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(width: 12),
            Switch(
              value: audition,
              onChanged: (v) {
                setState(() => audition = v);
                if (v) _run(() => dev.selectOnKeyboard(userBase + slot));
              },
            ),
            const Expanded(child: Text('本体の鍵盤をこの音色にする（本体の鍵盤でも、下の鍵盤でも弾けます）')),
            IconButton(tooltip: '1 オクターブ下', onPressed: pianoLow > 24 ? () => setState(() => pianoLow -= 12) : null, icon: const Icon(Icons.remove)),
            Text('C${pianoLow ~/ 12 - 1}〜'),
            IconButton(tooltip: '1 オクターブ上', onPressed: pianoLow < 84 ? () => setState(() => pianoLow += 12) : null, icon: const Icon(Icons.add)),
          ]),
          const SizedBox(height: 8),
          SizedBox(
            height: 110,
            child: PianoKeyboard(
              lowNote: pianoLow,
              onDown: (n) {
                if (!audition) {
                  setState(() => audition = true);
                  dev.selectOnKeyboard(userBase + slot).catchError((Object e) => _toast('$e', error: true));
                }
                _flushSend();
                dev.noteOn(n, 100);
              },
              onUp: (n) => dev.noteOff(n),
            ),
          ),
          const SizedBox(height: 4),
          Text('鍵盤をクリックしてから、PC のキーボードの Z〜M（下の段）・Q〜I（上の段）でも弾けます。移調の設定は本体の鍵盤と同じく反映されます。',
              style: Theme.of(context).textTheme.bodySmall),
        ]),
      ),
    );
  }

  // ---- ボタンに割り当て ----
  Widget _instDropdown(int value, ValueChanged<int> onChanged) {
    final v = value >= names.length ? 0 : value;
    return DropdownButton<int>(
      isExpanded: true,
      value: v,
      items: [
        for (var i = 0; i < names.length; i++)
          DropdownMenuItem(value: i, child: Text(i >= userBase ? '★ ${names[i]}' : names[i], overflow: TextOverflow.ellipsis)),
      ],
      onChanged: (x) {
        if (x != null) onChanged(x);
      },
    );
  }

  Widget _assignTab() {
    const bankColors = [Color(0xFFE53935), Color(0xFF43A047), Color(0xFF1E88E5)];   // 本体の LED の色（組 1 赤 / 組 2 緑 / 組 3 青）
    return ListView(padding: const EdgeInsets.all(16), children: [
      Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('音色の割り当て（TONE1〜5 × 3 組 = 15 音色）', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 6),
            const Text('・拡張基板あり: 音色ボタン TONE1〜5 で組の中の音色、OCT− と OCT＋ の同時押しで組 1 → 2 → 3 → 1 と切り替わります'
                '（同じ位置のボタンの音色になります）。本体の LED の色で今の組が分かります。\n'
                '・拡張基板なし（ベース基板のみ）: 同時押しで組 1 の 5 音色を順番に切り替えます'
                '（ブザーで起動したときは Buzzer Square も含めて回ります）。\n'
                '・拡張基板は自動では見分けられないので、起動後に音色ボタンを一度押すと「拡張基板あり」の動きになります。\n'
                '・電源を入れたときは組 1 の TONE1 の音色で始まります。★ はユーザー音色です。'),
            const SizedBox(height: 12),
            LayoutBuilder(builder: (context, c) {
              final w = c.maxWidth >= 1000 ? (c.maxWidth - 24) / 3 : c.maxWidth;
              return Wrap(spacing: 12, runSpacing: 12, children: [
                for (var k = 0; k < Assignment.banks; k++)
                  SizedBox(
                    width: w,
                    child: Card(
                      margin: EdgeInsets.zero,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: BorderSide(color: bankColors[k], width: 2)),
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Row(children: [
                            Icon(Icons.circle, size: 14, color: bankColors[k]),
                            const SizedBox(width: 6),
                            Text('組 ${k + 1}', style: Theme.of(context).textTheme.titleMedium),
                            if (k == 0) ...[
                              const SizedBox(width: 8),
                              const Flexible(child: Text('（拡張基板なしの同時押しもこの 5 音色）', overflow: TextOverflow.ellipsis)),
                            ],
                          ]),
                          const SizedBox(height: 6),
                          for (var b = 0; b < Assignment.buttons; b++)
                            Row(children: [
                              SizedBox(width: 64, child: Text('TONE${b + 1}', style: const TextStyle(fontWeight: FontWeight.bold))),
                              Expanded(
                                child: _instDropdown(assign.at(k, b), (v) {
                                  assign.set(k, b, v);
                                  _assignChanged();
                                }),
                              ),
                            ]),
                        ]),
                      ),
                    ),
                  ),
              ]);
            }),
          ]),
        ),
      ),
    ]);
  }

  // ---- ログ ----
  Widget _logTab() {
    final lines = dev.log.reversed.toList();
    return ListView.builder(
      padding: const EdgeInsets.all(12),
      itemCount: lines.length,
      itemBuilder: (c, i) => Text(lines[i], style: const TextStyle(fontFamily: 'Consolas', fontSize: 12)),
    );
  }
}
