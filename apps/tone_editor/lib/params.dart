// 音色のパラメータの定義。本体（MultiSynth.h の Instrument / PARAM_RANGE、SynthExt / EXT_RANGE）と同じ順番・範囲。
// 本体の PATCH_PROTO が変わったらここも合わせる。
import 'dart:math' as math;

const int kPatchProto = 3;
const int kNumParams = 36; // 基本（内蔵の楽器と同じ 36 項目）
const int kNumExt = 40; // 拡張（シンセ・作り込みの借用）

/// 鳴らし方（algo）
const int algoSub = 0, algoFm = 1, algoPluck = 2, algoDrum = 3, algoSyn = 4;
const Set<int> kAllAlgos = {algoSub, algoFm, algoPluck, algoDrum, algoSyn};

const Map<int, String> kAlgoName = {
  algoSyn: 'シンセ',
  algoSub: 'SUB（波形＋フィルタ）',
  algoFm: 'FM',
  algoPluck: '弦モデル',
  algoDrum: 'ドラム・打楽器',
};
const Map<int, String> kAlgoHelp = {
  algoSyn: 'シンセサイザー: 発振器 2 つ＋サブ・雑音、ユニゾン、PWM、シンク、FM、24dB フィルタ、LFO、ピッチ EG、ポルタメント、モノ／レガート',
  algoSub: '内蔵の管楽器・パッド・ピアノ・合唱などと同じ作り。高音質の作り込み（ピアノの弦 3 本・合奏・声）も使える',
  algoFm: 'エレピ・ベル・マリンバなど金属的な響き',
  algoPluck: 'ギター・ベース・ハープなど、はじく弦',
  algoDrum: 'ドラムキット（鍵ごとに別の音）か、音程のある打楽器',
};

enum ParamGroup {
  basic, // 基本
  synOsc1, synOsc2, synSub, synUnison, // シンセの発振器
  osc, // SUB の波形
  amp, // 音量 EG
  filter, filterEnv, // フィルタ
  synPitch, synVoice, synLfo, // シンセの音程・発音・LFO
  fm, pluck, drum, rich,
  fx, expression,
}

const Map<ParamGroup, String> kGroupTitle = {
  ParamGroup.basic: '基本',
  ParamGroup.synOsc1: '発振器 1',
  ParamGroup.synOsc2: '発振器 2',
  ParamGroup.synSub: 'サブ・雑音',
  ParamGroup.synUnison: 'ユニゾン（音を重ねて厚く）',
  ParamGroup.osc: '波形（発振器）',
  ParamGroup.amp: '音量の変化（アンプ EG）',
  ParamGroup.filter: 'フィルタ',
  ParamGroup.filterEnv: 'フィルタの変化（フィルタ EG）',
  ParamGroup.synPitch: '音程（ピッチ EG）',
  ParamGroup.synVoice: 'ポルタメント・発音のしかた',
  ParamGroup.synLfo: 'LFO（揺れ）',
  ParamGroup.fm: 'FM（金属的な響き・エレピ・ベル）',
  ParamGroup.pluck: '弦モデル（はじく音）',
  ParamGroup.drum: 'ドラム・打楽器',
  ParamGroup.rich: '高音質の作り込み（高音質モードのときだけ）',
  ParamGroup.fx: 'エフェクト・歪み',
  ParamGroup.expression: '表情（ビブラート・減衰）',
};

class ParamDef {
  final int index; // 基本なら 0〜35、拡張なら 0〜39
  final bool ext; // 拡張パラメータか
  final String key;
  final String label;
  final String? help;
  final int min, max;
  final ParamGroup group;
  final Map<int, String>? choices; // 選択肢で選ぶもの
  final Set<int>? algos; // この鳴らし方のときだけ表示（null = いつも）
  final bool hidden;
  final String Function(int)? format; // 値の表示（null = そのまま）
  const ParamDef(this.index, this.key, this.label, this.min, this.max, this.group,
      {this.help, this.choices, this.algos, this.hidden = false, this.ext = false, this.format});
  int clamp(int v) => v < min ? min : (v > max ? max : v);
  bool visibleFor(int algo) => !hidden && (algos == null || algos!.contains(algo));
}

const Map<int, String> kWaves = {
  0: 'サイン波（丸い）',
  1: 'のこぎり波（明るい）',
  2: '矩形波（木管・ゲーム音）',
  3: '三角波（やわらかい）',
  4: 'オルガン',
  5: 'ピアノ（音域で自動）',
  6: 'ピアノ（中音域）',
  7: 'ピアノ（高音域）',
  8: '無音（雑音だけの音色用）',
  9: '矩形波（ブザー用・倍音そのまま）',
};
final Map<int, String> kWaves2 = {...kWaves, 10: 'なし（波形 1 つだけ）'};
const Map<int, String> kSynWaves = {
  0: 'のこぎり波',
  1: 'パルス波（パルス幅を変えられる）',
  2: '三角波',
  3: 'サイン波',
  4: 'オルガン',
  5: 'ピアノ',
};
final Map<int, String> kSynWaves2 = {...kSynWaves, 6: 'なし'};
const Map<int, String> kDrums = {
  0: 'GM ドラムキット（鍵ごとに別の音）',
  1: 'ティンパニ（音程あり）',
  2: 'ウッドブロック（音程あり）',
  3: '太鼓（音程あり）',
  4: 'メロディック・タム（音程あり）',
  5: 'シンセドラム（音程あり）',
  6: 'アゴゴ（音程あり）',
};
const Map<int, String> kRich = {
  0: 'なし',
  1: 'Piano（弦 3 本＋ハンマー）',
  2: 'Bright Piano',
  3: 'Honky-tonk',
  4: 'Strings（4 本の合奏）',
  5: 'Slow Strings',
  6: 'Synth Strings',
  7: 'Choir Aahs（4 人分＋声の響き）',
  8: 'Voice Lead',
};

String _signed(int v) => v > 0 ? '+$v' : '$v';
String _ms10(int v) => v == 0 ? '0' : '${v * 10} ms';
String _level(int v) => v == 0 ? '補正なし' : '${(20 * math.log(v * 4 / 128) / math.ln10) >= 0 ? '+' : ''}${(20 * math.log(v * 4 / 128) / math.ln10).toStringAsFixed(1)} dB';
String _pw(int v) => '${(50 + v * 47 / 127).round()} %';
String _ratio(int v) => '${(v / 4).toStringAsFixed(2)} : 1';

const _syn = {algoSyn};
const _sub = {algoSub};
const _subSyn = {algoSub, algoSyn};
const _notDrum = {algoSub, algoFm, algoPluck, algoSyn};

final List<ParamDef> kParams = [
  // ---- 基本 ----
  const ParamDef(0, 'algo', '鳴らし方', 0, 4, ParamGroup.basic, hidden: true),
  const ParamDef(28, 'gain', '音量', 0, 127, ParamGroup.basic),
  ParamDef(33, 'level', '大きさの補正（ほかの楽器とそろえる）', 0, 127, ParamGroup.basic, ext: true, format: _level,
      help: '内蔵の楽器はどれも同じくらいの大きさに聞こえるように補正してあり、その楽器を元にするとこの値も引き継ぐ。0 = 補正なし'),
  ParamDef(27, 'transpose', '移調 [半音]（鍵盤で弾くとき）', -36, 36, ParamGroup.basic,
      help: '-12 = 1 オクターブ下（ベースなど）', format: _signed, algos: _notDrum),
  // ---- シンセ: 発振器 ----
  ParamDef(0, 'osc1Wave', '波形', 0, 5, ParamGroup.synOsc1, ext: true, choices: kSynWaves, algos: _syn),
  const ParamDef(1, 'osc1Level', '音量', 0, 127, ParamGroup.synOsc1, ext: true, algos: _syn),
  ParamDef(2, 'pw1', 'パルス幅', 0, 127, ParamGroup.synOsc1, ext: true, algos: _syn, format: _pw, help: 'パルス波のときだけ。50% = 矩形波、細いほど鼻にかかった音'),
  ParamDef(3, 'osc2Wave', '波形', 0, 6, ParamGroup.synOsc2, ext: true, choices: kSynWaves2, algos: _syn),
  const ParamDef(4, 'osc2Level', '音量', 0, 127, ParamGroup.synOsc2, ext: true, algos: _syn),
  ParamDef(5, 'pw2', 'パルス幅', 0, 127, ParamGroup.synOsc2, ext: true, algos: _syn, format: _pw),
  ParamDef(6, 'osc2Semi', '音程 [半音]', -48, 48, ParamGroup.synOsc2, ext: true, algos: _syn, format: _signed, help: '+7 = 5 度上、+12 = 1 オクターブ上'),
  ParamDef(7, 'osc2Cents', 'ずらし [セント]', -100, 100, ParamGroup.synOsc2, ext: true, algos: _syn, format: _signed, help: '少しずらすとうなって厚くなる'),
  const ParamDef(8, 'sync', '発振器 1 に同期（ハードシンク）', 0, 1, ParamGroup.synOsc2, ext: true, algos: _syn,
      choices: {0: 'しない', 1: 'する（発振器 2 の音程を上げると「ギュイーン」）'}),
  const ParamDef(9, 'fm', '発振器 2 → 1 の FM', 0, 127, ParamGroup.synOsc2, ext: true, algos: _syn, help: '金属的・ベルのような響き'),
  const ParamDef(10, 'sub', 'サブ（1 オクターブ下の矩形）', 0, 127, ParamGroup.synSub, ext: true, algos: _syn),
  const ParamDef(11, 'noise', '雑音', 0, 127, ParamGroup.synSub, ext: true, algos: _syn),
  const ParamDef(12, 'unison', '重ねる数', 1, 4, ParamGroup.synUnison, ext: true, algos: _syn, help: '重ねるほど厚くなるが重くなる（2 で約 1.5 倍、4 で約 2.5 倍）'),
  const ParamDef(13, 'detune', '広がり [セント]', 0, 100, ParamGroup.synUnison, ext: true, algos: _syn),
  // ---- SUB の波形 ----
  const ParamDef(1, 'wave1', '波形 1', 0, 9, ParamGroup.osc, choices: kWaves, algos: _sub),
  ParamDef(2, 'wave2', '波形 2', 0, 10, ParamGroup.osc, choices: kWaves2, algos: _sub),
  ParamDef(3, 'osc2Semi', '波形 2 の音程 [半音]', -48, 48, ParamGroup.osc, algos: _sub, help: '+12 = 1 オクターブ上', format: _signed),
  ParamDef(4, 'osc2Cents', '波形 2 のずらし [セント]', -100, 100, ParamGroup.osc, algos: _sub, help: '少しずらすと厚みが出る', format: _signed),
  const ParamDef(5, 'osc2Level', '波形 2 の音量', 0, 127, ParamGroup.osc, algos: _sub),
  const ParamDef(6, 'noise', '息・雑音', 0, 127, ParamGroup.osc, algos: _sub),
  // ---- 音量 EG ----
  const ParamDef(7, 'a', 'アタック（立ち上がり）', 0, 127, ParamGroup.amp, algos: _notDrum),
  const ParamDef(8, 'd', 'ディケイ（減衰）', 0, 127, ParamGroup.amp, algos: _notDrum),
  const ParamDef(9, 's', 'サステイン（押さえ中の音量）', 0, 127, ParamGroup.amp, algos: _notDrum),
  const ParamDef(10, 'r', 'リリース（離した後の余韻）', 0, 127, ParamGroup.amp, algos: _notDrum),
  const ParamDef(17, 'ampVel', '強さの効き（弱く弾くと小さく）', 0, 127, ParamGroup.amp, ext: true, algos: _syn),
  // ---- フィルタ ----
  const ParamDef(14, 'ftype', 'フィルタの種類', 0, 4, ParamGroup.filter, ext: true, algos: _syn,
      choices: {0: 'ローパス 12dB（普通）', 1: 'ローパス 24dB（アナログシンセ風・太い）', 2: 'バンドパス（鼻にかかった音）', 3: 'ハイパス（細く）', 4: 'ノッチ（真ん中だけ削る）'}),
  const ParamDef(34, 'fmode', 'フィルタの種類', 0, 3, ParamGroup.filter, algos: _sub,
      choices: {0: 'ローパス（普通）', 1: 'バンドパス（鼻にかかった音）', 2: 'フォルマント（声っぽく）', 3: 'ハイパス（細く）'}),
  const ParamDef(11, 'cutoff', '明るさ（カットオフ）', 0, 150, ParamGroup.filter, algos: _subSyn, help: '127 ≒ 5kHz、150 ≒ 12kHz'),
  const ParamDef(12, 'reso', 'クセ（レゾナンス）', 0, 127, ParamGroup.filter, algos: _subSyn),
  const ParamDef(18, 'keyTrack', '高い音ほど明るく', 0, 127, ParamGroup.filter, algos: _subSyn),
  const ParamDef(29, 'velCut', '強く弾くほど明るく', 0, 127, ParamGroup.filter, algos: _subSyn),
  ParamDef(15, 'fenvAmt', 'フィルタ EG の深さ（± 逆向きも）', -127, 127, ParamGroup.filterEnv, ext: true, algos: _syn, format: _signed),
  const ParamDef(16, 'fenvVel', 'フィルタ EG の強さの効き', 0, 127, ParamGroup.filterEnv, ext: true, algos: _syn),
  const ParamDef(13, 'fenv', 'フィルタ EG の深さ / FM の変調の深さ', 0, 127, ParamGroup.filterEnv, algos: {algoSub, algoFm}),
  const ParamDef(14, 'fa', 'EG アタック', 0, 127, ParamGroup.filterEnv, algos: {algoSub, algoFm, algoSyn}),
  const ParamDef(15, 'fd', 'EG ディケイ', 0, 127, ParamGroup.filterEnv, algos: {algoSub, algoFm, algoSyn}),
  const ParamDef(16, 'fs', 'EG サステイン', 0, 127, ParamGroup.filterEnv, algos: {algoSub, algoFm, algoSyn}),
  const ParamDef(17, 'fr', 'EG リリース', 0, 127, ParamGroup.filterEnv, algos: {algoSub, algoFm, algoSyn}),
  // ---- シンセ: 音程・発音・LFO ----
  ParamDef(18, 'pegAmt', '弾いた瞬間の音程のずれ [半音]', -48, 48, ParamGroup.synPitch, ext: true, algos: _syn, format: _signed, help: 'シンセドラム・ブラスの立ち上がりなど。そこから元の高さへ戻る'),
  const ParamDef(19, 'pegTime', '戻る速さ（大きいほどゆっくり）', 0, 127, ParamGroup.synPitch, ext: true, algos: _syn),
  const ParamDef(22, 'voiceMode', '発音のしかた', 0, 2, ParamGroup.synVoice, ext: true, algos: _syn,
      choices: {0: 'ポリ（和音が弾ける）', 1: 'モノ（1 音ずつ・弾くたびに頭から）', 2: 'モノ レガート（つなげて弾くと音程だけ移る）'}),
  const ParamDef(20, 'glide', 'ポルタメント（音から音へ滑る時間）', 0, 127, ParamGroup.synVoice, ext: true, algos: _syn, help: '0 = なし'),
  const ParamDef(21, 'glideMode', 'ポルタメントを掛けるとき', 0, 1, ParamGroup.synVoice, ext: true, algos: _syn,
      choices: {0: 'いつも', 1: '前の鍵を押さえたまま次を弾いたときだけ'}),
  const ParamDef(23, 'maxVoices', 'この音色の最大発音数（0 = 制限なし）', 0, 16, ParamGroup.synVoice, ext: true, algos: _syn, help: '重い音色は減らすと本体の負荷を抑えられる'),
  const ParamDef(24, 'lfoWave', '波形', 0, 5, ParamGroup.synLfo, ext: true, algos: _syn,
      choices: {0: 'サイン', 1: '三角', 2: 'のこぎり（上り）', 3: 'のこぎり（下り）', 4: '矩形', 5: 'ランダム（サンプル＆ホールド）'}),
  const ParamDef(25, 'lfoRate', '速さ（0.05〜30Hz）', 0, 127, ParamGroup.synLfo, ext: true, algos: _syn),
  ParamDef(26, 'lfoDelay', '掛かり始めるまで', 0, 127, ParamGroup.synLfo, ext: true, algos: _syn, format: _ms10),
  const ParamDef(27, 'lfoPitch', '→ 音程（ビブラート）', 0, 127, ParamGroup.synLfo, ext: true, algos: _syn),
  const ParamDef(28, 'lfoFilter', '→ 明るさ（ワウ）', 0, 127, ParamGroup.synLfo, ext: true, algos: _syn),
  const ParamDef(29, 'lfoAmp', '→ 音量（トレモロ）', 0, 127, ParamGroup.synLfo, ext: true, algos: _syn),
  const ParamDef(30, 'lfoPwm', '→ パルス幅（PWM）', 0, 127, ParamGroup.synLfo, ext: true, algos: _syn),
  const ParamDef(31, 'lfoSync', '弾くたびに頭から', 0, 1, ParamGroup.synLfo, ext: true, algos: _syn, choices: {0: 'しない（自由に回る）', 1: 'する'}),
  // ---- FM / 弦 / ドラム / 作り込み ----
  ParamDef(19, 'fmRatioX4', '変調の周波数比', 1, 64, ParamGroup.fm, algos: const {algoFm}, help: '1:1 = 丸い、3.5:1 = 金属的', format: _ratio),
  const ParamDef(20, 'brightness', 'はじく強さ（明るさ）', 0, 127, ParamGroup.pluck, algos: {algoPluck}),
  const ParamDef(21, 'sustainLoss', '減衰の速さ', 0, 127, ParamGroup.pluck, algos: {algoPluck}, help: '大きいほど早く消える'),
  const ParamDef(35, 'drum', '種類', 0, 6, ParamGroup.drum, algos: {algoDrum}, choices: kDrums),
  const ParamDef(32, 'rich', '借りる作り込み', 0, 8, ParamGroup.rich, ext: true, algos: _sub, choices: kRich,
      help: '高音質モード（本体が余裕のあるときの音）で、発振器を 4 本にした厚み・ピアノの打鍵音・声の響きを足す'),
  // ---- エフェクト・表情 ----
  const ParamDef(22, 'drive', '歪み', 0, 127, ParamGroup.fx),
  ParamDef(23, 'driveType', '歪みの種類', 0, 127, ParamGroup.fx, format: (v) => v < 43 ? 'OD $v' : (v < 86 ? 'Dist $v' : 'Fuzz $v')),
  const ParamDef(24, 'rev', 'リバーブ', 0, 127, ParamGroup.fx),
  const ParamDef(25, 'cho', 'コーラス', 0, 127, ParamGroup.fx),
  const ParamDef(26, 'dly', 'ディレイ', 0, 127, ParamGroup.fx),
  const ParamDef(32, 'vib', '自動ビブラートの深さ', 0, 127, ParamGroup.expression, algos: _notDrum),
  ParamDef(33, 'vibDelay', 'ビブラートが掛かるまで', 0, 127, ParamGroup.expression, algos: _notDrum, format: _ms10),
  const ParamDef(30, 'decKt', '高い音ほど短く', 0, 127, ParamGroup.expression, algos: _notDrum),
  const ParamDef(31, 'sdec', '押さえたままでも減衰（0 = しない）', 0, 127, ParamGroup.expression, algos: _notDrum),
];

/// 基本パラメータの番号 → 定義（範囲に使う。鳴らし方で表示だけ変わる同じ番号は最初のもの）
final Map<int, ParamDef> kParamByIndex = {for (final p in kParams.reversed) if (!p.ext) p.index: p};
final Map<int, ParamDef> kExtByIndex = {for (final p in kParams.reversed) if (p.ext) p.index: p};

/// 拡張パラメータの範囲（本体の EXT_RANGE と同じ。予備は 0）
const List<(int, int)> kExtRange = [
  (0, 5), (0, 127), (0, 127), (0, 6), (0, 127), (0, 127), (-48, 48), (-100, 100), (0, 1), (0, 127),
  (0, 127), (0, 127), (1, 4), (0, 100), (0, 4), (-127, 127), (0, 127), (0, 127), (-48, 48), (0, 127),
  (0, 127), (0, 1), (0, 2), (0, 16), (0, 5), (0, 127), (0, 127), (0, 127), (0, 127), (0, 127),
  (0, 127), (0, 1), (0, 8), (0, 127), (0, 0), (0, 0), (0, 0), (0, 0), (0, 0), (0, 0),
];
/// シンセの初期値（本体の SYNTH_EXT_DEFAULT と同じ）
const List<int> kSynthExtDefault = [
  0, 127, 0, 0, 90, 0, 0, 8, 0, 0, 0, 0, 1, 12, 1, 60, 40, 80, 0, 40, 0, 0, 0, 0, 1, 70, 30, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
];

/// 基本パラメータの範囲（本体の PARAM_RANGE と同じ）
const List<(int, int)> kParamRange = [
  (0, 4), (0, 9), (0, 10), (-48, 48), (-100, 100), (0, 127), (0, 127), (0, 127), (0, 127), (0, 127),
  (0, 127), (0, 150), (0, 127), (0, 127), (0, 127), (0, 127), (0, 127), (0, 127), (0, 127), (1, 64),
  (0, 127), (0, 127), (0, 127), (0, 127), (0, 127), (0, 127), (0, 127), (-36, 36), (0, 127), (0, 127),
  (0, 127), (0, 127), (0, 127), (0, 127), (0, 3), (0, 6),
];

int _clampR((int, int) r, int v) => v < r.$1 ? r.$1 : (v > r.$2 ? r.$2 : v);

/// 値を範囲に収めた 36 個のリストにする
List<int> clampParams(List<int> v) => List<int>.generate(kNumParams, (i) => _clampR(kParamRange[i], i < v.length ? v[i] : 0));
List<int> clampExt(List<int> v) => List<int>.generate(kNumExt, (i) => _clampR(kExtRange[i], i < v.length ? v[i] : kSynthExtDefault[i]));

/// 1 音の重さのめやす（本体の 1 サンプルあたりのサイクル数。内蔵の Saw Lead ≒ 171、Flute ≒ 237）
///  シンセは実機で測った値に合わせた（2026-09-30f、16 音×4 重 = 79% など。誤差 ±10% 程度）
int toneCost(List<int> p, List<int> x) {
  switch (p[0]) {
    case algoFm:
      return 82;
    case algoPluck:
      return 101;
    case algoDrum:
      return 90;
    case algoSub:
      var c = 171;
      if (p[2] != 10) c += 35; // 波形 2
      if (p[6] > 0) c += 30; // 雑音
      if (x[32] > 0) c = (c * 1.6).round(); // 作り込み（高音質モードのとき）
      return c;
    default: // シンセ
      final u = x[12].clamp(1, 4);
      final osc2 = x[3] != 6;
      final pulse1 = x[0] == 1, pulse2 = x[3] == 1;
      int perUni;
      if (x[8] == 1 || x[9] > 0) {
        perUni = 110 + (pulse1 ? 30 : 0) + (pulse2 ? 30 : 0);
      } else {
        perUni = (pulse1 ? 57 : 27) + (osc2 ? (pulse2 ? 57 : 27) : 0);
      }
      const filterCost = [40, 76, 42, 42, 42];
      var c = 175 + u * (perUni + 20) + filterCost[x[14].clamp(0, 4)];
      if (x[10] > 0) c += 30;
      if (x[11] > 0) c += 19;
      return c;
  }
}

/// この音色だけで弾ける音の数のめやす（本体の負荷 75% まで。2 コアで分担、何も鳴っていないとき約 6%）
int voicesFor(int cost) {
  final n = ((75 - 6) / (cost * 32000 / 250e6 / 2 * 100)).floor();
  return n.clamp(1, 32);
}
