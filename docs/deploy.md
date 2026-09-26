# チュートリアル: `cybertrain new` から本番稼働まで

`cybertrain new` でアプリを作り、Ubuntu サーバーに HTTPS 付きでデプロイして使い始める
までを、上から順にコピペで進められるように書いています。

最終的な構成は次のとおりです。

```
ブラウザ ──HTTPS──▶ Caddy (:443, 証明書を自動取得)
                     ├─ public/ の静的ファイルは Caddy が直接返す
                     └─ それ以外 ──HTTP──▶ build/bin/server (127.0.0.1:3000, systemd)
                                              ├─ app/views/ を実行時に読む
                                              └─ /srv/notes/shared/production.sqlite3
```

- アプリは Spinel で 1 本のネイティブバイナリ（`build/bin/server`）にコンパイルされます。
  ただしビュー（`app/views/`）と `public/` は実行時にディスクから読むので、バイナリ単体では
  動きません。**リポジトリをまるごとサーバーに置き、サーバー上でビルドする**のがこの
  チュートリアルのやり方です（サーバーと同じ OS・libc でビルドすることにもなり、一番
  ハマりにくい）。
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
| Spinel のバージョン | `2026.09.12`（[CI](../.github/workflows/ci.yml) の `SPINEL_TAG` と同じもの） |

---

## 第 1 部: 手元の開発環境

手元は Linux か macOS を想定しています（Windows は WSL2 の Ubuntu で同じ手順が使えます）。

### 1-1. 必要なパッケージ

Ubuntu / Debian:

```sh
sudo apt update
sudo apt install -y build-essential git curl libsqlite3-dev libssl-dev
```

macOS: `xcode-select --install`（C コンパイラと SQLite が入ります）。

### 1-2. Spinel をインストールする

CI と同じ手順です。`~/.local` に `spinel` と `spin` が入ります。

```sh
git clone --depth 1 --branch 2026.09.12 https://github.com/matz/spinel.git ~/src/spinel
cd ~/src/spinel
make deps
make -j"$(nproc 2>/dev/null || sysctl -n hw.ncpu)"
make install PREFIX="$HOME/.local"
```

`~/.local/bin` に PATH を通します（zsh なら `~/.zshrc`）。

```sh
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc
spinel --version
```

### 1-3. cybertrain の CLI をインストールする

```sh
git clone https://github.com/saeki-mototsune/cybertrain.git ~/src/cybertrain
cd ~/src/cybertrain
spin install          # bin/cybertrain.rb をビルドして ~/.local/bin/cybertrain に置く
cybertrain version
```

---

## 第 2 部: アプリを作る

### 2-1. `cybertrain new`

```sh
cd ~/src
cybertrain new notes
cd notes
git init -b main
```

### 2-2. フレームワークをアプリのリポジトリに固定する

`cybertrain new` が書く `spin.toml` は、フレームワークを **手元のチェックアウトの絶対パス**
（例: `/home/you/src/cybertrain`）で参照しています。このままだとサーバーでビルドできないので、
フレームワークを git submodule としてアプリに入れ、相対パスで参照するように変えます。
使うフレームワークのコミットもこれで固定されます。

```sh
git submodule add https://github.com/saeki-mototsune/cybertrain.git vendor/cybertrain
```

`spin.toml` を次の内容にします（`[dependencies]` の 1 行だけが変わります）。

```toml
[package]
name = "notes"
version = "0.1.0"

[dependencies]
cybertrain = { path = "vendor/cybertrain" }
```

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

生成 → マイグレーション → 再生成の順に実行します。

```sh
spin run gen             # 新しいマイグレーションを gen/migrations.rb に取り込む
spin run db -- migrate   # storage/development.sqlite3 を作り、db/schema.rb を書き直す
spin run gen             # db/schema.rb と routes から gen/ を作り直す
```

### 2-4. 手元で動かす

```sh
spin run server
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
spin build server
export CYBERTRAIN_ENV=production
export CYBERTRAIN_SECRET_KEY_BASE="$(openssl rand -hex 32)"
export CYBERTRAIN_DATABASE="$PWD/storage/rehearsal.sqlite3"
spin run db -- migrate
build/bin/server
```

起動時の表示が次のようになっていれば OK です。

```
=> Booting cybertrain 0.1.0
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
unset CYBERTRAIN_ENV CYBERTRAIN_SECRET_KEY_BASE CYBERTRAIN_DATABASE
rm -f storage/rehearsal.sqlite3*
```

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
sudo apt install -y build-essential git curl libsqlite3-dev libssl-dev sqlite3 ufw

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

### 3-4. `notes` ユーザーで Spinel をインストールする

```sh
sudo -iu notes
```

以降、**第 3 部の終わりまで `notes` ユーザーのシェル**で作業します。手順は 1-2 と同じです。

```sh
git clone --depth 1 --branch 2026.09.12 https://github.com/matz/spinel.git ~/spinel-src
cd ~/spinel-src
make deps
make -j"$(nproc)"
make install PREFIX="$HOME/.local"
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc
spinel --version
```

### 3-5. デプロイキー

サーバーがアプリの private リポジトリを読めるように、読み取り専用のデプロイキーを作ります
（フレームワークの submodule は公開リポジトリなので鍵は不要です）。

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

- `~/releases/<日時>/` … デプロイごとのチェックアウト（ビルド結果もここ）
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
| `CYBERTRAIN_ENV=production` | **必須**。これがないと開発モードで起動し、ファイル監視と再ビルドまで始めます |
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
WorkingDirectory=/srv/notes/current
EnvironmentFile=/etc/notes/notes.env
ExecStart=/srv/notes/current/build/bin/server
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

- `WorkingDirectory` が重要です。サーバーは `app/views/` と `public/` を**作業ディレクトリからの
  相対パス**で読みます。
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

export PATH="$HOME/.local/bin:$PATH"
set -a; . /etc/notes/notes.env; set +a

release="$ROOT/releases/$(date +%Y%m%d%H%M%S)"

echo "==> $REF を取得: $release"
git clone --quiet "$REPO" "$release"
cd "$release"
git checkout --quiet "$REF"
git submodule update --init --quiet

echo "==> gen/ が最新か確認"
spin run gen -- --check

echo "==> ビルド"
spin build server

echo "==> マイグレーション"
spin run db -- migrate

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
	root * /srv/notes/current/public

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

アプリの 404 / 500 は、アプリ自身が本番モードで `public/404.html` / `public/500.html` を返すので、
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
export PATH="$HOME/.local/bin:$PATH"
set -a; . /etc/notes/notes.env; set +a
spin run db -- status                         # 適用済みのマイグレーションを確認
spin run db -- rollback 1                     # 戻す数を指定
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

```sh
git -C vendor/cybertrain pull origin main    # またはタグ・コミットを checkout
spin run gen                                 # 生成コードがフレームワークに合わせて変わることがある
spin test                                    # テストを書いているなら
spin run server                              # 動作確認
git add -A && git commit -m "Update cybertrain"
git push
```

そのあと普段どおりデプロイします。フレームワークが要求する Spinel のバージョン
（`vendor/cybertrain/.github/workflows/ci.yml` の `SPINEL_TAG`）が上がっていたら、手元とサーバー
（3-4）の両方で Spinel を入れ直してからデプロイしてください。

### 秘密鍵を変える

`/etc/notes/notes.env` の `CYBERTRAIN_SECRET_KEY_BASE` を新しい値（`openssl rand -hex 32`）に
書き換えて `sudo systemctl restart notes`。全員のセッションとフラッシュが消え、開きっぱなしの
フォームは CSRF エラーになります。

---

## トラブルシューティング

| 症状 | 原因と対処 |
| --- | --- |
| 起動ログに `CYBERTRAIN_SECRET_KEY_BASE is not set` | `/etc/notes/notes.env` がない・読めない・値が空。`EnvironmentFile=` のパスと、ファイルの所有者 `root:notes`・権限 `640` を確認 |
| 起動ログに `=> development environment` や `Watching app/...` | `CYBERTRAIN_ENV=production` が渡っていない。開発モードでは `spin` で再ビルドしようとするので、必ず直す |
| `status=203/EXEC` で起動しない | `/srv/notes/current/build/bin/server` がない。`~/deploy.sh` が最後まで成功しているか確認 |
| 500 になり、ログに `Missing template app/views/...` が出る | 作業ディレクトリが違う。ユニットの `WorkingDirectory=/srv/notes/current` を確認 |
| `attempt to write a readonly database` / `unable to open database file` | DB のパスが `ReadWritePaths=` の外にある、または `/srv/notes/shared` の所有者が `notes` でない |
| デプロイが `stale: gen/...` で止まる | 手元で `spin run gen` して `gen/` をコミットし忘れている |
| `spin: command not found`（デプロイ時） | `notes` ユーザーの `~/.local/bin` に Spinel が入っていない（3-4） |
| `git clone` が `Permission denied (publickey)` | デプロイキーが未登録か、別ユーザーの鍵を使っている（3-5 は `notes` ユーザーで実行） |
| ブラウザで 500.html が出続ける | アプリが落ちている。`journalctl -u notes -n 50` を見る |
| 証明書が取れない | DNS がサーバーを向いているか、80/443 が開いているか。`journalctl -u caddy` を見る |
| 静的ファイルが 403 / 404 | `/srv/notes` の権限（`chmod 711`）と、ファイルが `public/` にあるか |
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
- ビューは初回アクセス時にパースされてキャッシュされます。ビューだけの変更でも、本番では
  デプロイ（再起動）が必要です。
