# EyeBreak — 20分ごとに「遠くを見る」お知らせ

20分ごとに、画面右上に小さなお知らせが出て、20秒間カウントダウンします。
その間は毎秒「ピッ」と鳴り、20秒たつと「ピロリロリン」と鳴って終わります。
その20秒のあいだ、窓の外など**6メートル以上遠く**を見てください。

Mac にログインすると自動で動き始めます。画面上端のメニューバーに、**目のアイコン**が1つ出ます。

> ⚠️ このアプリは音が主役です。**Mac がミュートだと何も聞こえません。**
> キーボードの音量キーか、メニューバーのスピーカーアイコンでミュートを解除しておいてください。

---

## 使い方

### 休憩を今すぐ試したい
メニューバーの**目のアイコン**をクリック →「今すぐ休憩」

### 出ているお知らせを今すぐ消したい
`Esc` キーを押す。または、お知らせのパネルをクリックする。

### しばらく静かにしてほしい（会議中など）
メニューバーの**目のアイコン**をクリック →「1時間停止」

### 今日はもう鳴らないでほしい
メニューバーの**目のアイコン**をクリック →「終了（今日はもう鳴らさない）」

次に Mac にログインしたときに、自動で戻ってきます。

---

## 止める・消す

### ログイン時の自動起動を止めたい（アプリは残す）

**ターミナル**（`アプリケーション` → `ユーティリティ` の中）を開いて、
次の2行をまとめてコピーし、貼り付けて `return` キーを押してください。

```bash
launchctl bootout gui/$(id -u)/com.user.eyebreak
launchctl disable gui/$(id -u)/com.user.eyebreak
```

またオンに戻したいときは、次の2行です。

```bash
launchctl enable gui/$(id -u)/com.user.eyebreak
launchctl bootstrap gui/$(id -u) "$HOME/Library/LaunchAgents/com.user.eyebreak.plist"
```

### 完全に削除したい

**ターミナル**で、次の4行をまとめてコピーし、貼り付けて `return` キーを押してください。

```bash
launchctl bootout gui/$(id -u)/com.user.eyebreak
launchctl disable gui/$(id -u)/com.user.eyebreak
osascript -e 'tell application "Finder" to delete POSIX file "'"$HOME"'/Library/LaunchAgents/com.user.eyebreak.plist"'
osascript -e 'tell application "Finder" to delete POSIX file "'"$HOME"'/Applications/EyeBreak.app"'
```

途中で「"ターミナル"から"Finder"を制御することを許可しますか?」と聞かれたら、
**「OK」を押してください。**押さないと削除されません。

消したものは**ごみ箱に入るだけ**です。間違えたと思ったら、ごみ箱から元に戻せます。

`システム設定` → `一般` → `ログイン項目と機能拡張` に `EyeBreak` の名前がしばらく
残って見えることがありますが、次回ログイン時に消えます。放っておいて大丈夫です。

---

## 設定を変えたい

`main.swift` の先頭にある「Knobs」の数行を書き換えてから、**ターミナル**で次の1行を実行します。

```bash
bash "/Users/hiro/Vision recovery/build.sh"
```

これだけで、作り直し → 動作チェック → 入れ替え → 再起動まで全部やります。

| 変えたいもの | 書き換える場所 |
|---|---|
| 20分の間隔 | `interval` の `20 * 60`（秒数） |
| ピッの音量 | `beepVolume` / `accentVolume`（0.0〜1.0） |
| 終了チャイムの音程 | `chimeNotes`（周波数 Hz。今は F5 A5 C6 F6） |
| チャイムの速さ | `chimeIOI`（音と音の間隔・秒） |

間隔だけなら、作り直さずに一時的に変えることもできます（テスト用）。

```bash
launchctl bootout gui/$(id -u)/com.user.eyebreak
EYEBREAK_INTERVAL=5 "$HOME/Applications/EyeBreak.app/Contents/MacOS/EyeBreak"
```

5秒ごとに休憩が出ます。`Ctrl + C` で止めて、次の1行で元に戻します。

```bash
launchctl bootstrap gui/$(id -u) "$HOME/Library/LaunchAgents/com.user.eyebreak.plist"
```

---

## 中身のしくみ（メモ）

- 本体は `main.swift` 1ファイルだけ。外部ライブラリはゼロ
- 「ピッ」は macOS 内蔵の `Tink.aiff`（F5・34ミリ秒の純音）
- 開始の合図は内蔵の `Submarine.aiff`（E4）
- 終了チャイムはその場で合成（F5→A5→C6→F6 の上昇。内蔵音に上昇する音がないため）
- 画面が消えているとき・ロック中は鳴りません
- 集中モードでは**自動的には黙りません**（黙らせたいときはメニューから「1時間停止」）
