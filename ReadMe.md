# mac-ime

[English](./ReadMe.en.md)

IMEパッチの入っていないEmacsでIMEを快適に使うための拡張機能です。
macOSのキー入力イベントをフックして、プリフィックスキーが押されたり、ミニバッファの入力時などに自動的にIMEをOFFにしコマンド実行後に復帰します。
Emacsのダイナミックモジュール機能を利用してOSのIMEを制御しているためIMEパッチなしのEmacsでもストレスなく日本語入力ができます。

## 特徴

- **キーイベントのフック**: `NSEvent` を監視し、特定のキー入力や修飾キーの状態変化をEmacs側で検知します。
- **IME制御**: 現在の入力ソース（IME）の取得や変更が可能です。
- **高速な動作**: Objective-Cで書かれたダイナミックモジュールにより、低レイテンシでイベントを処理します。

## 必要要件

- macOS
- Emacs 27.1 以上 (ダイナミックモジュールサポートが有効であること)
- Clang (ビルド用)

## インストール

`mac-ime` はダイナミックモジュール (`mac-ime-module.so`) を使用します。

リポジトリ内にファットバイナリーで作成したモジュールを登録しているため、リポジトリのクローンをすればビルドは不要です。
また、モジュールファイルが存在しない場合やバージョンが古い場合であっても、`mac-ime-enable`実行時に GitHub Releases から適切なモジュールを `curl` を使って自動的にダウンロード・配置します。

手動でモジュールをダウンロード・更新したい場合は、`M-x mac-ime-download-module` を実行してください。

Emacs 29以降では `use-package` の `:vc` キーワードを使用してインストールできます。

### リポジトリをクローンする場合

1. リポジトリをクローンします。

```bash
git clone https://github.com/ma0001/mac-ime.git
```

2. `init.el` などに以下の設定を追加してください。

基本設定は以下だけです

```elisp
;; ロードパスの追加 (リポジトリのパスに合わせて変更してください)
(add-to-list 'load-path "/path/to/mac-ime")
(require 'mac-ime)
;; input methodgを"mac-ime"に設定
(setq default-input-method "mac-ime")
;; モジュールの有効化 (イベント監視の開始)
(mac-ime-enable)
```

3. アップデート

アップデートする場合は、リポジトリをpullしてください

```bash
cd /path/to/mac-ime
git pull
```

### use-package :vc を使用する場合 (Emacs 29以降)

Emacs 29以降では `use-package` の `:vc` キーワードを使用してインストールできます。
`init.el` などに以下の設定を追加してください。

```elisp
(use-package mac-ime
  :vc (:url "https://github.com/ma0001/mac-ime")
  :config
  ;; input methodを"mac-ime"に設定
  (setq default-input-method "mac-ime")
  ;; モジュールの有効化
  (mac-ime-enable))
```

アップデート方法は　`M-x package-vc-upgrade`　または　`M-x package-upgrade-all`　でできます。
（list-packagesでは'U'表示されない）

> [!IMPORTANT]
> `mac-ime` はダイナミックモジュール (`.so`) を使用しています。  `package-upgrade-all`
> でファイル更新はできますが、`module-load` 済みのモジュール本体は同じ Emacs
> プロセス内で完全に差し替えできません。  アップデート後は Emacs を再起動してください。
> `mac-ime-unload-function` はタイマー・フック・advice の後始末を行いますが、
> モジュール本体のアンロードではありません。

## トラブルシューティング

### `library load disallowed by system policy` が出る、またはモジュールが読み込めない

`mac-ime` はモジュールのロード前に自動的に `com.apple.quarantine` 属性の解除を試みますが、権限などの理由でロードが失敗することがあります。
手動で属性を確認・解除するには以下を実行してください。

```bash
# 属性の確認
xattr -l mac-ime-module.so

# 属性の解除
xattr -d com.apple.quarantine mac-ime-module.so
```

### モジュールのバージョン不整合警告が出る

アップデート時などに「Loaded module version `X` is older than required `Y`」といった警告やエラーが表示される場合は、ロードされているモジュールが古い状態のままです。
画面の指示に従って最新モジュールをダウンロードし、**Emacs を再起動**してください。

手動で再ビルドしたい場合は、以下を実行してください。

```bash
make clean
make
```

## 起動方法

本機能が有効になるのはinput methodが"mac-ime"の場合です。
C-\ (toggle-input-method) や cmd-space などで日本語入力状態にすることによりIMEの自動オフと復帰動作を行うようになります。


### プリフィックスキー入力時のIMEオフ

日本語入力が有効な状態で `C-x` などのプリフィックスキー（後続のキー入力を待つキーバインド）を入力すると、自動的に一時的にRoman入力（英語入力）に切り替わり、コマンドの実行が完了した後に元のIME状態（日本語入力など）へ復元します。
ただし、変換中（未確定の入力文字列が存在する場合）はIMEの無効化を行いません。これにより、変換中の操作時に誤ってIMEがオフになって変換がキャンセルされるのを防ぎます。

本機能は、Emacsのアクティブなキーマップ（`key-binding`）を動的に問い合わせてプレフィックスキー判定を行います。
そのため、ユーザー自身がキーバインドをカスタマイズしている場合や、Evilモード等の外部パッケージを導入してキーマップが変更されている場合でも、特別な設定なしで自動的にプレフィックスキーとして認識されます。

> [!NOTE]
> 以前のバージョンで存在した `mac-ime-prefix-keys` および `mac-ime-modifier-action-table` による手動のキーコード設定は不要になったため、廃止・削除されました。



### ミニバッファ入力時のIMEオフ

ミニバッファへの入力時にRoman入力となり入力後に元に戻すようにするため、`mac-ime-auto-deactivate-functions` に指定してある関数では、関数実行前にRoman入力とし関数実行後に戻す処理を追加しています。

デフォルトで設定している関数は以下の通りです。

- `read-string`
- `read-char`
- `read-event`
- `read-char-exclusive`
- `read-char-choice`
- `read-no-blanks-input`
- `read-from-minibuffer`
- `completing-read`
- `y-or-n-p`
- `yes-or-no-p`
- `map-y-or-n-p`

また、`read-string` や `read-from-minibuffer` などの `inherit-input-method` 引数を持つ関数については、その引数が non-nil の場合はバッファのinput-methodが"mac-ime"かを確認し、その場合のみmacのIMEをオンするように制御しています。
設定を変更する場合は、関数シンボルのみ、または `(関数シンボル . inherit-input-methodの引数インデックス)` の形式で指定します。


また、C-uのようにコマンド実行後のキーでRoman入力として次のコマンド実行前に戻す必要があるものについては、変数mac-ime-temporary-deactivate-functionsに指定しています。（universal-argumentではC-u後の最初のキー入力しかRomanとならないため、その後の数字入力で繰り返し呼ばれるuniversal-argument--modeを登録しています）

### IMEの入力モード判定

本モジュールではmacOSの入力ソースがRomanなのか日本語などの非Romanなのかを判定する必要があるためinput source IDを正規表現を使って判定を行っています。もし特殊なIMEを使っていてこの判断が正しく動作しない場合はmac-ime-no-ime-input-source-regexpで正しくRomanを判断できるように設定してください。現在使用可能なinput source IDは(mac-ime-get-input-source-list)で取得できます。

## 検討事項いろいろ
ソフト作成中に問題となった動作と、その対策方法についてまとめる

### C-x C-x 後すぐにIME状態が復帰しない

C-x C-xのようにキーバインドの最後がプリフィックスキーの場合、コマンド実施後に再度IMEオフ状態になってしまう。

原因：

キーイベントをポーリングだけで処理していたため、プリフィックスキーの処理が遅れてコマンド実行後に動作していた。
（C-x C-x(exchange-point-and-mark)の実行後に最後のプリフィックスキーをコマンド実行後のプリフィックスキー入力と認識してしまいIMEをオフにしていた。）


対策：

キーイベントの処理をタイマーによるポーリングだけでなく、`pre-command-hook` でも行うように変更した。その際、ポーリング処理の優先度（depth）を高く設定し、IMEの復帰処理よりも先に実行されるように制御することで、コマンド実行直前のイベントを正しく処理させている。

### minibufferのIMEがONになることがある

日本語入力中にM-%で日本語の置換をした後にC-x bなどでminibaffer表示すると日本語入力の状態になる

原因：

minibufferで日本語入力すると、minibufferのcurrent-input-methodはmac-imeになる。
この状態でread-from-minibufferがINHERIT-INPUT-METHOD nilで呼ばれると、バッファ移動前にmacのIMEを一旦英語入力とするが、
その後にminibufferへの切り替えが発生する。
その時window-selection-change-functions のフックでmac-ime-update-stateの処理でIMEがバッファに合わせて日本語入力になってしまう

対策：

バッファが切り替わってからIMEを英語にしたいが難しい。
mac-ime--ignore-input-source-changeが有効な間は、バッファ変更時のIME更新処理をしないようにする
また、カレントバッファが英語の状態でminibufferに切り替わった時にも日本語に切り替わらないように、すでに英語の状態でも英語に切り替える処理を行いmac-ime--ignore-input-source-changeを有効にする


## 提供される関数

### 基本操作

- `(mac-ime-enable)`: イベントモニターを開始し、キーイベントの監視と各種フックを有効にします。
  - 起動時にモジュールの存在とバージョン整合性をチェックし、不足や不整合がある場合は自動ダウンロードを促します。
- `(mac-ime-disable)`: イベントモニター、タイマー、およびフックを停止・解除します。
- `(mac-ime-download-module &optional tag)`: 指定したタグ（デフォルトは現在のパッケージバージョンに対応する `v<version>`）のダイナミックモジュールを GitHub からダウンロードして配置します。

### IME操作

- `(mac-ime-get-input-source)`: 現在の入力ソースIDを取得します (例: `"com.apple.keylayout.US"`).
- `(mac-ime-set-input-source SOURCE-ID)`: 指定したIDの入力ソースに変更します。
- `(mac-ime-get-input-source-list)`: 利用可能な入力ソースIDのリストを取得します。
- `(mac-ime-activate-ime)`: システムのIMEをオンの状態（日本語入力など）に切り替えます。
- `(mac-ime-deactivate-ime)`: システムのIMEをオフの状態（Roman/英語）に切り替えます。

### 自動切り替え設定の追加

- `(mac-ime-auto-deactivate FUNC)`: 指定した関数 `FUNC` の実行中に自動的にIMEをオフにし、終了後に復元する設定（アドバイス）を追加します。
- `(mac-ime-temporary-deactivate FUNC)`: 指定した関数 `FUNC` の実行前に一時的にIMEをオフにする設定（アドバイス）を追加します。状態の復元は、次に新たなコマンドが実行される直前に行われます。

## カスタマイズ

- `mac-ime-auto-deactivate-functions`: 実行時に自動的にIMEを無効化する関数のリスト。デフォルトではミニバッファ入力時などにIMEをオフにします。
- `mac-ime-temporary-deactivate-functions`: 実行前に一時的にIMEを無効化し、次に新たなコマンドが開始される直前に元の状態に戻す関数のリスト。デフォルトでは `universal-argument` などが含まれます。
- `mac-ime-no-ime-input-source-regexp`: どの入力ソースが「IMEオフ（Roman/英語）」であるかを判定するための正規表現。
- `mac-ime-ime-on-input-source` / `mac-ime-ime-off-input-source`: IMEをオン/オフする際に使用する入力ソースIDを明示的に指定する場合に使用します（通常は自動判定されます）。
- `mac-ime-title-rules`: 入力ソースIDに応じてモードラインに表示するインジケータ（`[あ]` など）を決定するルール。
- `mac-ime-debug-level`: デバッグメッセージの出力レベル（0:なし、1:入力キー、2:詳細）。
- `mac-ime-functions`: キーイベントが発生した際に呼び出されるフック関数リスト。登録するフック関数は `(keycode modifiers characters characters-ignoring converting-p)` の5つの引数を受け取る必要があります。

