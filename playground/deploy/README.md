# ホスト型プレイグラウンドの運用ガイド

ログインなしで cybertrain を試せるホスト型プレイグラウンド（設計は
[docs/superpowers/specs/2026-10-02-web-playground-sp2-design.md](../../docs/superpowers/specs/2026-10-02-web-playground-sp2-design.md)）を、
新しい VPS に Cloudflare と Kamal で出して運用するための手順書です。上から順にコピペで進められるように
書いています。部品の中身と手元での動かし方は [playground/README.md](../README.md) にあります。

最終的な構成は次のとおりです。

```
ブラウザ ──HTTPS / WSS──▶ Cloudflare（Free。<DOMAIN> と *.<DOMAIN> をプロキシ）
                              │ HTTPS（Full (strict)、Origin CA のワイルドカード証明書）
                              ▼
VPS（Ubuntu 24.04、Docker、Kamal 2）
  kamal-proxy :443 ──▶ ルーター（Caddy :80、サービス cybertrain-play-router）
                         ├─ <DOMAIN>              → 制御面（Sinatra :9292、サービス cybertrain-play）
                         ├─ <sid>.<DOMAIN>        → そのセッションの code-server :8080
                         └─ 3000-<pid>.<DOMAIN>   → そのセッションの開発サーバー :3000
  制御面 ──docker CLI──▶ セッション 1 つごとに --internal のネットワーク（10.250.0.0/16 の /28）とコンテナ
  ホストのファイアウォール: セッションの範囲からホストとメタデータへの通信を落とす、80/443 は Cloudflare だけ
```

- セッションは 30 分（既定）で、ファイルごと消えます。タブを閉じると約 5 分半後に終わります（code-server の
  アイドル時間 300 秒の後に、制御面の刈り取りが片付けます。手元の計測）。
- セッションの URL は持参人払いの合鍵です。制御面のログはセッションをハンドル（id の SHA-256 の先頭 16 桁）
  でしか書きません。kamal-proxy の要求ログにはホスト名が残るので、ログを人に渡さないでください。

## この文書で使う名前

自分の値に読み替えてください。コマンド中にそのまま出てきます。

| 項目 | この文書での値 |
| --- | --- |
| プレイグラウンドのドメイン（Public Suffix List に載っていないもの） | `<DOMAIN>` |
| VPS の IPv4 アドレス | `<VPS_IP>` |
| GHCR の持ち主（GitHub のユーザー名。小文字で書く: Docker はイメージ名の大文字を受け付けない） | `<GHCR_OWNER>` |
| 不正利用と脆弱性の窓口のメールアドレス | `<ABUSE_EMAIL>` |
| VPS のデプロイ用ユーザー | `deploy` |
| セッションのプール（`PLAY_SUBNET_POOL`） | `10.250.0.0/16`（`router.yml`、`control.yml`、ファイアウォールの `POOL` で同じ値） |
| Kamal | `2.12.0`（設定ファイルの `minimum_version`） |

---

## 第 1 部: 用意するもの

### 1-1. ドメイン

Public Suffix List（https://publicsuffix.org/list/ ）に載っていない、登録可能なドメインを買います（例えば新しい
`.dev`）。載っているドメインではエディタとプレビューが別サイトになり、プレビューの中のフォームが Cookie を
失います。`mototsune.dev` の下は使いません。

### 1-2. Cloudflare

Free のアカウントにゾーンとしてドメインを足し、レジストラのネームサーバーを Cloudflare が示すものに替えます。
設定は第 3 部で行います。

### 1-3. VPS

東京、Ubuntu 24.04 LTS、IPv4 あり。1 セッションの実際の山は約 1 GiB、ホストの取り分は約 2 GiB です。

| VPS | 同時セッションの目安（`PLAY_MAX_SESSIONS`） | 全員が同時に Ruby を保存したときの再ビルド |
| --- | --- | --- |
| 8 GB / 4〜6 vCPU | 5 | 46 s × 5/4 ≈ 1 分（4 vCPU） |
| 12 GB / 6 vCPU（推奨） | 8 | 46 s × 8/6 ≈ 1 分 |
| 16 GB / 8 vCPU | 12 | 46 s × 12/8 ≈ 70 s |
| 24 GB / 8 vCPU | 16 | 46 s × 16/8 ≈ 90 s |

46 s は arm64 の計測です（手元の計測でも保存から再起動まで約 47 秒）。x86 では第 5 部の P11 の値で読み替えます。
KVM は要りません（gVisor の systrap は VM の中で動きます）。

### 1-4. GitHub

- Kamal 用に Personal access token（classic）を `write:packages` で作ります（GHCR は classic のトークンで入ります）。
  ルーターと制御面のイメージを push し、VPS が pull します（この 2 つのパッケージは private のままで構いません）。
- リポジトリの Settings で Private vulnerability reporting を有効にします（Code security か Advanced Security の
  項にあります。[SECURITY.md](../../SECURITY.md) がここを指しています）。
- このブランチを main に入れると CI が動きます（ブランチを push しただけでは既存の `CI` だけが走ります）。
  最初の実行で見ること:
  - PR では "Playground image" の `image` ジョブ（Codespaces のイメージと `smoke.sh`）が通ってから、`web` ジョブ
    （セッションのイメージ、`web-smoke.sh`、`e2e.sh`）が走ります。`image` が落ちると `web` は走りません。
    "Playground control plane"（制御面の単体テスト）も走ります。PR からは何も GHCR に出ません。両方のジョブで
    30〜50 分の見込みです（見積もり。まだ GitHub で走らせていません）。
  - `web` ジョブの `e2e.sh` は Linux のランナーで初めて走ります。E8（セッションから外、メタデータ、ホストに
    届かない）は手元より強い確かめになります（本物のホストのアドレスとメタデータのサービスがある）。
  - E15（作り直したルーターが 10 秒以内にセッションに届く）は手元で 6〜7 秒でした（大半は刈り取りの 5 秒の
    間隔）。いちばん落ちやすいのがこれです。遅いランナーで落ちたら一度だけ走らせ直し、続けて落ちるなら調べます。
  - main に入ると `cybertrain-playground:latest`、続けて `cybertrain-playground-web:latest` が出ます。最初の
    `cybertrain-playground-web` が出たら、github.com/<GHCR_OWNER> の Packages でそのパッケージを Public にし、
    リポジトリに結び付けます（Package settings → Change visibility、Connect repository）。
  - "Playground uptime" は 30 分ごとに予定され、変数 `PLAYGROUND_URL` を入れるまで skipped と出ます（6-7）。
    一覧がうるさければ、公開まで Actions の画面でこのワークフローを無効にしておきます。

### 1-5. 手元の Kamal と Docker

```sh
gem install kamal -v 2.12.0
kamal version          # 2.12.0
docker buildx version  # 何か版が出ること
```

- 手元に Docker（buildx 付き。Docker Desktop で可）が要ります。Kamal はルーターと制御面のイメージを手元で
  amd64 向けに作ります（Apple Silicon ではエミュレーションになるので時間がかかります）。
  `playground/deploy/session-image` は `docker buildx imagetools inspect` で GHCR にダイジェストを問い合わせます。
- フック（4-4）は `ssh deploy@<VPS_IP>` をそのまま使います。Kamal の `ssh:` に書いたポート、プロキシ、鍵は
  使わないので、それらが要るなら `~/.ssh/config` の `Host <VPS_IP>` にも書きます。

### 1-6. 窓口と利用条件

- `<ABUSE_EMAIL>` は受け取れるアドレスにします。入口、利用条件、`/.well-known/security.txt` に出ます。
- 利用条件とプライバシーの文面（[playground/control/views/terms.erb](../control/views/terms.erb)）を読んで
  承認します（法的な約束になります）。直したら制御面を出し直します（6-1）。

---

## 第 2 部: VPS

ここは VPS の管理用ユーザー（sudo できるもの）で行います。

### 2-1. ユーザーと SSH

```sh
sudo adduser --disabled-password --gecos "" deploy
sudo install -d -m 0700 -o deploy -g deploy /home/deploy/.ssh
sudo tee /home/deploy/.ssh/authorized_keys < ~/.ssh/authorized_keys > /dev/null   # 自分の公開鍵
sudo chown deploy:deploy /home/deploy/.ssh/authorized_keys && sudo chmod 600 /home/deploy/.ssh/authorized_keys
```

root でのログインとパスワードでのログインを止めます。`/etc/ssh/sshd_config` は `sshd_config.d/` の中を先に読み、
最初に出た値が効きます（クラウドのイメージは `50-cloud-init.conf` で `PasswordAuthentication yes` にしている
ことがあります）。そこで名前の先頭を `00-` にしたファイルに書きます:

```sh
printf 'PermitRootLogin no\nPasswordAuthentication no\n' | sudo tee /etc/ssh/sshd_config.d/00-cybertrain-play.conf > /dev/null
sudo sshd -t && sudo systemctl reload ssh
sudo sshd -T | grep -Ei '^(permitrootlogin|passwordauthentication) '   # permitrootlogin no と passwordauthentication no
```

今の SSH の接続は閉じずに、別の端末で `ssh deploy@<VPS_IP>` が通ることを確かめてから閉じます。

VPS の私設網の範囲がセッションのプール `10.250.0.0/16` と重ならないことを確かめます:

```sh
ip route
```

`10.250.` で始まる経路があれば、`PLAY_SUBNET_POOL` を別の範囲（例 `10.251.0.0/16`）にして、ルーターと制御面の
両方の設定（4-2）とファイアウォールの `POOL`（2-4 の終わり）に同じ値を書きます。ルーターはプールから来た接続を
切り、ファイアウォールはプールからの通信を落とすので、3 か所がそろっていないと動きません（pre-deploy フックが
2 つの設定を比べて、違えば止めます）。

### 2-2. ufw

```sh
sudo ufw default deny incoming
sudo ufw allow 22/tcp          # できれば自分の IP からだけ: sudo ufw allow from <自分の IP> to any port 22 proto tcp
sudo ufw enable
```

Docker が公開する 80/443（IPv4）は ufw（INPUT）ではなく FORWARD を通るので、2-4 の規則で Cloudflare に絞ります。

### 2-3. Docker と daemon.json

Docker の公式 apt リポジトリから入れます（https://docs.docker.com/engine/install/ubuntu/ ）。`deploy` は sudo
できないので、`kamal setup` には Docker を入れられません（Kamal は root か sudo のできるユーザーでしか入れません）。
何も動いていないうちに設定を置いて再起動します:

```sh
sudo install -m 0644 /dev/stdin /etc/docker/daemon.json <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" },
  "live-restore": true
}
EOF
sudo systemctl restart docker
docker info | grep -i cgroup          # Cgroup Version: 2
sudo usermod -aG docker deploy
```

中身は [host/daemon.json.example](host/daemon.json.example) と同じです。`live-restore` で Docker の更新や再起動の
ときもコンテナ（セッションと Kamal のアプリ）が止まりません。

メモリの重ね売りに備えて、小さなスワップ（2 GB 程度）を置くことを勧めます:

```sh
sudo fallocate -l 2G /swapfile && sudo chmod 600 /swapfile && sudo mkswap /swapfile && sudo swapon /swapfile
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
```

### 2-4. ファイアウォールのスクリプトとユニット

手元のリポジトリから VPS へ写します:

```sh
scp playground/deploy/host/cybertrain-play-firewall playground/deploy/host/cybertrain-play-firewall.service deploy@<VPS_IP>:/tmp/
```

VPS の上で、まず Cloudflare の IPv4 の一覧を置きます。一時ファイルに取り、空でなく IPv4 の範囲だけのときに
だけ置き場所へ移します（どこかで失敗すると何も置き換わらず、`list ok` が出ません）:

```sh
sudo install -d -m 0755 /etc/cybertrain-play
curl -fsS https://www.cloudflare.com/ips-v4 -o /tmp/cf-ips-v4 && [ -s /tmp/cf-ips-v4 ] &&
  ! grep -Evq '^[0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]{1,2}$' /tmp/cf-ips-v4 &&
  sudo install -m 0644 /tmp/cf-ips-v4 /etc/cybertrain-play/cloudflare-ips-v4 && echo "list ok"
grep -c . /etc/cybertrain-play/cloudflare-ips-v4    # 範囲の数（2026-10 の一覧は 15）
```

続けてスクリプトとユニットを入れて動かします:

```sh
sudo install -m 0755 /tmp/cybertrain-play-firewall /usr/local/sbin/cybertrain-play-firewall
sudo install -m 0644 /tmp/cybertrain-play-firewall.service /etc/systemd/system/cybertrain-play-firewall.service
sudo systemctl daemon-reload
sudo systemctl enable --now cybertrain-play-firewall
sudo journalctl -u cybertrain-play-firewall -n 5 --no-pager   # rules in force: 15 Cloudflare ranges on eth0, session pool 10.250.0.0/16
sudo iptables -S DOCKER-USER                       # -A DOCKER-USER -j CTPLAY が最初の規則
sudo iptables -S CTPLAY                            # メタデータの DROP、80/443 の CTPLAY-EDGE、physdev の RETURN、プールの DROP
sudo iptables -S CTPLAY-EDGE | grep -c RETURN      # 上の grep -c . と同じ数
sudo iptables -S INPUT | grep 10.250.0.0/16        # -A INPUT -s 10.250.0.0/16 -j DROP
```

- ジャーナルの行の `eth0` の所は、VPS の公開側のインターフェースの名前です（`ens3` などのこともあります）。
- Cloudflare の一覧は最後の行に改行がありません。スクリプトは最後の行も読みます（`grep -c .` の数と
  `CTPLAY-EDGE` の `RETURN` の数が同じになります。`wc -l` は 1 つ少なく数えます）。
- スクリプトはまずすべてを確かめます: 一覧が空でなく IPv4 の範囲（`a.b.c.d/n`、n は 8〜32）だけであること、`POOL`、
  公開側のインターフェース（`EXT_IF`、既定は既定経路のもの）、Docker の `DOCKER-USER` の鎖。どれかが違うと
  「…; nothing changed」と理由を出して 1 で終わり、規則は前のままです。最初の起動でそうなると規則は 1 つも
  無く、80/443 は誰にでも開いたままです（`CF-Connecting-IP` を偽れ、アドレスごとの上限が破れます。全体の上限は
  残ります）。だからジャーナルの「rules in force」を必ず見ます。
- 規則は `iptables-restore --noflush` の 1 回の取引で入ります。途中で止まっても、カーネルが規則を断っても、
  前の規則がそのまま残ります（断った規則の名前を出して 1 で終わります）。同時に 2 つ走ることはありません
  （`/run/lock/cybertrain-play-firewall.lock`）。
- ユニットは失敗すると 10 秒ごとにやり直し、2 分のうちに 5 回失敗すると failed になります（Docker の再起動に
  付いて走った回も数えます）。原因を直したら:
  `sudo systemctl reset-failed cybertrain-play-firewall && sudo systemctl restart cybertrain-play-firewall`。
- Docker の再起動と起動のたびにユニットも走り直し、規則を作り直します（`PartOf` と `WantedBy=docker.service`）。
  起動の直後は、Kamal のコンテナがユニットより数秒早く上がります（その数秒は 80/443 が誰にでも開き、
  メタデータの規則もありません。5-3 で秒数を見ます）。
- Cloudflare の範囲が変わったら、上の一覧の取り直し（`curl` から `echo "list ok"` までの 3 行）を走らせ、
  `list ok` が出たら `sudo systemctl restart cybertrain-play-firewall`。
- ユニットのファイルを入れ直したら `sudo systemctl daemon-reload && sudo systemctl reenable cybertrain-play-firewall`
  （`docker.service` からのリンクを作り直すため）。
- プールを変えるとき（2-1）: `sudo systemctl edit cybertrain-play-firewall` で `[Service]` の下に
  `Environment=POOL=10.251.0.0/16` を書き、`sudo systemctl restart cybertrain-play-firewall`、最後に古い INPUT の
  規則を手で消します: `sudo iptables -D INPUT -s 10.250.0.0/16 -j DROP`。

### 2-5. データのディレクトリ

```sh
sudo install -d -m 0750 /var/lib/cybertrain-play
```

制御面の `/data` です（`paused`、`kill-all`、`create.lock`）。

---

## 第 3 部: Cloudflare

ダッシュボードで、上から順に設定します。

| どこで | 設定 | 値と理由 |
| --- | --- | --- |
| DNS → Records | `A <DOMAIN>` と `A *` | どちらも `<VPS_IP>`、Proxied（橙の雲）。AAAA は作りません（オリジンを IPv4 だけにして、ファイアウォールを 1 系統にします。訪問者には Cloudflare が IPv6 でも答えます）。一部だけをプロキシしないこと: Origin CA 証明書はブラウザに信頼されません |
| SSL/TLS → Overview | 暗号化モード | Full (strict) |
| SSL/TLS → Origin Server | Create Certificate | ECC、ホスト名 `<DOMAIN>` と `*.<DOMAIN>`、有効期限は最長（15 年）。表示された証明書（PEM）と秘密鍵を手元の安全な場所に保存します（例 `~/.secrets/cybertrain-play/origin.pem`、`origin.key`、`chmod 600`）。期限の通知は来ないので暦に書きます |
| SSL/TLS → Edge Certificates | Always Use HTTPS | on |
| SSL/TLS → Edge Certificates | Minimum TLS Version | 1.2 |
| Caching → Cache Rules | 規則を 1 つ | 条件「Hostname ends with `<DOMAIN>`」（または All incoming requests）、動作 Bypass cache。既定では css/js などの拡張子が保存され、編集した CSS がプレビューで古いままになります |
| Network | WebSockets | on（既定）。エディタが使います |
| Speed → Optimization ほか | Rocket Loader、Email Address Obfuscation、Automatic HTTPS Rewrites、Always Online | すべて off（前の 3 つは訪問者の HTML を書き換えます） |
| Security → Bots | Bot Fight Mode | off（確認の画面にエディタの XHR と WebSocket が答えられません） |

してはいけないこと:

- **Under Attack モード**: すべての要求に確認を挟み、エディタの WebSocket と XHR を壊します。必要なときは
  第 7 部の WAF 規則（入口だけ）を使います。
- キャッシュ、HTML の変換、Workers での書き換え。

HSTS は第 5 部の確認がすべて通った後で有効にします（SSL/TLS → Edge Certificates → HSTS: max-age 6 か月、
includeSubDomains、preload なし）。一度出すと戻せないので最後にします。

任意: Google Search Console でドメインを確認しておきます（DNS の TXT）。Safe Browsing の通知と再審査の窓口になります。

---

## 第 4 部: Kamal

ここからは手元のリポジトリの最上位で行います。

### 4-1. 秘密

秘密そのものはリポジトリに入れません。[.kamal/secrets](../../.kamal/secrets) は環境変数とファイルを参照するだけです。
デプロイする端末で毎回:

```sh
export KAMAL_REGISTRY_PASSWORD=<1-4 の PAT>
export PLAY_ORIGIN_CERT=~/.secrets/cybertrain-play/origin.pem
export PLAY_ORIGIN_KEY=~/.secrets/cybertrain-play/origin.key
```

複数行の PEM がそのまま kamal-proxy に届くことを、設定を読むだけで確かめられます:

```sh
ruby -e 'require "kamal"; s = Kamal::Secrets.new; c = s["CERTIFICATE_PEM"]; puts c.lines.first, c.lines.size'
```

`-----BEGIN CERTIFICATE-----` と 2 以上の行数が出れば届きます（変数が無いと空の行と `0`）。

- ルーターの `kamal setup`、`deploy`、`redeploy`、`rollback` の前には、必ず 2 つの証明書の変数を export します。
  無いと pre-deploy フックが止めます（`pre-deploy: PLAY_ORIGIN_CERT is not set: …`）。Kamal は空の秘密もそのまま
  上げるからです。
- `kamal app boot -c playground/deploy/router.yml` を手で使わないでください。pre-deploy が走らないので、変数が
  無いと空の証明書をホストの写しに上書きします。

### 4-2. 設定ファイル

```sh
cp playground/deploy/router.yml.example playground/deploy/router.yml
cp playground/deploy/control.yml.example playground/deploy/control.yml
```

両方の `<VPS_IP>`、`<DOMAIN>`、`<GHCR_OWNER>`（小文字）、`<ABUSE_EMAIL>` を埋めます（2 つのファイルは git が
無視します）。容量（1-3）に合わせて `control.yml` の `PLAY_MAX_SESSIONS` を決めます。`PLAY_SUBNET_POOL` は
2 つのファイルで同じ値のままにします。

`control.yml` を読むたびに `playground/deploy/session-image` が GHCR に `cybertrain-playground-web:latest` の
ダイジェストを問い合わせて、`PLAY_SESSION_IMAGE` に固定します（CI がスモークと E2E を通したものだけを `latest`
にします）。前提: CI が main から `latest` を出していること（1-4）。パッケージを Public にする前は、手元で
`docker login ghcr.io -u <GHCR_OWNER>`（パスワードは PAT）をしておきます。確かめ:

```sh
kamal config -c playground/deploy/router.yml > /dev/null && echo router ok
kamal config -c playground/deploy/control.yml > /dev/null && echo control ok
cat playground/deploy/.session-image      # ghcr.io/saeki-mototsune/cybertrain-playground-web@sha256:...
```

GHCR に届かないと、docker のエラーの後に `env/clear/PLAY_SESSION_IMAGE: should be a string` で止まります
（7-1 の `PLAY_SESSION_IMAGE_REF` で前回の値を使えます。最初の 1 回だけは GHCR が要ります）。

### 4-3. kamal-proxy のログ

ホスト名（= セッションの合鍵）を長く残さないように、最初の起動の前にログの大きさを絞ります:

```sh
kamal proxy boot_config set -c playground/deploy/router.yml --log-max-size=1m
```

### 4-4. 最初のデプロイ

順番はルーターが先です（制御面はルーターがいないと作成を断ります）。4-1 の 3 つの変数を export した端末で:

```sh
kamal setup -c playground/deploy/router.yml
kamal setup -c playground/deploy/control.yml
curl -s https://<DOMAIN>/status.json      # {"accepting":true,"paused":false,"live":0,...}
```

Kamal はこのリポジトリのフック（`playground/deploy/hooks`、両方の設定の `hooks_path`）を決まった時に走らせ、
メッセージを出力に出します（`hooks_output: verbose`）。止めたときは ``Hook `pre-build` failed:`` や
``Hook `pre-deploy` failed:`` の後に理由が出ます。

- **pre-build**（イメージを作る前。`setup`、`deploy`、`redeploy`）: 作業ツリーがコミットと違うとき、または
  そのサービスのディレクトリ（`playground/router/`、`playground/control/`）にコミットしていないファイル
  （git が無視するものも）があり、その `Dockerfile.dockerignore` が外していないとき、名前を出して止めます。
  何も GHCR に出ません。macOS が置く `.DS_Store` もこれに当たります:
  `find playground/control playground/router -name .DS_Store -delete`。ロールバックは何も作らないので走りません。
- **pre-deploy**（イメージを出した後、新しい版を起動する前。`rollback` も）: ルーターでは 2 つの証明書の
  ファイル（読めて空でない）、両方で `PLAY_SUBNET_POOL` が同じこと、制御面では固定したセッションのイメージを
  VPS に pull します（`pre-deploy: pulling ghcr.io/…@sha256:… on <VPS_IP>` とイメージの ID が出ます）。制御面は
  セッションを `docker run --pull never` で作るので、この pull が要ります。
- **post-deploy**（制御面の `kamal deploy` の後）: セッションのイメージを、新しい 3 つと固定中のものを残して
  消します。VPS に届かないときや消せないときは警告だけ出して、deploy は成功のままです。

---

## 第 5 部: 公開前の確認

### 5-1. VPS とドメイン（P1〜P14）

| # | 確かめること | 期待 |
| --- | --- | --- |
| P1 | `curl -sI https://<DOMAIN>/` | 200、`server: cloudflare`、入口の CSP（`content-security-policy: default-src 'none'; …; form-action 'self' https://*.<DOMAIN>; …`） |
| P2 | `curl -s https://<DOMAIN>/status.json` | `{"accepting":true,"paused":false,"live":0,"capacity":5,"ttl_seconds":1800}`（capacity は `PLAY_MAX_SESSIONS`） |
| P3 | 手元から `curl -sk --max-time 5 --resolve <DOMAIN>:443:<VPS_IP> https://<DOMAIN>/status.json`（VPS に IPv6 のアドレスがあれば `[<v6>]` でも） | どちらも時間切れ（Cloudflare 以外は届かない） |
| P4 | VPS の上で `curl -vk --resolve <DOMAIN>:443:127.0.0.1 https://<DOMAIN>/status.json` と `curl -vk --resolve x.<DOMAIN>:443:127.0.0.1 https://x.<DOMAIN>/` | 発行者が Cloudflare Origin の証明書が、apex と一段の名前の両方で出る（複数行の PEM が届いた証拠） |
| P5 | 実ブラウザ（5-2 の B1〜B14） | すべて |
| P6 | セッションを 2 つ作り（2 つ目は別の回線、例えばスマートフォンのテザリングから）、VPS で下の「P6 のコマンド」 | 外、DNS、メタデータ、ホスト、別のセッションのどれにも届かない |
| P7 | 同じブラウザで: エディタからブラウザの戻るを 1 回（プレビューを使う前に）→ 入口で Start をもう一度 | 戻った入口のボタンは「Start a session」のまま押せる（"Starting…" で固まらない）。押すと 429 のページ「A session from your network address is already running」。`playctl status` の CLIENT に自分の IP（`CF-Connecting-IP` が届いている） |
| P8 | `curl -sI https://3000-<pid>.<DOMAIN>/` を 2 回 | `cf-cache-status` が `DYNAMIC` か `BYPASS` |
| P9 | エディタを 20 分放置 | 使えるまま、または自分で再接続する |
| P10 | `control.yml` を `PLAY_TTL: "300"` にして deploy し、1 つ作る | 約 5 分で消え（ログに `event=ended … reason=ttl`）、ネットワークも残らない（VPS で `docker network ls --filter label=cybertrain-play.role=session` が空）。元に戻して deploy |
| P11 | 時間: 制御面のログの `ready_ms`、ワークベンチが出るまで、Ruby の編集から再起動まで、`docker stats --no-stream` のメモリ | 5-4 に記録する。再ビルドが 120 秒を超えたら、ガイド・入口・サイトの「about a minute」を実測に合わせて直す |
| P12 | `playctl pause "check"` → 入口と、手元から `curl -s -o /dev/null -w '%{http_code}\n' -X POST -H 'Origin: https://<DOMAIN>' https://<DOMAIN>/sessions`、`resume`、テスト用のセッションで `kill-all`、最後に `resume` | 停止中は入口にボタンが無く「The playground is paused. Check. …」、作成は 503。`kill-all` でセッションとネットワークが消え、`resume` まで停止したまま（第 7 部） |
| P13 | `kamal app logs -c playground/deploy/control.yml --grep <sid>`（P5〜P12 で使ったエディタの URL の最初のラベル） | 行が出ない。`kamal proxy logs -c playground/deploy/router.yml --grep <sid>` には出る（想定どおり） |
| P14 | VPS を再起動 | ファイアウォールの規則が戻る（2-4 の確かめ）、ルーターと制御面が戻る（P2）、照合で残りが消える（ラベルの付いたコンテナとネットワークが無い） |

P6 のコマンド（VPS の上で。ハンドルは `playctl status` の HANDLE、別のセッションのアドレスは
`docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' ctplay-s-<別のハンドル>`）:

```sh
docker exec -i -u 1000 ctplay-s-<ハンドル> bash -s -- <VPS_IP> <別のセッションのアドレス> <<'EOF'
curl -s --max-time 5 -o /dev/null https://example.com; echo "example.com: exit $?"
getent hosts example.com; echo "DNS: exit $?"
for t in 1.1.1.1/443 169.254.169.254/80 172.17.0.1/22 "$1/22" "$1/443" "$2/8080" "$2/3000"; do
  out=$(timeout 5 bash -c "exec 3<>/dev/tcp/${t%/*}/${t#*/}" 2>&1); echo "$t: exit $? ${out##*: }"
done
EOF
```

期待: `example.com: exit 6`（または 28）、`DNS: exit 2`、残りの行はどれも `exit 124`（時間切れ）か
`exit 1 Network is unreachable` / `No route to host`。`exit 0` や `Connection refused`（そのアドレスで何かが答えた）
が 1 つでもあれば、公開を止めてファイアウォール（2-4）とネットワークを調べます。

### 5-2. 実ブラウザ（B1〜B14）

Chrome で行い、B13 で Firefox と Safari を見ます。ページの再読み込みはブラウザの再読み込みボタンで行います
（F5 はエディタの中ではデバッグの開始になります）。

| # | 確かめること | 期待 |
| --- | --- | --- |
| B1 | 入口 → Start a session | 数秒でエディタ。左に `PLAYGROUND.md`（テキスト）、右に Simple Browser（鍵の付いた自分のグループ）。端末にバナー（App の行がプレビューの URL、Ends の行）と `Listening`。10 秒以内に手を触れずにプレビューが記事一覧（手元の計測で約 7 秒） |
| B2 | プレビューで記事を作る | 303 → 詳細ページ（枠の中で Lax の Cookie が往復する） |
| B3 | ビューを編集して保存し、プレビューの再読み込みボタン。続けてモデルの編集（`validates :body, presence: true, length: { minimum: 10 }`）と保存 | ビューはすぐ。モデルは再ビルドの後（手元で保存から約 47 秒）、短い本文が 422 |
| B4 | ブラウザの再読み込みボタン | サーバーは 1 つ、"Select an instance" の確認なし、端末と右のプレビューが戻る |
| B5 | 最初の表示 | Welcome、Chat のサイドバー、信頼の確認、自動タスクの確認、Coder の宣伝がどれも出ない |
| B6 | 枠 | Simple Browser がアプリを描画する。`PLAYGROUND.md` を開いた状態でコマンドパレットの Markdown: Open Preview（⇧⌘V / Ctrl+Shift+V）を使うと、Markdown のプレビューも描画される（最初の表示はテキストなので、ここで開く）。DevTools のコンソールに `frame-ancestors` や X-Frame-Options による拒否が無い |
| B7 | 拡張機能のビューを開き、検索欄に語（例 `ruby`）を入れる | ギャラリーの一覧が出ない（何も見つからない）。DevTools のネットワークに `open-vsx.org` などの外のホストへの要求が無い |
| B8 | `.html.erb` | 言語が HTML、Emmet が効く（`ul>li*2` と Tab） |
| B9 | Ports ビュー | 3000 が `https://3000-<pid>.<DOMAIN>/` で出る。Open in Browser で通常のタブに開く。閉じたプレビューは Preview in Editor で戻る |
| B10 | 終わりの予告と時間切れ（P10 の 5 分の設定で） | 4 分で端末に黄色の `[playground] This session ends in 1 minute.`（5 分の設定では 5 分前の行は出ない）。時間切れの約 40 秒後に再接続の表示（"Attempting to reconnect"）→ 再読み込みで「No session at this address」がすぐ出る |
| B11 | タブを閉じる | 約 5 分半で `status.json` の `live` が減る（ログに `event=ended … reason=idle`） |
| B12 | エクスプローラでフォルダ（例 `app/views`）を右クリック → Download... | 最初の右クリックでクリップボードの読み取りの許可を尋ねられ（答えるまでメニューが出ない）、Download... でフォルダの選択の画面が出て、選んだ所にファイルが書かれる。メニューに Upload... は無い |
| B13 | Firefox と Safari | B1〜B4。加えて B12 をファイルとフォルダで試す（この 2 つにはフォルダを書く API が無いので、フォルダの Download は出ないか動かないことがある。そのときは `playground/web/PLAYGROUND.md` の "To keep a file or a folder" を見たとおりに直す） |
| B14 | 20 分放置 | 使えるまま、または自分で再接続（P9） |

### 5-3. VPS でしか確かめられないこと

手元（Docker Desktop）では確かめられなかったものです。P1〜P14 と一緒に見ます。

| 確かめること | どうやって | 期待（違ったとき） |
| --- | --- | --- |
| ファイアウォールの取引（Ubuntu 24.04 の iptables-nft） | 2-4 の確かめを、`sudo systemctl restart cybertrain-play-firewall` の後と、2 つ同時に走らせた後（`sudo systemctl restart cybertrain-play-firewall & sudo /usr/local/sbin/cybertrain-play-firewall; wait`）にもう一度 | ジャーナルに「rules in force」。`sudo iptables -S DOCKER-USER \| grep -c CTPLAY` と `sudo iptables -S INPUT \| grep -c 10.250.0.0/16` がどちらも 1。`iptables-restore refused …` が出たら、その規則と `iptables -V` を書き留めて公開を止める |
| Docker の再起動 | `sudo systemctl restart docker`、続けて `sudo systemctl stop docker; sudo systemctl start docker` | どちらの後も `sudo iptables -S DOCKER-USER` の最初の規則が `-j CTPLAY`、`systemctl status cybertrain-play-firewall` が active（違えば `sudo systemctl restart cybertrain-play-firewall`） |
| ufw の再読み込み | `sudo ufw reload`、`sudo iptables -S INPUT` | 最初の `-A` の行が `-A INPUT -s 10.250.0.0/16 -j DROP`。下がっていたら `sudo iptables -D INPUT -s 10.250.0.0/16 -j DROP && sudo systemctl restart cybertrain-play-firewall`（先頭に入れ直す） |
| ユニットのやり直し | `sudo mv /etc/cybertrain-play/cloudflare-ips-v4 /tmp/cf.bak && sudo systemctl restart cybertrain-play-firewall`、2 分後に `systemctl status cybertrain-play-firewall`。戻すときは `sudo mv /tmp/cf.bak /etc/cybertrain-play/cloudflare-ips-v4 && sudo systemctl reset-failed cybertrain-play-firewall && sudo systemctl restart cybertrain-play-firewall` | "activating (auto-restart)" の後、5 回で failed。その間も規則は前のまま。戻した後は active と「rules in force」 |
| 起動の直後の数秒 | P14 の後に `sudo journalctl -b -u docker -u cybertrain-play-firewall -o short-precise` | Docker の起動から「rules in force」まで数秒（その間は 80/443 が誰にでも開き、メタデータの規則も無い）。秒数を 5-4 に書く |
| kamal-proxy の本文の上限 | 手元から `head -c 1100000 /dev/zero \| curl -s -o /dev/null -w '%{http_code}\n' -X POST --data-binary @- <URL>` を、`https://<sid>.<DOMAIN>/` と `https://3000-<pid>.<DOMAIN>/articles` に | どちらも 413（kamal-proxy が 1 MB で断る）。その後もエディタとプレビューが普通に動く（WebSocket は影響を受けない） |
| 大きな応答がディスクを使わない | セッションの端末でサーバーを Ctrl-C で止め、下の「大きな応答のコマンド」で 3000 番から約 3 GB を流す。手元から `curl -s -o /dev/null -w '%{size_download}\n' https://3000-<pid>.<DOMAIN>/`、その間 VPS で `df -h /` | 約 3.2 GB を受け取り、VPS のディスクの使用量が増えない（kamal-proxy は応答を溜めない）。終わったら端末で `playground-server` |
| ダイジェストで pull したイメージ | 最初の deploy の後の B1 | セッションが作られる（ログに `docker_error step=run` の "No such image" が出ない） |
| 掃除（post-deploy） | セッションのイメージが 4 つ以上になる deploy の後、VPS で `docker images --no-trunc ghcr.io/saeki-mototsune/cybertrain-playground-web` | 新しい 3 つと固定中のもの（`.session-image`）だけが残る |
| フックが本物の SSH で動く | `playground/control/` に空のファイルを作って `kamal deploy -c playground/deploy/control.yml`（その後ファイルを消す）。`env -u PLAY_ORIGIN_CERT kamal deploy -c playground/deploy/router.yml` | 前者は ``Hook `pre-build` failed:`` で止まり、GHCR に新しいタグが出ない。後者は `pre-deploy: PLAY_ORIGIN_CERT is not set: …` で止まり、動いているルーターはそのまま。どちらもフックのメッセージが出力に出る |
| ルーターの `dns` と `sysctl` | `docker inspect -f '{{.HostConfig.Dns}} {{.HostConfig.Sysctls}}' $(docker ps -q --filter label=service=cybertrain-play-router)` | `[127.0.0.1] map[net.ipv4.ip_forward:0]`。Docker が sysctl を断ってルーターが起動しないときは、`router.yml` の `sysctl:` の行を外して出し直す |
| 制御面の入れ替え | `kamal deploy -c playground/deploy/control.yml` の最中に Start | セッションが作られるか 503 で断られる。どちらでも、deploy の後の `playctl status` と `docker ps --filter label=cybertrain-play.role=session` が一致し、上限を超えない。deploy が「not healthy」で止まらない（制御面は 30 秒以内に healthy になる） |
| ロールバックが pull する | 6-2 のロールバックを試しに一度 | 出力に `pre-deploy: pulling … on <VPS_IP>`。`PLAY_SESSION_IMAGE_REF` を付けたときは、新しいコンテナの `PLAY_SESSION_IMAGE` がその参照（`docker inspect`） |

大きな応答のコマンド（セッションの端末で。1 回の要求に答えて終わります）:

```sh
ruby -rsocket -e 's = TCPServer.new("0.0.0.0", 3000); c = s.accept; c.gets; c.write "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nConnection: close\r\n\r\n"; z = "\0" * 65536; 50_000.times { c.write z }; c.close'
```

### 5-4. 記録

| 項目 | 手元の計測（Apple M5、Docker Desktop、Cloudflare なし） | VPS |
| --- | --- | --- |
| Start から 303 まで | 0.6〜0.8 s |  |
| セッションのコンテナが答えるまで（ログの `ready_ms`） | 263〜523 ms |  |
| Start からワークベンチが出るまで | 2〜3 s |  |
| Start からプレビューに記事一覧が出るまで | 約 7 s |  |
| Ruby の編集から再起動まで | 約 47 s |  |
| エディタ接続中のメモリ（`docker stats --no-stream`） | 未計測（スパイクでは 456 MiB） |  |
| タブを閉じてから終わるまで | 約 5 分半 |  |
| 起動の後、ファイアウォールの規則が入るまで | — |  |
| gVisor（第 8 部） | — |  |

確認が終わったら、Cloudflare で HSTS を有効にします（第 3 部）。

---

## 第 6 部: 日々の運用

### 6-1. 更新

制御面とセッションのイメージ: main に入れる → CI が web のイメージを試験して `latest` を出す（`image` ジョブが
通ってから `web` ジョブ）→

```sh
kamal deploy -c playground/deploy/control.yml
```

ERB が新しいダイジェストを固定し、pre-deploy が pull します。動いているセッションは元のイメージで最後まで動き、
新しいセッションから新しいイメージになります。

- deploy の前に作業ツリーをコミットにそろえます（pre-build が止めます。4-4）。
- Actions の手動実行（Playground image → Run workflow）でタグ `latest` を出すと、どのブランチからでも、次の
  deploy がそれをセッションのイメージに固定します。試すときは `latest` 以外のタグにします。

### 6-2. ロールバック

```sh
kamal app containers -c playground/deploy/control.yml      # 版を見る
kamal rollback <version> -c playground/deploy/control.yml
```

`kamal rollback` は古い版の制御面を、今読んだ設定で起動します。セッションのイメージは、その時に `latest` が
指すものに固定され、pre-deploy がそれを VPS に pull します。つまり悪いのがセッションのイメージなら、これだけ
では戻りません。セッションのイメージも戻すときは、古い参照を VPS で調べて付けます:

```sh
# VPS で: 古い版のコンテナの環境から
docker inspect cybertrain-play-web-<version> --format '{{range .Config.Env}}{{println .}}{{end}}' | grep '^PLAY_SESSION_IMAGE='
# 手元で
PLAY_SESSION_IMAGE_REF=<その参照> kamal rollback <version> -c playground/deploy/control.yml
```

古いイメージが VPS から消えていても、pre-deploy が GHCR から pull し直します。次の `kamal deploy` は、変数が
無ければまた `latest` を固定します。直した `latest` を CI が出すまでは、deploy にも同じ変数を付けます。

### 6-3. ルーターを出す

kamal-proxy が古いルーターを抜くとき、全エディタの WebSocket が切れます（VS Code が数秒で再接続します。
プレビューは再読み込みが要ることがあります）。できれば静かなときに、4-1 の 2 つの証明書の変数を export した
端末で:

```sh
kamal app exec -c playground/deploy/control.yml --reuse 'bin/playctl pause "maintenance"'
kamal app exec -c playground/deploy/control.yml --reuse 'bin/playctl status'   # 0 になるまで待つ（最長 30 分）
kamal deploy -c playground/deploy/router.yml
kamal app exec -c playground/deploy/control.yml --reuse 'bin/playctl resume'
```

新しいルーターは、制御面の刈り取り（5 秒ごと）が全セッションのネットワークへつなぎます（E2E の E15 は
10 秒以内を求め、手元では 6〜7 秒でした）。

### 6-4. code-server の版上げ

`playground/Dockerfile` の `CODE_SERVER_VERSION` と 2 つのチェックサム（GitHub のリリースの各ファイルの sha256）を
替える PR → CI → 5-2 の確認表（設定の効く範囲が版で変わりうるため）→ 制御面の deploy。月に 1 度を目安に、
code-server、Caddy、ベースイメージの新しい版を確かめます。

版を上げたら、次の 2 つを必ず手で確かめます。どちらも code-server 4.139.1 のふるまいに頼っています:

- B4: ブラウザの再読み込みでプレビューが戻ること（`playground/web/settings.json` の
  `"window.restoreWindows": "preserve"`。エディタの URL が毎回ガイドを開くので、これが無いと他のエディタが戻らない）。
- エクスプローラから開いたファイルが、プレビューの横（ガイドの側）に開くこと（code-server が Simple Browser の
  グループに既定で鍵を掛けるため）。

ガイドはテキストで開きます。描画した形（`workbench.editorAssociations`）に戻すと、プレビューがガイドの上に
重なって開くので戻さないでください。

### 6-5. 証明書

Origin CA を作り直したら、`PLAY_ORIGIN_CERT` / `PLAY_ORIGIN_KEY` のファイルを替えて
`kamal deploy -c playground/deploy/router.yml`（kamal-proxy は証明書をデプロイのときにだけ読みます）。
`kamal app boot` は使いません（4-1）。

### 6-6. 容量を変える

プロバイダでプランを上げる（再起動を伴います）→ `control.yml` の `PLAY_MAX_SESSIONS` を 1-3 の表に合わせる →
`kamal deploy -c playground/deploy/control.yml`。他は何も変えません。ワークショップの日（NAT の向こうから大勢が
来る）は `PLAY_MAX_SESSIONS_PER_IP` も上げます。

### 6-7. ログと監視

| 見るもの | どうやって |
| --- | --- |
| 制御面の出来事 | `kamal app logs -c playground/deploy/control.yml -f`。1 行に 1 つ: `event=created`（`ready_ms`、`live`）、`ended`（理由 `ttl` `idle` `exited` `orphan` `killed` `failed`）、`refused`（理由 `full` `per_ip` `rate` `paused` `origin` `unavailable` `failed`）、`docker_error`（`step` が段）、`unavailable` と `available`（Docker かセッションのイメージ）、`suspect`（CPU）、`dropped`、`error`（予期しない例外。クラス名だけ）。`playctl` の出来事は入らない（7-1） |
| 生きているセッション | `kamal app exec -c playground/deploy/control.yml --reuse 'bin/playctl status'` |
| 公開の状態 | `https://<DOMAIN>/status.json` |
| ルーター | 普段はログなし。調べるときは `router.yml` の `env.clear` に `ROUTER_LOG_OUTPUT: stderr` を足して出し直し（6-3 のとおりエディタが再接続します）、`kamal app logs -c playground/deploy/router.yml`。終わったら外して出し直す |
| kamal-proxy | `kamal proxy logs -c playground/deploy/router.yml`（ホスト名を含みます。人に渡さないこと） |
| ホスト | `df -h`、`docker system df`、プロバイダのグラフ。週に 1 度 |
| 外形監視（任意） | リポジトリの変数 `PLAYGROUND_URL` に `https://<DOMAIN>`（末尾の `/` なし）を入れると、`.github/workflows/playground-uptime.yml` が 30 分ごとに `status.json` を取り、失敗すると GitHub が通知のメールを送ります。入れたら Actions → Playground uptime → Run workflow で一度通ることを見ます。停止中や満員でも通ります（答えないときだけ落ちます） |

### 6-8. ホストの掃除

古いセッションのイメージは post-deploy フックが、新しい 3 つと固定中のものを残して消します。`docker system df`
で使われていない volume が溜まっていれば `docker volume prune -f`。`docker image prune` と `docker system prune`
は使いません: セッションのイメージはダイジェストで pull したタグの無いイメージで、セッションが 1 つも動いて
いないときに消されると、次の作成から「Its session image is missing」で断り続けます（戻すには
`kamal deploy -c playground/deploy/control.yml`）。

### 6-9. 暦に書くこと

- Origin CA の期限（作った日から 15 年。通知は来ません）。
- 月に 1 度: code-server、Caddy（`caddy:2.11.4-alpine`）、ベースイメージ（`ubuntu:24.04`、`ruby:4.0.7-slim`、
  `docker:28-cli`）の新しい版（6-4）。
- 週に 1 度: 6-7 のホストの確認。
- まれに: Cloudflare の範囲の見直し（2-4 の取り直し）。
- 公開リポジトリでは、60 日間リポジトリに動きがないと GitHub が予定のワークフロー（外形監視）を止めます。
  止まったら Actions の画面で有効に戻します。

---

## 第 7 部: 緊急停止と不正利用

### 7-1. 停止スイッチ（playctl）

| コマンド | すること |
| --- | --- |
| `bin/playctl status` | セッションごとに HANDLE、STATE、AGE と LEFT（分）、CPU、MEMORY、CLIENT（制御面が動いていればクライアントのアドレス）。最後の行に「N of M sessions; accepting」か「…; paused: <メッセージ>」 |
| `bin/playctl pause [message]` | 新しい作成を止め、入口にメッセージを出す（無ければ「for maintenance」。`-` で始まるものは断る）。動いているセッションはそのまま |
| `bin/playctl resume` | 作成を再開する |
| `bin/playctl end <handle>` | そのセッションを片付ける。ハンドルは小文字の 16 進 16 桁。無いハンドルには `playctl: no session <handle>` と出して 1 で終わる |
| `bin/playctl kill-all` | 停止したうえで、全セッションを片付ける。停止は残るので、再開は `resume` |

実行の仕方:

```sh
kamal app exec -c playground/deploy/control.yml --reuse 'bin/playctl pause "maintenance"'
```

出力の例: `paused: Maintenance. Running sessions go on; playctl resume starts accepting again.`、
`resumed: new sessions are accepted`、`ended <handle>`、
`killed every session; the playground stays paused until playctl resume`。

- 引数を取らないコマンド（`status`、`resume`、`kill-all`）に余計な引数を付けると、使い方を出して 2 で終わります
  （`kill-all --help` で全セッションが消えることはありません）。
- `kill-all` の直後は、刈り取りが残りを片付け終えるまで（約 5 秒）、`status` と `resume` が
  `playctl: a kill-all is pending: …` と警告します。その間に現れたセッションも片付けられます。
- `playctl` の出来事の行（`play event=ended … reason=killed` など）は、実行した端末に出ます。サーバーのログ
  （`kamal app logs`）には出ないので、`playctl end` したセッションはログでは `created` だけに見えます。
- `end` が `… is not fully removed (see the docker_error line); the reaper retries` と言ったら、刈り取りが次の回
  （5 秒ごと）でやり直します。`status` で消えたことを確かめます。
- `pause` のメッセージは日本語でも構いません（UTF-8 で読みます）。

Kamal のコマンドはどれも `control.yml` を読み、そのたびに GHCR へダイジェストを問い合わせます。GHCR に届かない
ときは、前回のデプロイの値で固定してから実行します:

```sh
PLAY_SESSION_IMAGE_REF=$(cat playground/deploy/.session-image) kamal app exec -c playground/deploy/control.yml --reuse 'bin/playctl kill-all'
```

### 7-2. 制御面が動いていないとき

VPS の上で直接:

```sh
docker ps -aq --filter label=cybertrain-play.role=session | xargs -r docker rm -f
for n in $(docker network ls -q --filter label=cybertrain-play.role=session); do
  for c in $(docker network inspect -f '{{range $id, $x := .Containers}}{{$id}} {{end}}' "$n"); do
    docker network disconnect -f "$n" "$c"; done
  docker network rm "$n"
done
sudo touch /var/lib/cybertrain-play/paused
```

再開は `sudo rm /var/lib/cybertrain-play/paused`（または `playctl resume`）。

### 7-3. 不正利用の手順書

| 兆候 | すること |
| --- | --- |
| CPU を使い続けるセッション（`event=suspect` の行、`playctl status`） | `playctl status` でハンドルとアドレスを見て `playctl end <handle>`。繰り返すなら Cloudflare の Security → WAF → Tools の IP Access Rules でそのアドレスを Block |
| 多くのアドレスからの大量の作成 | WAF のカスタム規則「`(http.host eq "<DOMAIN>" and http.request.uri.path ne "/status.json")` → Managed Challenge」（入口だけ。エディタとプレビューには掛けない。`/status.json` を外すのは外形監視のためで、外さないと 30 分ごとに失敗のメールが来ます）を有効にし、必要ならレート制限の規則（Free で 1 つ）「`POST /sessions`、同じ IP で 10 秒に 5 回」→ Block。まだ多ければ `playctl pause` |
| プレビューのホストのフィッシング・マルウェアの通報 | 30 分以内に消えているはず。`playctl status` で生きていれば `end`。分からなければ `kill-all`。通報者に返信する。Safe Browsing に載ったら Search Console で再審査を依頼する |
| Cloudflare からの不正利用の通知 | 上と同じ。ダッシュボードで返答する |
| 脱出・侵害の疑い | `playctl kill-all` → 両サービスを `kamal app stop -c playground/deploy/control.yml`、`kamal app stop -c playground/deploy/router.yml` → プロバイダのスナップショットで保全 → VPS を作り直す → 秘密を替える（GHCR の PAT、Origin CA は失効して作り直す）→ SECURITY.md の窓口で記録する |
| ディスクが埋まる | `docker system df`、6-8 の掃除（セッションのイメージは消さない）、ログの大きさ |

生きているログ（とくに kamal-proxy のもの）は、セッションの合鍵を含むので人に渡しません。

---

## 第 8 部: gVisor

最初の週に計測して、実行環境を runc から gVisor（`runsc`）に替えるかを決めます。

1. VPS で gVisor の apt リポジトリを足して入れます（https://gvisor.dev/docs/user_guide/install/ ）:
   `sudo apt-get install -y runsc`、`sudo runsc install`、`sudo systemctl reload docker`
   （再起動ではないので、動いているコンテナは止まりません）。
2. 計測（同じイメージ、同じ制限で runc と runsc を比べます）:

   VPS の上で、手元の `playground/deploy/.session-image` に書かれた参照を `img` に入れてから:

   ```sh
   img=ghcr.io/saeki-mototsune/cybertrain-playground-web@sha256:...
   docker run --rm --cpus 1 --memory 1536m --entrypoint bash "$img" -lc 'cd /workspace/blog && touch app/controllers/articles_controller.rb && time cybertrain spin build blog'
   docker run --rm --cpus 1 --memory 1536m --runtime runsc --entrypoint bash "$img" -lc 'cd /workspace/blog && touch app/controllers/articles_controller.rb && time cybertrain spin build blog'
   ```

   最後の `real` が再ビルドの時間です（イメージに `/usr/bin/time` は無いので bash の `time` を使います。手元の
   runc では `real 0m39.9s`）。code-server の起動から `/healthz` まで、エディタ接続中のメモリ
   （`docker stats --no-stream`）も比べます。
3. 互換性: リポジトリのチェックアウトがある VPS か手元の Linux で
   `RUNTIME=runsc bash playground/web-smoke.sh <セッションのイメージ>` がすべて通ること。チェックアウトは
   イメージと同じコミットにします（W1 と W2 が code-server と CLI の版を比べます）。
4. 目安: 再ビルドが runc の 1.5 倍以内（約 70 s）で、スモークがすべて通れば、`control.yml` を
   `PLAY_RUNTIME: runsc` にして `kamal deploy -c playground/deploy/control.yml`。新しいセッションから gVisor に
   なります。ルーターは runc のままです。替えたら P6 と B1〜B4 をもう一度見ます。
5. 結果を 5-4 の表に書きます。採らない場合も数字と理由を残します（カーネル脱出の危険を受け入れる根拠になります）。

---

## 第 9 部: 公開（サイトと README の入口）

第 5 部が通ってから、サイトの playground ページと README に入口を足します。差分は
[launch.patch](launch.patch) に用意してあり、ドメインの所だけが `<DOMAIN>` になっています:

```sh
git switch -c web-playground-launch main
sed 's/<DOMAIN>/<実際のドメイン>/g' playground/deploy/launch.patch | git apply
git diff --stat      # README.md、site/README.md、site/assets/style.css、site/playground.html
python3 -m http.server -d site 8000   # http://localhost:8000/playground.html を見る
# playground/README.md の冒頭の "its address goes here once it is public" をアドレスを示す文に替える（下）
git add README.md site/README.md site/assets/style.css site/playground.html playground/README.md
git commit -m "Site: the hosted playground's entry"
```

- `git apply` が当たらないとき（main で README.md や site/ が変わった）は `git apply --3way` を試し、それでも
  だめなら差分を見て手で足します。サイトの内容規則（`site/README.md`）: サイトの主張はどれも README.md にも
  書きます。差分は同じ事実を両方に書いています。
- `playground/README.md` の冒頭の "its address goes here once it is public" は、例えば
  "it is at https://<実際のドメイン>/" にします（差分には入っていません）。

サイトのボタンはそのまま `https://<DOMAIN>/sessions` に POST します（制御面の `PLAY_ALLOWED_ORIGINS` にサイトの
オリジン `https://saeki-mototsune.github.io` が入っています）。PR にしてマージすると Pages がサイトを出します。
出たら、サイトの playground ページのボタンから一度セッションを作り、エディタに着くことを確かめます。続けて
外形監視の変数を入れます（6-7）。

---

## トラブルシューティング

| 症状 | 見る所 |
| --- | --- |
| エディタが「Cannot reconnect」/「Attempting to reconnect」 | セッションが終わった（時間切れ、タブを閉じて約 5 分半）なら、ブラウザの再読み込みで「No session at this address」がすぐ出る。動いているのに切れるならルーターがつながっていない: VPS で `docker network inspect ctplay-n-<handle>` の Containers にルーターがいるか。制御面の刈り取りが 5 秒ごとにつなぎ直す |
| プレビューが開かない | 「No app is answering here」（502）なら開発サーバーが動いていない: 端末で `playground-server`。Ports ビューの 3000 の URL が `https://3000-<pid>.<DOMAIN>/` か。閉じたプレビューは Ports ビューの 3000 の Preview in Editor で戻る |
| 作成が 503 | `kamal app logs -c playground/deploy/control.yml` の `docker_error`（段 `network`、`connect`、`run`）と `unavailable`（`image_missing` ならセッションのイメージを pull し直す: `kamal deploy -c playground/deploy/control.yml`） |
| 入口が 503（"not available"） | 制御面が落ちている。`kamal app details -c playground/deploy/control.yml`、`kamal app logs -c playground/deploy/control.yml` |
| Cloudflare の 52x | 521: オリジンが答えない（kamal-proxy が動いているか、ファイアウォールの一覧に Cloudflare の範囲が漏れていないか）。524: オリジンの応答が Cloudflare の待ち時間を超えた（作成なら `ready_ms` と `docker_error` を見る） |
| `kamal` のコマンドが設定を読むところで失敗する | docker のエラーの後に `env/clear/PLAY_SESSION_IMAGE: should be a string`: GHCR に届かない。7-1 の `PLAY_SESSION_IMAGE_REF`。`session-image: … is not an image reference` なら参照の形が違う（`<repository>@sha256:<小文字の 16 進 64 桁>`） |
| ``Hook `pre-build` failed:`` | コミットしていない変更か、サービスのディレクトリのコミットしていないファイル（名前が出る）。コミットするか消す（4-4） |
| ``Hook `pre-deploy` failed:`` | 理由の行を読む: 証明書の変数（4-1）、`PLAY_SUBNET_POOL` の食い違い（2-1）、`.session-image` が無い（`kamal config -c playground/deploy/control.yml` を一度）、VPS での pull の失敗（VPS から GHCR に届くか、PAT） |
| ファイアウォールのユニットが failed | `sudo journalctl -u cybertrain-play-firewall -n 20 --no-pager` の「…; nothing changed」の理由を直し、`sudo systemctl reset-failed cybertrain-play-firewall && sudo systemctl restart cybertrain-play-firewall` |
| F5 で「You don't have an extension for debugging Ruby」 | エディタの中の F5 はデバッグの開始。Cancel を押し、ブラウザの再読み込みボタンを使う |
| 戻るボタンで入口に戻れない | プレビューの中の移動が履歴に積まれるので、何回も押すことになる（想定どおり）。出るときはタブを閉じる |
| エクスプローラの右クリックでメニューが出ない | Chrome がクリップボードの読み取りの許可を尋ねている（アドレスバーの所）。どちらかで答えるとメニューが出る |
| 外形監視が 30 分ごとに失敗する | `status.json` が答えない（P2）か、WAF の規則が `/status.json` にも確認を挟んでいる（7-3 の形で外す） |
