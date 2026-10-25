# チュートリアル: `cybertrain new` から本番稼働まで

（英語版: [deploy.en.md](deploy.en.md)）

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
- Docker と [Kamal](https://kamal-deploy.org) で配る方法は[第 8 部](#第-8-部-kamal-でデプロイする)にあります。
  `cybertrain new` は `Dockerfile` と `config/deploy.yml` も書くので、サーバーに Docker を入れられる
  なら、第 3 部〜第 6 部の代わりにそちらを使えます。

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
make・git・curl が、アプリのビルドには SQLite と zlib のヘッダ／ライブラリが要ります。`cybertrain setup` は
両方がそろっているか先に確かめるので、ここで入れておきます。

Ubuntu / Debian:

```sh
sudo apt update
sudo apt install -y build-essential git curl libsqlite3-dev zlib1g-dev libssl-dev libjemalloc-dev ruby-full
```

macOS: `xcode-select --install`（C コンパイラ、make、git、curl と SQLite・zlib のヘッダが入ります）。

jemalloc（`libjemalloc-dev`、macOS なら `brew install jemalloc`）は、2-2 で `allocator = "jemalloc"`
を有効にする場合だけ要ります。

OpenSSL（`libssl-dev`、macOS なら `brew install openssl@3`）は必須ではありません。無くても Spinel は
openssl パッケージ抜きでビルドされ、cybertrain はそれを使いません。macOS で `require "openssl"` する
アプリをビルドするときは、Homebrew の OpenSSL(keg-only)をコンパイラに教えます:
`export LIBRARY_PATH="$(brew --prefix openssl@3)/lib" CPATH="$(brew --prefix openssl@3)/include"`。

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
# jemalloc is a faster malloc for a server: 1.1 to 1.4 times the
# requests per second on examples/blog (docs/benchmark.md). Building then
# needs its development package (libjemalloc-dev on Debian/Ubuntu,
# `brew install jemalloc` on macOS).
# allocator = "jemalloc"

[dependencies]
cybertrain = { git = "https://github.com/saeki-mototsune/cybertrain", ref = "v0.2.1" }
```

`# allocator = "jemalloc"` の行の `#` を外すと、アプリが glibc の malloc の代わりに jemalloc を
リンクしてビルドされます。サーバーはリクエストごとに大量の小さなメモリ確保をするので、
examples/blog では 1 秒あたりのリクエスト数が 1.1〜1.4 倍になりました（[benchmark.md](benchmark.md)）。
本番ではおすすめです。手元とサーバーの両方に `libjemalloc-dev` が要ります（1-1 と 3-2 で入れています）。
入っていないと `cannot find -ljemalloc` でビルドが止まります。

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
=> Booting cybertrain 0.2.1
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
cybertrain spin run gen -- --check   # 何も出ず終了コード 0 なら最新
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
sudo apt install -y build-essential git curl libsqlite3-dev zlib1g-dev libssl-dev libjemalloc-dev sqlite3 ufw ruby-full

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
gem install --user-install cybertrain -v 0.2.1
mkdir -p ~/.local/bin
ln -sfn "$(ruby -e 'print Gem.user_dir')/bin/cybertrain" ~/.local/bin/cybertrain
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc
cybertrain version
```

`-v` はアプリの `spin.toml` の `ref`（タグ `v0.2.1`）と同じバージョンにそろえてください。CLI と
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
- ログは標準出力に出るので、journald（`sudo journalctl -u notes`）に集まります。
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
previous="$(readlink "$ROOT/current" || true)"   # 戻す先（初回は空）
ln -sfn "$release" "$ROOT/current.new"
mv -T "$ROOT/current.new" "$ROOT/current"
sudo /usr/bin/systemctl restart "$APP"

echo "==> 新しいリリースが応答するまで待つ（約 30 秒）"
up=""
deadline=$((SECONDS + 30))   # 1 回 2 秒まで、全体で約 30 秒（最後の試行は期限を少し越えうる）
while [ "$SECONDS" -lt "$deadline" ]; do
  if curl -fs --max-time 2 -o /dev/null "http://127.0.0.1:$PORT/up.html"; then up=1; break; fi
  sleep 1
done
if [ -z "$up" ]; then
  echo "==> 新しいリリースが応答しない（原因は sudo できるユーザーで journalctl -u $APP）"
  if [ -n "$previous" ]; then
    echo "==> 前のリリースに戻す: $previous"
    ln -sfn "$previous" "$ROOT/current.new"
    mv -T "$ROOT/current.new" "$ROOT/current"
    sudo /usr/bin/systemctl restart "$APP"
  fi
  exit 1
fi

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
`current` を切り替える前に止まるので、動いているアプリはそのまま古いリリースで動き続けます。
ただし、マイグレーションは古いリリースが動いている間に流れ、成功したマイグレーションはその後の手順が
失敗しても適用されたまま残ります。マイグレーションは動いているコードと両立する形にしてください（列は
まず足し、古い列は別のデプロイで消す）。

`systemctl restart` は、新しいバイナリが起動直後に落ちても成功を返します（`Type=simple` のため）。
そこでスクリプトは、切り替えて再起動したあと `http://127.0.0.1:$PORT/up.html` が応答するまで約
30 秒待ち、応答しなければ `current` を前のリリースに戻して再起動し、失敗で終わります。原因
（秘密鍵が空、ポートが使われている、など）は、`notes` ユーザーを抜けて sudo できるユーザーで
`sudo journalctl -u notes` を見ます（`notes` に許しているのは `systemctl restart notes` だけです）。

- `public/up.html` は `cybertrain new` が書く（Kamal のヘルスチェックと同じ）静的ファイルで、
  アプリ自身が返します。古い `cybertrain` で作ったアプリにない場合は、
  `echo OK > public/up.html` で作ってコミットしてください。
- マイグレーションは戻しません。前のリリースに戻せるのは、上のとおりマイグレーションが古いコードと
  両立しているからです。
- 初回のデプロイには戻す先がないので、失敗したら原因を直してもう一度 `~/deploy.sh` を実行します。

### 5-4. 最初のデプロイ

`notes` ユーザーのまま:

```sh
~/deploy.sh
```

初回はマイグレーションが `/srv/notes/shared/production.sqlite3` を作ります。

```sh
exit    # sudo できるユーザーに戻る
systemctl status notes --no-pager
sudo journalctl -u notes -n 20 --no-pager
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
`sudo journalctl -u caddy -n 50 --no-pager` を見ます。

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
変数を変えたら `cybertrain spin run gen` をしてから `gen/` ごとコミットしてください（忘れるとデプロイが
`gen/ が最新か確認` で止まります）。

再起動の間（数秒）は Caddy が 500.html を返します。

### ログを見る

```sh
sudo journalctl -u notes -f             # アプリ（1 リクエスト 2 行: Started / Completed）
sudo journalctl -u caddy -f             # Caddy
```

リクエストログの接続元 IP は常に `127.0.0.1`（Caddy）になります。実際のクライアント IP が
必要なら Caddyfile のサイトブロックに `log` を足して Caddy のアクセスログを使ってください。

### ロールバック

`notes` ユーザーで、戻す先のリリースを確かめます。

```sh
sudo -iu notes
ls -1 ~/releases                                         # 残っているリリース
```

戻したいリリース以降に**マイグレーションを追加していなければ**、そのまま切り替えて再起動します。

```sh
ln -sfn ~/releases/20260926120000 ~/current.new && mv -T ~/current.new ~/current
sudo /usr/bin/systemctl restart notes
```

**マイグレーションを追加していた場合**は、切り替える**前に**、いま動いている（新しい方の）リリースで
DB を戻します（古いリリースは新しいマイグレーションを知らないため）。戻している途中のスキーマに
リクエストが当たらないよう、アプリを止めてから行います（その間、Caddy は 500.html を返します）。
`notes` のシェルを抜け、sudo できるユーザーで:

```sh
sudo systemctl stop notes
sudo -iu notes
cd ~/current                                  # いま動いている（新しい方の）リリース
set -a; . /etc/notes/notes.env; set +a
dist/notes db status                          # 適用済みのマイグレーションを確認
dist/notes db rollback 1                      # 戻す数を指定
dist/notes db status                          # 戻ったことを確認
ln -sfn ~/releases/20260926120000 ~/current.new && mv -T ~/current.new ~/current
exit                                          # sudo できるユーザーに戻る
sudo systemctl start notes
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
cybertrain spin lock      # 新しいタグのコミットを spin.lock に固定する
cybertrain spin run gen   # 生成コードがフレームワークに合わせて変わることがある
cybertrain spin test      # テストを書いているなら
cybertrain server         # 動作確認
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

## 第 8 部: Kamal でデプロイする

（英語版: [deploy-kamal.md](deploy-kamal.md)）

第 3 部〜第 6 部（サーバー上でビルドし、systemd と Caddy で動かす）の代わりに、Docker イメージに
して [Kamal 2](https://kamal-deploy.org) で配ることもできます。`cybertrain new` は次のファイルを
書いています。

| ファイル | 中身 |
| --- | --- |
| `Dockerfile` | 2 段のビルド。1 段目（Ubuntu 24.04）で `gem install cybertrain`・`cybertrain setup`（Spinel）・`cybertrain build` を実行し、2 段目（同じ Ubuntu）に `dist/` と実行時に要るライブラリ（SQLite・zlib・jemalloc）だけを入れる。起動時に `./notes migrate` してから `./notes` を `exec` する |
| `.dockerignore` | `build/`・`dist/`・`storage/` の DB・`tmp/`・`.git/`・`.kamal/` をビルドに渡さない |
| `config/deploy.yml` | Kamal の設定。kamal-proxy が HTTPS（Let's Encrypt）を受けてアプリの 3000 番に渡し、`/up.html` でヘルスチェックする。DB はボリューム `notes_storage`（コンテナの `/app/storage`）に置く |
| `.kamal/secrets` | `KAMAL_REGISTRY_PASSWORD` と `CYBERTRAIN_SECRET_KEY_BASE` を、kamal を実行するシェルの環境変数から読む。値そのものは書かない（コミットするファイル） |
| `public/up.html` | ヘルスチェック用のページ。アプリ自身が静的ファイルとして返す |

[examples/blog](../examples/blog#deploying-with-kamal) にも同じ設定が入っています（フレームワークは
このリポジトリのものを使うので、`Dockerfile` は gem を入れずにチェックアウトの CLI を使い、ビルド
コンテキストはリポジトリのルートです）。

バイナリは Docker の中でビルドされるので、「動かすマシンと同じ OS でビルドする」制約はイメージが
満たします。CPU は合わせる必要があります（`builder.arch`。下記）。

### 8-1. 用意するもの

- 手元: Docker と Kamal（`gem install kamal`）。
- サーバー: Ubuntu など、root（または sudo できるユーザー）で SSH できるマシン。Docker は
  `kamal setup` が入れます。80 と 443 を開けておきます。
- DNS: `notes.example.com` の A（AAAA）レコードをサーバーに向けておきます（3-1 と同じ）。
- イメージの置き場: Docker Hub か GitHub Container Registry（ghcr.io）のアカウントと、push できる
  トークン。
- フレームワークの参照: `spin.toml` の `cybertrain =` が git のタグ（`cybertrain new` の既定）か
  バージョンであること。`--path` で作ったアプリは、イメージの中からそのパスが見えないのでビルド
  できません。

### 8-2. `config/deploy.yml` を書き換える

`CHANGE ME` と書いた値を自分のものにします。

```yaml
service: notes
image: YOUR_DOCKERHUB_USER/notes      # ghcr.io なら YOUR_GITHUB/notes

servers:
  web:
    - 203.0.113.10                    # サーバーの IP アドレスかホスト名

proxy:
  ssl: true
  host: notes.example.com
  app_port: 3000
  healthcheck:
    path: /up.html

registry:
  # server: ghcr.io                   # ghcr.io を使うときだけ
  username: YOUR_DOCKERHUB_USER
  password:
    - KAMAL_REGISTRY_PASSWORD
```

`builder.arch` はサーバーの CPU に合わせます（x86-64 なら `amd64`、arm64 なら `arm64`）。
イメージのビルドでは Spinel もコンパイルするので、手元と違う CPU 向けにエミュレーションでビルド
すると非常に遅くなります。Apple Silicon の Mac から x86-64 のサーバーに配るときは
`builder.remote: ssh://root@203.0.113.10` を有効にして、サーバー上でビルドさせるのがおすすめです。

`proxy.ssl` は外さないでください。本番のセッション Cookie は `Secure` なので、HTTP ではフォーム
送信が 403 になります。

生成される `config/deploy.yml` は `env.clear` に `CYBERTRAIN_TRUSTED_PROXIES: 172.16.0.0/12` を
書きます。kamal-proxy は別のコンテナで動き、Docker のネットワーク上のアドレス（既定では
172.16.0.0/12 の中）からアプリにつなぐので、そこからの接続に限って `X-Forwarded-For` の最後の
アドレス（kamal-proxy が付けたもの）を `request.client_ip` にします。これがないと、サインインの
レート制限（`rate_limit`）が訪問者全員を kamal-proxy の一つのアドレスとして数えます。Docker の
ネットワークを別の範囲にしているときは、その範囲に書き換えてください（`docker network inspect kamal`
で確かめられます）。`proxy.forward_headers` は設定しません。TLS を終端する kamal-proxy は
`X-Forwarded-For` を自分で付け、クライアントが送ったものは渡さないので、それが望む動きです。

### 8-3. 秘密鍵を用意する

`.kamal/secrets` は環境変数を読むだけなので、kamal を実行するシェルで設定します。
`CYBERTRAIN_SECRET_KEY_BASE` は一度だけ作り、パスワードマネージャーなどに保管してください
（変えると全員のセッションが切れます）。

```sh
export KAMAL_REGISTRY_PASSWORD=...                      # レジストリのトークン
export CYBERTRAIN_SECRET_KEY_BASE="$(openssl rand -hex 32)"   # 初回だけ作り、保管した値を使う
```

パスワードマネージャーから直接読む書き方は
[Kamal のドキュメント](https://kamal-deploy.org/docs/commands/secrets/)にあります。

### 8-4. 最初のデプロイ

Kamal は手元の git の HEAD からイメージをビルドします。`gen/` を含めてコミットしてから実行します
（2-7）。

```sh
cybertrain spin run gen -- --check
git add -A && git commit -m "Configure Kamal"
kamal setup
```

`kamal setup` はサーバーに Docker と kamal-proxy を入れ、イメージをビルドして push し、
コンテナを起動します。初回は Spinel のコンパイルがあるので数分かかります（Docker のレイヤー
キャッシュに残るので、2 回目からはアプリのビルドだけです）。コンテナは起動時に
`./notes migrate` を流してからサーバーを起動し、`/up.html` が 200 を返すと kamal-proxy が
トラフィックを切り替えます。`deploy_timeout`（30 秒）のうちに応答しなければデプロイは失敗し、
トラフィックは古いコンテナのままです（初回は古いコンテナがありません）。
https://notes.example.com を開いて確かめます。

### 8-5. 日々の運用

| やりたいこと | コマンド |
| --- | --- |
| 更新をデプロイする（コミットしてから） | `kamal deploy` |
| ログを見る | `kamal app logs -f` |
| マイグレーションの状態 | `kamal db_status`（`config/deploy.yml` の `aliases`） |
| コンテナでシェルを開く | `kamal shell` |
| 前のバージョンに戻す | `kamal rollback VERSION`（`kamal app containers` で一覧） |

- DB はサーバーの Docker ボリューム `notes_storage`（サーバー上の
  `/var/lib/docker/volumes/notes_storage/_data/`）にあります。バックアップはサーバーで
  `sudo apt install -y sqlite3` してから、SQLite の `.backup` で取ります（書き込み中でも壊れません）。

  ```sh
  sudo sqlite3 /var/lib/docker/volumes/notes_storage/_data/production.sqlite3 ".backup /root/notes-$(date +%Y%m%d).sqlite3"
  ```

- `kamal deploy` は新しいコンテナがヘルスチェックに通ってから古いコンテナを止めるので、第 7 部の
  systemd の再起動と違い、デプロイ中も接続は拒否されません。ただし新旧のコンテナが短い間同じ
  SQLite ファイルを開き、新しいコンテナのマイグレーションは古いコンテナが動いている間に流れます。
  列を消すようなマイグレーションは、古いコードがその列を使わなくなってから別のデプロイで流します。
- サーバーは 1 台にしてください（SQLite のファイルはそのサーバーのボリュームにしかありません）。
- フレームワークを上げるとき（第 7 部の「フレームワークを更新する」）は、`Dockerfile` の
  `gem install cybertrain -v ...` も `spin.toml` の `ref` と同じバージョンにします。

## トラブルシューティング

| 症状 | 原因と対処 |
| --- | --- |
| 起動ログに `CYBERTRAIN_SECRET_KEY_BASE is not set` | `/etc/notes/notes.env` がない・読めない・値が空。`EnvironmentFile=` のパスと、ファイルの所有者 `root:notes`・権限 `640` を確認 |
| 起動ログに `=> development environment` や `Watching app/...` | `/etc/notes/notes.env` の `CYBERTRAIN_ENV` が `production` 以外になっている。開発モードでは `app/views/` をディスクから読み、`spin` で再ビルドしようとするので、必ず直す |
| `status=203/EXEC` で起動しない | `/srv/notes/current/dist/notes` がない。`~/deploy.sh` が最後まで成功しているか確認 |
| 起動ログに `error: views are not embedded in this binary` | ビューを埋め込まずにビルドしたバイナリ（`spin build notes` の `build/bin/notes` など）を本番モードで起動している。`cybertrain build` で作った `dist/notes` を使う |
| 500 になり、ログに `Missing template ...` が出る | ビルド時に `app/views/` に無かったテンプレート。`cybertrain build` をやり直す |
| `attempt to write a readonly database` / `unable to open database file` | DB のパスが `ReadWritePaths=` の外にある、または `/srv/notes/shared` の所有者が `notes` でない |
| デプロイが `stale: gen/...` で止まる | 手元で `cybertrain spin run gen` して `gen/` をコミットし忘れている |
| デプロイが「新しいリリースが応答しない」で終わる | 新しいリリースが約 30 秒のうちに `/up.html` に応答しなかった（スクリプトは前のリリースに戻している）。`sudo journalctl -u notes -n 50` で原因を見る。起動はしているのに応答しないなら、アプリに `public/up.html` が無い（5-3） |
| `spin: command not found`（デプロイ時） | `notes` ユーザーに Spinel が入っていない（3-4 の `cybertrain setup`）、または `~/deploy.sh` の `PATH` に `~/.cybertrain/bin` が無い（5-3） |
| `cybertrain: command not found`（デプロイ時） | `notes` ユーザーに cybertrain の CLI が入っていない（3-4 の `gem install --user-install cybertrain -v 0.2.1`） |
| `git clone` が `Permission denied (publickey)` | デプロイキーが未登録か、別ユーザーの鍵を使っている（3-5 は `notes` ユーザーで実行） |
| ブラウザで 500.html が出続ける | アプリが落ちている。`sudo journalctl -u notes -n 50` を見る |
| 証明書が取れない | DNS がサーバーを向いているか、80/443 が開いているか。`sudo journalctl -u caddy` を見る |
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
- アプリは全レスポンスに `X-Content-Type-Options: nosniff` と `X-Frame-Options: SAMEORIGIN` を付けます
  （アプリの応答、エラー応答、`Static` ミドルウェアが返す `public/` のファイルも）。ただし 6-2 の
  Caddyfile では `public/` のファイルを Caddy が直接返すので、アプリを通らず、この 2 つは付きません。
  揃えたいときは、サイトブロックに `header ?X-Content-Type-Options nosniff` と
  `header ?X-Frame-Options SAMEORIGIN` を足してください（`?` は、アプリがすでに付けているときは
  上書きしない指定です。埋め込み用のページがアプリ側で値を変えていても、それが残ります）。
- 認証（ログイン）機能はフレームワークにありません。公開前に、誰が書き込めるべきかを考えてください。
- ビューはビルド時にバイナリへ埋め込まれます。ビューだけの変更でも、本番ではデプロイ
  （再ビルドと再起動）が必要です。
