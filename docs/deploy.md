# チュートリアル: `cybertrain new` から本番稼働まで

`cybertrain new` でアプリを作り、Ubuntu サーバーに HTTPS 付きでデプロイして使い始める
までを、上から順にコピペで進められるように書いています。

最終的な構成は次のとおりです。

```
ブラウザ ──HTTPS──▶ Caddy (:443, 証明書を自動取得)
                     ├─ public/ は dist/public/。静的ファイルは Caddy が直接返す
                     └─ それ以外 ──HTTP──▶ dist/notes (127.0.0.1:3000, systemd)
                                              └─ /srv/notes/shared/production.sqlite3
```

- アプリは `cybertrain build` で 1 本のネイティブバイナリ（`dist/notes`）にコンパイルされます。
  ビュー（`app/views/`）はビルド時にバイナリへ埋め込まれ、`public/` は `dist/public/` に
  コピーされます。バイナリはシステムの SQLite（と libc）にリンクするので、動かすマシンと同じ
  OS・CPU でビルドする必要があります。そのため**リポジトリをサーバーに置き、サーバー上で
  ビルドする**のがこのチュートリアルのやり方です（一番ハマりにくい）。
- サーバーは TLS と HTTP/2 を話さないので、前段に Caddy を置きます。
- DB は SQLite 1 ファイルです。サーバー 1 台構成が前提です。

## この文書で使う名前

自分の値に読み替えてください。コマンド中にそのまま出てきます。

| 項目 | この文書での値 |
| --- | --- |
| アプリ名（`cybertrain new` に渡す名前。英小文字・数字・`_`） | `notes` |
| ドメイン | `notes.example.com` |
| アプリの GitHub リポジトリ（private で可） | `YOUR_GITHUB/notes` |
| サーバー | Ubuntu 24.04 LTS、x86-64 か arm64、メモリ 1GB 以上 |
| Spinel のバージョン | `2026.09.12`（`cybertrain setup` が入れるもの。[CI](../.github/workflows/ci.yml) の `SPINEL_TAG` と同じもの） |

---

## 第 1 部: 手元の開発環境

手元は Linux か macOS を想定しています（Windows は WSL2 の Ubuntu で同じ手順が使えます）。

### 1-1. 必要なパッケージ

Spinel は 1-3 で `cybertrain` コマンドが自分でビルドして入れます。Spinel のビルドには C コンパイラ・
make・git・curl が、アプリのビルドには SQLite のヘッダ／ライブラリが要ります。`cybertrain setup` は
両方がそろっているか先に確かめるので、ここで入れておきます。

Ubuntu / Debian:

```sh
sudo apt update
sudo apt install -y build-essential git curl libsqlite3-dev libssl-dev ruby-full
```

macOS: `xcode-select --install`（C コンパイラ、make、git、curl と SQLite のヘッダが入ります）。

OpenSSL（`libssl-dev`、macOS なら `brew install openssl@3`）は必須ではありません。無くても Spinel は
openssl パッケージ抜きでビルドされ、cybertrain はそれを使いません。

`cybertrain` コマンドは gem で入れるので、Ruby 3.2 以上が要ります（サーバーでも
`cybertrain build` を使うので入れます。アプリ自体は Ruby 無しで動きます）。Ubuntu 24.04 の `ruby-full` は 3.2 です。macOS 付属の Ruby は古いので、
Homebrew（`brew install ruby`）や rbenv・mise などで入れてください。

### 1-2. cybertrain の CLI をインストールする

```sh
gem install cybertrain
cybertrain version
```

gem に入っているのは `cybertrain` コマンドだけです（フレームワークも Spinel も入っていません）。
Spinel は次の 1-3 で、このコマンドが入れます。

### 1-3. Spinel をインストールする

```sh
cybertrain setup
```

`cybertrain` が固定している Spinel `2026.09.12` を、GitHub のリリースタグからビルドして
`~/.cybertrain/spinel/2026.09.12/` に入れます（`git clone` → `make deps` → `make -j` →
`make install`）。初回だけで、数分かかります（4 コアのマシンで 3 分前後でした。`make -j` は CPU の数だけ
並列に動くので、CPU が少ないほど長くかかります）。CI も Spinel を同じ `cybertrain setup` で入れています。

- 足りない道具（git・make・curl・C コンパイラ・SQLite のヘッダ／ライブラリ）があると、ビルドを始める前に
  何が足りないかとインストールのコマンドを表示して止まります。
- 各手順の出力はログ `~/.cybertrain/log/spinel-2026.09.12-build.log` に書かれます。途中で失敗したときは
  ログの末尾が表示されます。
- すでに入っている場合（`~/.cybertrain` にある、または同じリリースの `spinel` が PATH にある）は、
  `nothing to install` と表示して何もしません。`~/.cybertrain` のものを作り直したいときは
  `cybertrain setup --force` です。
- 入れ先 `~/.cybertrain/spinel/2026.09.12/` は約 13 MB です（Linux x86-64 で確認した値）。ビルド中だけ、
  ソースと中間ファイルが `~/.cybertrain/src/spinel-2026.09.12/` に 90 MB ほどでき、成功すると削除されます。

前提が足りているかは `cybertrain doctor` で確認できます（git・make・curl・cc・SQLite・OpenSSL と
Spinel を 1 行ずつ表示します。足りないものは `MISSING` と表示され、インストールのコマンドが続きます）。

`cybertrain new`・`db`・`server`・`build` は、この Spinel を自分で見つけて使うので、PATH の設定は要りません。
`spin` を直接実行したいときは `cybertrain spin ...`（例: `cybertrain spin run gen -- --check`）でも
動きます。それでも `spin` をそのまま打ちたい場合だけ、`~/.cybertrain/bin` を PATH に通します（zsh なら
`~/.zshrc`）。`~/.cybertrain/bin` には現在使っているリリースへの `spinel`・`spin` のリンクが置かれるので、
リリースが上がっても書き換えは要りません。`cybertrain setup` は、自分が入れた Spinel を使う場合に、
同じ内容の `export PATH=...` の行を表示します。

```sh
echo 'export PATH="$HOME/.cybertrain/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc
spinel --version
```

括弧の中が `2026.09.12` になっていれば OK です
（`spinel 112bae85c1a2 (2026.09.12) [cc ...]` のように表示されます）。

**補足: 手動で入れる場合**

`cybertrain setup` を使わず、Spinel を自分でビルドして入れることもできます。手順は `cybertrain setup` と
同じです。

```sh
git clone --depth 1 --branch 2026.09.12 https://github.com/matz/spinel.git ~/src/spinel
cd ~/src/spinel
make deps
make -j"$(nproc 2>/dev/null || sysctl -n hw.ncpu)"
make install PREFIX="$HOME/.local"
```

入れたものを `cybertrain` に使わせるには、次のどちらかにします。

- `~/.local/bin` に PATH を通す（`echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc`）。
  `spinel --version` が `2026.09.12` なら、`cybertrain` は PATH 上のそれをそのまま使います。別のリリース
  だと使わず、`cybertrain` が自分用のものを `~/.cybertrain` に入れます。
- 環境変数で入れ先を指定する（`~/.bashrc` に `export CYBERTRAIN_SPINEL_HOME="$HOME/.local"` を書きます）。
  そこの `spinel` が `2026.09.12` でなければ、エラーで止まります。

---

## 第 2 部: アプリを作る

### 2-1. `cybertrain new`

```sh
cd ~/src
cybertrain new notes
cd notes
git init -b main
```

1-3 で Spinel を入れてあれば `cybertrain new` はそれをそのまま使います（まだなら、最初に入れます）。

### 2-2. フレームワークの参照を確認する

`cybertrain new` は `spin.toml` に、CLI と同じバージョンのフレームワーク（GitHub のタグ）を
書きます。

```toml
[package]
name = "notes"
version = "0.1.0"

[dependencies]
cybertrain = { git = "https://github.com/saeki-mototsune/cybertrain", ref = "v0.2.0" }
```

続けて `new` が `spin lock` と `spin run gen` を実行しています。フレームワークは spin の
キャッシュ（`~/.cache/spin/packages/`）に取得され、使うコミットは `spin.lock` に固定されます。
アプリのリポジトリにフレームワークのコードは入りません。`spin.toml` と `spin.lock` を
コミットしておけば、サーバーでも同じコミットでビルドされます（Gemfile.lock と同じ役割です）。

### 2-3. 画面を作る

```sh
cybertrain generate scaffold note title:string body:text
```

トップページをノート一覧にします。`config/routes.rb`:

```ruby
Cybertrain::Routes.draw do
  root "notes#index"
  resources :notes
end
```

マイグレーションを流します。

```sh
cybertrain db migrate
```

中身は生成 → マイグレーション → 再生成の 3 段です。`spin run gen` で新しいマイグレーションを
`gen/migrations.rb` に取り込み、`spin run db -- migrate`（開発用の `bin/db.rb`）で
`storage/development.sqlite3` を作って `db/schema.rb` を書き直し、もう一度 `spin run gen` で
`db/schema.rb` と routes から `gen/` を作り直します。

### 2-4. 手元で動かす

```sh
cybertrain server
```

http://127.0.0.1:3000 を開き、ノートの作成・編集・削除ができることを確かめます。
開発モードでは Ruby のコードを保存すると自動で再ビルドされ、ビューは保存するだけで反映されます。
`Ctrl-C` で止めます。

### 2-5. （任意）`*_url` ヘルパーを使う場合

scaffold が書くのは `*_path`（`/notes/1` のような相対パス）だけなので、普通は不要です。
メール本文や JSON に絶対 URL を書くために `note_url(@note)` などを使うときは、
`config/app.rb` の末尾に本番のオリジンを書いておきます（既定値は `http://localhost:3000`）。

```ruby
Cybertrain.url_root = "https://notes.example.com" if Cybertrain.config.production?
```

### 2-6. 本番モードのリハーサル

サーバーに行く前に、手元で本番と同じ起動のしかたを一度試しておくと、設定漏れに早く気づけます。

```sh
cybertrain build
export CYBERTRAIN_SECRET_KEY_BASE="$(openssl rand -hex 32)"
export CYBERTRAIN_DATABASE="$PWD/dist/storage/rehearsal.sqlite3"
(cd dist && ./notes migrate && ./notes)
```

`cybertrain build` はビューを埋め込んだバイナリ `dist/notes` と `dist/public/` を作ります。
本番では systemd が `dist/` を作業ディレクトリにしてバイナリを起動する（5-1）ので、リハーサルも
`dist/` に入ってから `./notes` を実行します。このとき `storage/` と `public/` はアプリ直下ではなく
`dist/` にあるコピーが使われます。サブシェル `( ... )` で入るので、止めたあとのシェルは
アプリ直下のままです。
ビルドしたバイナリは既定で本番モードなので、`CYBERTRAIN_ENV` を設定する必要はありません
（開発モードで動かしたいときだけ `CYBERTRAIN_ENV=development` を付けます）。
`./notes migrate` はバイナリに組み込まれたマイグレーションを `CYBERTRAIN_DATABASE` に流します。

起動時の表示が次のようになっていれば OK です。

```
=> Booting cybertrain 0.2.0
=> production environment (1 worker)
* Listening on http://127.0.0.1:3000
```

`=> Watching app/, config/ and db/schema.rb for changes` の行が**出ていない**ことを確認して
ください（出ていたら開発モードで動いています）。

ブラウザでは **http://localhost:3000** を開いて一通り触ります。本番モードのセッション Cookie には
`Secure` 属性が付くので、ブラウザは HTTPS でしか送り返しません。例外として Chrome と Firefox は
`localhost` を安全な接続として扱うのでそのまま試せますが、`127.0.0.1` で開いたり他のブラウザを
使ったりすると、フォーム送信が `Invalid authenticity token`（403）になります。本番では Caddy が
HTTPS にするので問題ありません。

試し終わったら `Ctrl-C` で止め、環境変数を戻します。

```sh
unset CYBERTRAIN_SECRET_KEY_BASE CYBERTRAIN_DATABASE
rm -f dist/storage/rehearsal.sqlite3*
```

`dist/` は `cybertrain new` の `.gitignore` に入っているのでコミットされません。

### 2-7. コミットして GitHub に置く

`gen/` は生成物ですが**コミットします**（ビルドは `gen/` がすでに最新であることを前提にしています）。
コミット前に鮮度を確認します。

```sh
spin run gen -- --check   # 何も出ず終了コード 0 なら最新
git add -A
git commit -m "Create notes"
```

GitHub に private リポジトリ `YOUR_GITHUB/notes` を作り（README などは追加しない）、push します。

```sh
git remote add origin git@github.com:YOUR_GITHUB/notes.git
git push -u origin main
```

---

## 第 3 部: サーバーを用意する

ここからはサーバー上の作業です。sudo できるユーザーで SSH ログインできる状態から始めます。

### 3-1. DNS

ドメインの DNS に、`notes.example.com` → サーバーの IP アドレスの A レコード（IPv6 があれば
AAAA も）を登録します。第 6 部で Caddy が証明書を取るときに必要なので、先にやっておきます。

### 3-2. パッケージとファイアウォール

```sh
sudo apt update && sudo apt -y upgrade
sudo apt install -y build-essential git curl libsqlite3-dev libssl-dev sqlite3 ufw ruby-full

sudo ufw allow OpenSSH
sudo ufw allow 80,443/tcp
sudo ufw enable
```

アプリ自体は `127.0.0.1:3000` でしか待ち受けないので、3000 番は開けません。

### 3-3. アプリ専用ユーザー

アプリのビルドと実行は専用ユーザー `notes` で行います。ホームディレクトリ `/srv/notes` が
アプリの置き場になります。

```sh
sudo useradd --system --create-home --home-dir /srv/notes --shell /bin/bash notes
sudo chmod 711 /srv/notes    # Caddy が public/ まで辿れるように（中身の一覧は見せない）
```

### 3-4. `notes` ユーザーで cybertrain と Spinel をインストールする

```sh
sudo -iu notes
```

以降、**第 3 部の終わりまで `notes` ユーザーのシェル**で作業します。手順は 1-2、1-3 と同じで、先に
`cybertrain` コマンド、次に Spinel の順です。Ruby は 3-2 の `ruby-full` で入っています。

まず `cybertrain` コマンドを `notes` ユーザーのホームに入れます（デプロイスクリプトが
`cybertrain build` を使います）。実行ファイルは gem のディレクトリに入るので、`~/.local/bin` に
リンクを置いて PATH に通します。

```sh
gem install --user-install cybertrain -v 0.2.0
mkdir -p ~/.local/bin
ln -sfn "$(ruby -e 'print Gem.user_dir')/bin/cybertrain" ~/.local/bin/cybertrain
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc
cybertrain version
```

`-v` はアプリの `spin.toml` の `ref`（タグ `v0.2.0`）と同じバージョンにそろえてください。CLI と
`spin.lock` が固定するフレームワーク（`spin run gen` はそのフレームワーク自身の generator を
実行します）は対で更新するものなので、バージョンがずれるとビルドや起動が失敗します。

続けて、同じ `notes` ユーザーで Spinel を入れます。

```sh
cybertrain setup
```

1-3 と同じ処理で、初回だけ数分かかります（CPU が少ないサーバーほど長くかかります）。Spinel は `notes`
ユーザーの `~/.cybertrain/spinel/2026.09.12/`（ここでは `/srv/notes/.cybertrain/spinel/2026.09.12/`。
約 13 MB）に入り、ログは `~/.cybertrain/log/spinel-2026.09.12-build.log` に残ります。ビルド中だけ、
ソースと中間ファイルが `~/.cybertrain/src/` に 90 MB ほどできます（成功すると削除されます）。3-2 で
入れたパッケージで前提はそろっていますが、足りないと言われたら `cybertrain doctor` で確認してください。

### 3-5. デプロイキー

サーバーがアプリの private リポジトリを読めるように、読み取り専用のデプロイキーを作ります
（フレームワークは spin が `spin.lock` のコミットを公開リポジトリから取得するので鍵は不要です）。

```sh
ssh-keygen -t ed25519 -N "" -C "deploy@notes.example.com" -f ~/.ssh/id_ed25519
cat ~/.ssh/id_ed25519.pub
```

表示された公開鍵を GitHub の `YOUR_GITHUB/notes` → Settings → Deploy keys → Add deploy key
に貼ります（"Allow write access" はチェックしない）。接続を確認します。

```sh
ssh -T git@github.com
```

初回はホスト鍵の確認が出ます。表示されたフィンガープリントが
[GitHub の公開値](https://docs.github.com/ja/authentication/keeping-your-account-and-data-secure/githubs-ssh-key-fingerprints)
と一致することを確かめてから `yes` と答えてください。
`Hi YOUR_GITHUB/notes! You've successfully authenticated` と出れば OK です。

### 3-6. ディレクトリ

```sh
mkdir -p ~/releases ~/shared ~/backups
chmod 700 ~/shared ~/backups
exit    # notes ユーザーを抜けて、sudo できるユーザーに戻る
```

- `~/releases/<日時>/` … デプロイごとのチェックアウト（ビルド結果の `dist/` もここ）
- `~/current` … 動かすリリースへのシンボリックリンク
- `~/shared/` … リリースをまたいで残すもの（SQLite の DB）

---

## 第 4 部: 秘密鍵と環境変数

本番の設定は環境変数で渡します。`CYBERTRAIN_SECRET_KEY_BASE` はセッション Cookie の署名鍵で、
本番では未設定だと起動しません。リポジトリには入れず、サーバーのファイルにだけ置きます。

sudo できるユーザーで:

```sh
sudo install -d -m 750 -o root -g notes /etc/notes
SECRET="$(openssl rand -hex 32)"
sudo tee /etc/notes/notes.env > /dev/null <<EOF
CYBERTRAIN_ENV=production
CYBERTRAIN_SECRET_KEY_BASE=$SECRET
CYBERTRAIN_DATABASE=/srv/notes/shared/production.sqlite3
PORT=3000
EOF
unset SECRET
sudo chown root:notes /etc/notes/notes.env
sudo chmod 640 /etc/notes/notes.env
```

| 変数 | 意味 |
| --- | --- |
| `CYBERTRAIN_ENV=production` | `cybertrain build` のバイナリは既定で本番モードなので省略できますが、明示しておきます。`development` にすると開発モードで起動し、ファイル監視と再ビルドまで始めます |
| `CYBERTRAIN_SECRET_KEY_BASE` | **必須**。変えると全員のセッションが切れます |
| `CYBERTRAIN_DATABASE` | DB ファイル。リリースをまたいで残るよう `shared/` に置きます |
| `PORT` | 待ち受けポート。Caddy の設定と合わせます |

---

## 第 5 部: systemd とデプロイスクリプト

### 5-1. systemd ユニット

`/etc/systemd/system/notes.service` を作ります。

```sh
sudo tee /etc/systemd/system/notes.service > /dev/null <<'EOF'
[Unit]
Description=notes (cybertrain)
After=network.target

[Service]
Type=simple
User=notes
Group=notes
WorkingDirectory=/srv/notes/current/dist
EnvironmentFile=/etc/notes/notes.env
ExecStart=/srv/notes/current/dist/notes
Restart=always
RestartSec=2
TimeoutStopSec=15

# 書き込めるのは DB のディレクトリだけにする
NoNewPrivileges=true
ProtectSystem=strict
ReadWritePaths=/srv/notes/shared
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload
sudo systemctl enable notes
```

ここではまだ起動しません（`/srv/notes/current` がまだないため）。最初のデプロイで起動します。

- `WorkingDirectory` が重要です。サーバーは `public/` と `storage/`（`CYBERTRAIN_DATABASE` を
  指定しないときの DB の置き場）を**作業ディレクトリからの相対パス**で解決します。ビューは
  バイナリに埋め込まれているので、ディスクからは読みません。ここでは DB を
  `CYBERTRAIN_DATABASE` で `/srv/notes/shared/` に置くので、書き込みが要るのは
  `ReadWritePaths` のそこだけです。
- ログは標準出力に出るので、journald（`journalctl -u notes`）に集まります。
- 停止は SIGTERM で、受け付けを止め、処理中のリクエストに応答し終えてから終了します（最大 10 秒。
  `TimeoutStopSec=15` はこれより長くしてあります）。

### 5-2. `notes` ユーザーにサービスの再起動だけ許可する

```sh
echo 'notes ALL=(root) NOPASSWD: /usr/bin/systemctl restart notes' | sudo tee /etc/sudoers.d/notes > /dev/null
sudo chmod 440 /etc/sudoers.d/notes
sudo visudo -c
```

### 5-3. デプロイスクリプト

`notes` ユーザーでスクリプトを置きます。`REPO` の行を自分のリポジトリに変えてください。

```sh
sudo -iu notes
cat > ~/deploy.sh <<'EOF'
#!/usr/bin/env bash
# 使い方: ~/deploy.sh [ブランチ・タグ・コミット]   （省略時は main）
set -euo pipefail

APP=notes
ROOT=/srv/notes
REPO=git@github.com:YOUR_GITHUB/notes.git
REF="${1:-main}"
KEEP=5   # 残すリリースの数

export PATH="$HOME/.cybertrain/bin:$HOME/.local/bin:$PATH"
set -a; . /etc/notes/notes.env; set +a

release="$ROOT/releases/$(date +%Y%m%d%H%M%S)"

echo "==> $REF を取得: $release"
git clone --quiet "$REPO" "$release"
cd "$release"
git checkout --quiet "$REF"

echo "==> gen/ が最新か確認"
spin run gen -- --check

echo "==> ビルド（ビューを埋め込んだ dist/notes と dist/public/）"
cybertrain build

echo "==> マイグレーション"
dist/notes migrate

echo "==> 切り替えて再起動"
ln -sfn "$release" "$ROOT/current.new"
mv -T "$ROOT/current.new" "$ROOT/current"
sudo /usr/bin/systemctl restart "$APP"

echo "==> 古いリリースを削除（新しい $KEEP 個を残す）"
ls -1d "$ROOT"/releases/* | sort -r | tail -n +$((KEEP + 1)) | xargs -r rm -rf

echo "==> 完了: $(git rev-parse --short HEAD)"
EOF
chmod 700 ~/deploy.sh
```

`PATH` の先頭に `~/.cybertrain/bin` を入れているのは、`gen/` の確認で `spin` を直接呼ぶためです
（`cybertrain build` は Spinel を自分で見つけます）。`~/.cybertrain/bin` は `cybertrain setup` が
現在のリリースに向けて張り直すリンクなので、Spinel のリリースが上がっても書き換えは要りません。

途中のどこかで失敗した場合（`gen/` が古い、コンパイルエラー、マイグレーション失敗）は、
`current` を切り替える前に止まるので、動いているアプリには影響しません。

### 5-4. 最初のデプロイ

`notes` ユーザーのまま:

```sh
~/deploy.sh
```

初回はマイグレーションが `/srv/notes/shared/production.sqlite3` を作ります。

```sh
exit    # sudo できるユーザーに戻る
systemctl status notes --no-pager
journalctl -u notes -n 20 --no-pager
curl -sI http://127.0.0.1:3000/
```

`=> production environment` と `* Listening on http://127.0.0.1:3000` がログにあり、
curl が `HTTP/1.1 200 OK` を返せば、アプリは動いています。

---

## 第 6 部: Caddy で HTTPS 公開する

### 6-1. インストール

[Caddy 公式の手順](https://caddyserver.com/docs/install#debian-ubuntu-raspbian)どおり、
公式の apt リポジトリから入れます。

```sh
sudo apt install -y debian-keyring debian-archive-keyring apt-transport-https curl
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | sudo tee /etc/apt/sources.list.d/caddy-stable.list
sudo chmod o+r /usr/share/keyrings/caddy-stable-archive-keyring.gpg
sudo chmod o+r /etc/apt/sources.list.d/caddy-stable.list
sudo apt update
sudo apt install -y caddy
```

### 6-2. Caddyfile

`/etc/caddy/Caddyfile` を次の内容で置き換えます。

```sh
sudo tee /etc/caddy/Caddyfile > /dev/null <<'EOF'
notes.example.com {
	encode zstd gzip
	root * /srv/notes/current/dist/public

	# public/ にあるファイルは Caddy が直接返す
	@static file
	handle @static {
		file_server
	}

	handle {
		reverse_proxy 127.0.0.1:3000
	}

	# アプリが落ちている・再起動中（502 など）のとき
	handle_errors {
		rewrite * /500.html
		file_server
	}
}
EOF
caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
sudo systemctl reload caddy
```

アプリの 404 / 500 は、アプリ自身が本番モードで `dist/public/404.html` / `dist/public/500.html` を返すので、
Caddy 側で差し替える必要はありません。Caddy の `handle_errors` は、アプリに繋がらないとき
（再起動中など）用です。

最初のアクセスで Caddy が Let's Encrypt から証明書を取ります（DNS が向いていて、80/443 が
開いている必要があります）。HTTP へのアクセスは自動で HTTPS にリダイレクトされます。

### 6-3. 確認

```sh
curl -sI https://notes.example.com/
```

`HTTP/2 200` が返れば公開完了です。ブラウザで https://notes.example.com/ を開き、
ノートを作成・編集・削除してみてください。うまくいかないときは
`journalctl -u caddy -n 50 --no-pager` を見ます。

---

## 第 7 部: 日々の運用

### 更新をデプロイする

手元で変更してコミットし、push してから:

```sh
ssh YOUR_SERVER
sudo -iu notes /srv/notes/deploy.sh          # main を出す
sudo -iu notes /srv/notes/deploy.sh v1.2.0   # タグやコミットを指定することもできる
```

手元での変更の流れは開発時と同じです。スキーマ・ルート・コントローラのコールバックやインスタンス
変数を変えたら `spin run gen` をしてから `gen/` ごとコミットしてください（忘れるとデプロイが
`gen/ が最新か確認` で止まります）。

再起動の間（数秒）は Caddy が 500.html を返します。

### ログを見る

```sh
journalctl -u notes -f                  # アプリ（1 リクエスト 2 行: Started / Completed）
journalctl -u caddy -f                  # Caddy
```

リクエストログの接続元 IP は常に `127.0.0.1`（Caddy）になります。実際のクライアント IP が
必要なら Caddyfile のサイトブロックに `log` を足して Caddy のアクセスログを使ってください。

### ロールバック

```sh
sudo -iu notes
ls -1 ~/releases                                         # 残っているリリース
ln -sfn ~/releases/20260926120000 ~/current.new && mv -T ~/current.new ~/current
sudo /usr/bin/systemctl restart notes
```

戻したいリリース以降に**マイグレーションを追加していた場合**は、切り替える前に、新しい方の
リリースのディレクトリで DB も戻しておきます（古いリリースは新しいマイグレーションを知らないため）。

```sh
cd ~/current                                  # 切り替え前（新しい方）のリリース
set -a; . /etc/notes/notes.env; set +a
dist/notes db status                          # 適用済みのマイグレーションを確認
dist/notes db rollback 1                      # 戻す数を指定
```

### バックアップ

SQLite は WAL モードで動いているので、DB ファイルを `cp` せず `sqlite3` の `.backup` を使います
（アプリを止めずに一貫したコピーが取れます）。`notes` ユーザーの crontab に毎日 3:15 の
バックアップと 14 日より古いものの削除を登録します。

```sh
sudo -iu notes
crontab -e
```

```cron
15 3 * * * sqlite3 /srv/notes/shared/production.sqlite3 ".backup '/srv/notes/backups/production-$(date +\%F).sqlite3'" && find /srv/notes/backups -name 'production-*.sqlite3' -mtime +14 -delete
```

サーバーが壊れたときのために、`/srv/notes/backups/` は別の場所（別サーバーやオブジェクト
ストレージ）にも定期的にコピーしてください。

復元するとき:

```sh
sudo systemctl stop notes
sudo -u notes cp /srv/notes/backups/production-2026-09-26.sqlite3 /srv/notes/shared/production.sqlite3
sudo -u notes rm -f /srv/notes/shared/production.sqlite3-wal /srv/notes/shared/production.sqlite3-shm
sudo systemctl start notes
```

### フレームワークを更新する

手元で:

`spin.toml` の `ref` を新しいタグ（例: `"v0.3.0"`）に書き換え、`gem install cybertrain` で
CLI も同じバージョンにそろえてから（サーバーの `notes` ユーザーでも
`gem install --user-install cybertrain -v 0.3.0` のように、`spin.toml` のタグと同じバージョンを
指定して CLI を更新します。CLI と `spin.lock` が固定するフレームワークは対で更新するものなので、
バージョンがずれるとビルドや起動が失敗します）:

```sh
spin lock          # 新しいタグのコミットを spin.lock に固定する
spin run gen       # 生成コードがフレームワークに合わせて変わることがある
spin test          # テストを書いているなら
cybertrain server  # 動作確認
git add -A && git commit -m "Update cybertrain"
git push
```

そのあと普段どおりデプロイします。新しい `cybertrain` が固定している Spinel のリリース
（`Cybertrain::SPINEL_TAG`。そのタグの [`.github/workflows/ci.yml`](https://github.com/saeki-mototsune/cybertrain/blob/main/.github/workflows/ci.yml) の `SPINEL_TAG` と同じもの）が上がっていたら、
上のコマンドの前に `cybertrain setup` で入れ直してください。新しいリリースは
`~/.cybertrain/spinel/<リリース>/` に入り、古いリリースはそのまま残ります。`~/.cybertrain/bin` の
リンクは新しいリリースに張り直されるので、PATH の行（1-3、5-3）はそのままで構いません。
サーバーでは `gem install` のあとに `notes` ユーザーで `cybertrain setup` を実行しておくと（3-4）、
デプロイの途中でビルドを待たずに済みます。

### 秘密鍵を変える

`/etc/notes/notes.env` の `CYBERTRAIN_SECRET_KEY_BASE` を新しい値（`openssl rand -hex 32`）に
書き換えて `sudo systemctl restart notes`。全員のセッションとフラッシュが消え、開きっぱなしの
フォームは CSRF エラーになります。

---

## トラブルシューティング

| 症状 | 原因と対処 |
| --- | --- |
| 起動ログに `CYBERTRAIN_SECRET_KEY_BASE is not set` | `/etc/notes/notes.env` がない・読めない・値が空。`EnvironmentFile=` のパスと、ファイルの所有者 `root:notes`・権限 `640` を確認 |
| 起動ログに `=> development environment` や `Watching app/...` | `/etc/notes/notes.env` の `CYBERTRAIN_ENV` が `production` 以外になっている。開発モードでは `app/views/` をディスクから読み、`spin` で再ビルドしようとするので、必ず直す |
| `status=203/EXEC` で起動しない | `/srv/notes/current/dist/notes` がない。`~/deploy.sh` が最後まで成功しているか確認 |
| 起動ログに `error: views are not embedded in this binary` | ビューを埋め込まずにビルドしたバイナリ（`spin build notes` の `build/bin/notes` など）を本番モードで起動している。`cybertrain build` で作った `dist/notes` を使う |
| 500 になり、ログに `Missing template ...` が出る | ビルド時に `app/views/` に無かったテンプレート。`cybertrain build` をやり直す |
| `attempt to write a readonly database` / `unable to open database file` | DB のパスが `ReadWritePaths=` の外にある、または `/srv/notes/shared` の所有者が `notes` でない |
| デプロイが `stale: gen/...` で止まる | 手元で `spin run gen` して `gen/` をコミットし忘れている |
| `spin: command not found`（デプロイ時） | `notes` ユーザーに Spinel が入っていない（3-4 の `cybertrain setup`）、または `~/deploy.sh` の `PATH` に `~/.cybertrain/bin` が無い（5-3） |
| `cybertrain: command not found`（デプロイ時） | `notes` ユーザーに cybertrain の CLI が入っていない（3-4 の `gem install --user-install cybertrain -v 0.2.0`） |
| `git clone` が `Permission denied (publickey)` | デプロイキーが未登録か、別ユーザーの鍵を使っている（3-5 は `notes` ユーザーで実行） |
| ブラウザで 500.html が出続ける | アプリが落ちている。`journalctl -u notes -n 50` を見る |
| 証明書が取れない | DNS がサーバーを向いているか、80/443 が開いているか。`journalctl -u caddy` を見る |
| 静的ファイルが 403 / 404 | `/srv/notes` の権限（`chmod 711`）と、ファイルが `dist/public/` にあるか（`cybertrain build` が `public/` からコピーする） |
| フォーム送信が 403 `Invalid authenticity token` になる・フラッシュが出ない | HTTP で開いている。本番のセッション Cookie は `Secure` なので HTTPS でしか届かない。`https://` で開く（どうしても HTTP で運用するなら `config/app.rb` で `c.session_secure = false`） |

## いまの cybertrain の制約（本番で気にしておくこと）

- **DB は SQLite だけ**です。サーバー 1 台・1 プロセスで動かす前提で、横に並べることはできません。
- **再起動（デプロイ）のあいだは数秒つながりません**。SIGTERM を受けると新しい接続の受け付けを
  止め、処理中のリクエストには応答し終えてから終了しますが、新しいプロセスが listen するまでの
  間に来た接続は拒否されます（Caddy は 502 を返します）。処理中のリクエストを待つのは最大 10 秒
  で、それより長くかかるリクエストはそこで切れます。
- HTTPS に固定したい場合は、動作を確認した後で Caddyfile のサイトブロックに
  `header Strict-Transport-Security "max-age=31536000"` を足してください（セッション Cookie は
  本番では `Secure` 付きです）。
- 認証（ログイン）機能はフレームワークにありません。公開前に、誰が書き込めるべきかを考えてください。
- ビューはビルド時にバイナリへ埋め込まれます。ビューだけの変更でも、本番ではデプロイ
  （再ビルドと再起動）が必要です。
