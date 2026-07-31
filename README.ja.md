# EyeBreak

[![CI](https://github.com/TadFuji/eyebreak/actions/workflows/ci.yml/badge.svg)](https://github.com/TadFuji/eyebreak/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

目の疲れ対策の「**20-20-20 ルール**」（20分ごとに、20フィート＝約6m 以上遠くを、20秒見る）を
習慣にするための、小さな macOS メニューバー常駐アプリです。

**Swift 1ファイル。依存ゼロ。Xcode プロジェクト不要。通知の許可ダイアログも不要。**

[English README is here](README.md)

## 動作

20分ごとに、画面右上に通知そっくりの小さなパネルが出て、
「遠くを見て 20 → 19 → …」とカウントダウンします。

- 開始時に低い合図音（Submarine / E4）
- 毎秒「ピッ」（内蔵の Tink / F5）× 20回。**最後の3回だけ少し大きく**鳴るので、
  窓の外を見たままでも「あと3秒」が分かります
- 20秒たつと「ピロリロリン」（F5→A5→C6→F6 の上昇アルペジオをその場で合成）

`Esc` キーかパネルのクリックで、今回の休憩をスキップできます。
メニューバーの目のアイコンから「今すぐ休憩」「1時間停止」「終了」が選べます。
「終了」しても、次のログインで自動的に戻ってきます。

## インストール

Xcode Command Line Tools が必要です（未導入なら `xcode-select --install`）。

```sh
git clone https://github.com/TadFuji/eyebreak.git
cd eyebreak
bash build.sh
```

`build.sh` が全部やります: コンパイル → 自動セルフチェック（失敗したら中断）→
`~/Applications/EyeBreak.app` へ設置 → ログイン時の自動起動を登録 → 起動。
何度実行しても安全で、更新時もこの1コマンドだけです。

「開発元を確認できません」の警告は出ません。あの警告はダウンロードした
ファイルに付く目印（quarantine 属性）に反応するもので、手元でビルドした
アプリには付かないためです。

## 使い方

| したいこと | 操作 |
|---|---|
| 休憩を今すぐ試す | メニューバーの目のアイコン →「今すぐ休憩」 |
| 出ているお知らせを消す | `Esc` キー、またはパネルをクリック |
| 会議などでしばらく静かに | 目のアイコン →「1時間停止」 |
| 今日はもう鳴らさない | 目のアイコン →「終了」（次のログインで復活） |

> ⚠️ このアプリは音が主役です。**Mac がミュートだと何も聞こえません。**
> また、集中モード（おやすみモード）では自動的に黙りません。
> 会議中は「1時間停止」を使ってください。

## 設定を変える

`main.swift` の先頭にある数行を書き換えて、`bash build.sh` を実行するだけです。

| 変えたいもの | 書き換える場所 |
|---|---|
| 20分の間隔 | `interval` の `20 * 60`（秒数） |
| ピッの音量 | `beepVolume` / `accentVolume`（0.0〜1.0） |
| チャイムの音程 | `chimeNotes`（周波数 Hz。今は F5 A5 C6 F6） |
| チャイムの速さ | `chimeIOI`（音と音の間隔・秒） |

20分待たずに動作を試すには:

```sh
launchctl bootout gui/$(id -u)/com.user.eyebreak
EYEBREAK_INTERVAL=5 ~/Applications/EyeBreak.app/Contents/MacOS/EyeBreak
```

5秒ごとに休憩が出ます。`Ctrl + C` で止めて、`bash build.sh` で常駐に戻します。

## 自動起動を止める・完全に削除する

自動起動だけ止める（アプリは残す）:

```sh
launchctl bootout gui/$(id -u)/com.user.eyebreak
launchctl disable gui/$(id -u)/com.user.eyebreak
```

完全に削除する:

```sh
launchctl bootout gui/$(id -u)/com.user.eyebreak
launchctl disable gui/$(id -u)/com.user.eyebreak
osascript -e 'tell application "Finder" to delete POSIX file "'"$HOME"'/Library/LaunchAgents/com.user.eyebreak.plist"'
osascript -e 'tell application "Finder" to delete POSIX file "'"$HOME"'/Applications/EyeBreak.app"'
```

途中で「"ターミナル"から"Finder"を制御することを許可しますか?」と聞かれたら
「OK」を押してください。消したものは**ごみ箱に入るだけ**なので、元に戻せます。

## しくみのメモ

- 「ピッ」は内蔵音を全部スペクトル解析して選びました。`Tink.aiff` は
  34ミリ秒・倍音なしの純音・F5（698Hz）で、「ピッ」の理想形が OS に同梱されています
- 終了チャイムの1音目を同じ F5 に合わせてあるので、ビープとチャイムが同じ調に聞こえます
- 通知バナーでなく自作パネルなのは、本物の通知では毎秒のカウントダウン表示と
  Esc キーが技術的に不可能なためです（しかも許可ダイアログが必要になります）
- 画面が消えているとき・ロック中は鳴りません
- Esc の検知は休憩中の20秒間だけ。特別な権限（入力監視など）は一切要りません

## ライセンス

[MIT](LICENSE)
