#!/bin/sh
# kitplayer を Mac で起動する（ダブルクリックで Terminal が開く）。
# 初回や kitplayer.c を更新したときは自動でビルドする。このファイルの隣の「最適化後」フォルダを再生する。
cd "$(dirname "$0")"
if [ ! -x ./kitplayer ] || [ kitplayer.c -nt kitplayer ]; then
  echo "kitplayer をビルドしています…"
  if ! clang -O2 -Wno-deprecated-declarations -o kitplayer kitplayer.c -framework CoreMIDI -framework CoreFoundation; then
    echo "ビルドに失敗しました（初回は Terminal で xcode-select --install を実行して開発ツールを入れてください）"
    echo "Enter キーで閉じます"; read _; exit 1
  fi
fi
# 再生中はスリープ・画面オフにしない（caffeinate）
caffeinate -dis ./kitplayer "$@"
echo "Enter キーで閉じます"; read _
