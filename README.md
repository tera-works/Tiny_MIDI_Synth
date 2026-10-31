# Tiny MIDI Synth（TinySynth）

RP2040-Zero を使った、USB MIDI キーボード兼シンセサイザーのキットです。
19 鍵の鍵盤・オクターブキー・アナログスティックを持ち、パソコンやスマートフォンに USB でつなぐと MIDI キーボードとして使えます。本体だけでも音が鳴ります（ベース基板はブザー／ライン出力、拡張基板を足すとスピーカー・音色ボタン 5 個・音量つまみ）。

**プロジェクトページ：<https://tera-works.pages.dev/projects/tiny-midi-synth>**

このリポジトリでは、次のものを公開しています。

| フォルダ | 中身 |
| :--- | :--- |
| [`firmware/`](firmware) | 書き込み用ファームウェア（`.uf2`） |
| [`3Dmodels/`](3Dmodels) | ケースの 3D モデル（印刷用 3MF、編集用 STEP） |
| [`windows/`](windows) | すぐに使える Windows 版アプリ（kitplayer・音色エディタ） |
| [`apps/`](apps) | アプリのソース（Flutter）と、kitplayer の HTML 版・コマンドライン版 |

***

## ファームウェア（`firmware/`）

ファームウェアは 2 種類あります。組み立てた構成に合うほうを書き込んでください。

| ファイル | 構成 |
| :--- | :--- |
| `midi_keyboard_kit_synth_BASE.uf2` | ベース基板だけ（ブザー・3.5mm ジャックのライン出力） |
| `midi_keyboard_kit_synth_EXPANSION.uf2` | 拡張基板（TDA2822 アンプ・スピーカー）あり。アンプで音が割れないよう出力を絞っています |

**書き込み方**

1. RP2040-Zero の **BOOT** ボタンを押したまま、USB ケーブルでパソコンにつなぎます。
2. `RPI-RP2` というドライブが現れたら、ボタンを離します。
3. 合う方の `.uf2` ファイルを、そのドライブにドラッグ＆ドロップします。書き込みが終わると自動で再起動します。

キットの RP2040-Zero には、出荷時に書き込み済みです。書き直すとき・更新するときに使ってください。

***

## ケースの 3D モデル（`3Dmodels/`）

ケースは 2 種類あります。

| フォルダ | 対象 | 部品 |
| :--- | :--- | :--- |
| [`standard_case/`](3Dmodels/standard_case) | ベース基板だけ（標準ケース） | 下ケース・白鍵シート・ボタン層・天板・スティック |
| [`large_case/`](3Dmodels/large_case) | ベース基板＋拡張基板（大型ケース） | 上記＋音量つまみ |

- `3mf/` … 印刷する向きに回転済みの 3MF です。ファイル名の `_x1` は印刷する個数です。
- `step/` … 組み立てた位置のままの STEP です（`assembly.step` は基板・部品を含めた組み立て図）。
- 色（白鍵シートは白、ほかは黒）と印刷の向きは、各フォルダの `印刷メモ.txt` にまとめてあります。すべてサポートなしで印刷できます。
- 組み立てには **M3×6 皿タッピングネジ 4 本**を使います。下ケースの裏から、天板の柱に締めます（接着剤は使いません）。

***

## アプリ

### kitplayer（`windows/kitplayer_windows.zip`、`apps/kitplayer/`）

フォルダの MIDI ファイルを TinySynth に流し続ける、展示用のプレーヤーです。

- **Windows 版（GUI）**：zip を展開して `kitplayer.exe` を起動します。
- **コマンドライン版**：zip の `cli/` にある `kitplayer.bat` をダブルクリックします（`kitplayer.exe` と同じフォルダの「最適化後」フォルダの曲を再生します）。Mac では `apps/kitplayer/kitplayer.command` を使います。
- **HTML 版**：`apps/kitplayer/kitplayer.html` を Chrome などのブラウザで開きます（Web MIDI を使います）。

### 音色エディタ tone editor（`windows/tone_editor_windows.zip`、`apps/tone_editor/`）

パソコンで音色を作って、本体に保存するアプリです。

- zip を展開して `tone_editor.exe` を起動し、本体の COM ポートを選んで「接続」します。本体がなくても「本体なしで試す」で画面を試せます。
- ユーザー音色を 8 つ作れます。スライダーを動かすと、すぐ本体に反映されます。
- 音色ボタン TONE1〜5 × 3 組に、内蔵の楽器とユーザー音色を割り当てられます。
- 「本体に保存」で本体のフラッシュに書き込みます。電源を切っても、ファームウェアを書き直しても残ります。
- 音色は `.tone.json` に書き出し・読み込みできます。

### ソースからビルドする

どちらも Flutter（3.47）で作っています。Windows 版は Visual Studio 2022 が必要です。

```
cd apps/tone_editor        # または apps/kitplayer/app
flutter build windows --release
```

***

## ライセンス

[MIT License](LICENSE) です。ファームウェアに含まれるサードパーティのソフトウェアとそのライセンスは、[NOTICE.txt](NOTICE.txt) に記載しています。
