# web playground SP2: ログイン不要のホスト型プレイグラウンド

> **Status: abandoned on 2026-10-07.** The hosted playground was built and tested (on one machine and in GitHub Actions) and its session image was published to GHCR, but it was never deployed; the owner decided that GitHub Codespaces (SP1) is enough to try cybertrain. Its code was removed from the tree in the commit "Remove the hosted playground (cancelled)"; the merge of PR #12 still has it. This document is kept for its measurements and its threat model. The published image `ghcr.io/saeki-mototsune/cybertrain-playground-web` is no longer built.

2026-10-02。ブランチ `web-playground-sp2`（SP1 のブランチ `web-playground` の上に積む。SP1 は実装済みで、push と
実機確認が未了）。状態: 2026-10-02 にオーナーが設計を承認（新規の小さめの VPS、専用ドメイン + Cloudflare、
本書の構成と既定値）。前提: オーナーの決定と調査メモ（コンテナスパイク、code-server のスパイク、脅威モデル、
ホスティングの調査。リポジトリには入れていない作業メモで、本書が頼る事実は下の印を付けて本文に写してある。
code-server のスパイクのメモは途中の版で、頼るのは計測済みの「Interim result 1〜4」だけ）、
SP1 の spec（`docs/superpowers/specs/2026-10-02-web-playground-sp1-design.md`、特に §4.6 の約束と §14 の実装後の差分）と
SP1 の実装、spinel scope の公開部分（`config/deploy.yml` は読んでいない）。

> **2026-10-03 の注記**: 実装は終わり、§15 と §16（実装後の実態）が本文に優先する。デプロイと運用の手順は本文の §7 ではなく、実装後の実態に合わせた `playground/deploy/README.md`（運用ガイド）に従うこと。本文の §7.4〜§7.6、§7.11、§7.12 のコマンドや設定の全文には、そのまま使うと最初のデプロイが失敗する・ホストが無防備になる記述が残っている（§16.5 に一覧）。

事実の出どころの印:

- **[計測]** スパイクか SP1 の実装で測った値（Apple M5 上の Docker Desktop、linux/arm64。x86 の VPS では未計測）。
- **[ソース]** 上流のソースを読んで確かめたこと（調査メモに書かれたものを含む）。
- **[文書]** 公式文書で読んだこと。
- **[推論]** 上の事実からの推論。
- **[未検証]** まだ誰も確かめていないこと。§12.1 に一覧にし、plan の最初のタスクで確かめる。

本書が決めた細部には「（本 spec での決定）」と付け、§14 に一覧にした。オーケストレーターの既定案から
変えたものは理由を添えた。

## 1. 目的

### 1.1 届けるもの

訪問者はアカウントなしで「Start a session」を押す。数秒でブラウザに VS Code（code-server）が開き、
チュートリアルのブログ、端末で動く開発サーバー、エディタ内のプレビューに表示されたアプリが揃っている。
プレビューの中でフォームが動き、編集の待ち時間は SP1 と同じ（ビューは次のリクエスト、Ruby は約 1 分）。
決まった時間（既定 30 分）が来るとセッションはファイルごと消える。

1. イメージの新しいステージ `web`（`playground/Dockerfile` の最後、`playground` の後）: SP1 のイメージに
   code-server 4.139.1、ユーザー設定、起動タスク、SP2 用のガイド、セッションのエントリポイントを足したもの。
   公開名 `ghcr.io/saeki-mototsune/cybertrain-playground-web`（§4）。Codespaces のイメージ（`playground`）は変わらない。
2. 制御面（control plane）: Ruby + Sinatra + Puma の小さなアプリ。ランディングページ、セッションの作成、
   上限、刈り取り、停止スイッチ（§5）。
3. ルーター: 静的な Caddyfile を持つ素の Caddy。ホスト名でセッションのコンテナへ振り分ける（§6）。
4. デプロイ: Kamal の 2 サービス（ルーターと制御面）、ホストのファイアウォール、Cloudflare の設定、
   日本語の運用ガイド（§7、§9.4）。
5. ローカル開発とテスト: `*.localhost` で全体を動かす compose、制御面の単体テスト、イメージのスモークテスト、
   全体の E2E、実ブラウザの確認表（§8）。
6. サイトと README の入口。サービスが動いてから入れる別のコミットとして用意する（§9.1）。

フレームワーク（`cybertrain/`）は変えない。SP1 の `CYBERTRAIN_HOST` と既定の `SameSite=Lax` で足りる（§3.5 (b)、§4.4）。

### 1.2 訪問者の体験

1. **入口。** サイトの `playground.html` の「Start a session」（フォームの POST、JavaScript 不要、§9.1）か、
   `https://<DOMAIN>/` のランディングページ（§5.13）のボタンを押す。ランディングには空きの状況
   （"3 of 5 sessions are free."）、制限（30 分で消える、ネットワークなし、1 つのアドレスに 1 つ）、
   利用条件への短い案内が出る。
2. **作成。** 制御面が上限を確かめ、セッション専用の内部ネットワークを作り、ルーターをつなぎ、
   硬化したコンテナを起動し、ルーター経由で code-server の `/healthz` が答えるのを待つ。
   目安 2〜4 秒（[推論]: コンテナの起動と code-server の起動。作成全体は [未検証]、§8.6 で VPS 上で計る）。
   答えたら `303` でエディタの URL へ送る:
   `https://<sid>.<DOMAIN>/?folder=/workspace/blog&payload=[["openFile","vscode-remote://<sid>.<DOMAIN>/workspace/blog/PLAYGROUND.md"]]`
   （payload は URL エンコードする）。
3. **エディタが開く。** 最初に見えるもの: エクスプローラにブログのファイル、左のエディタに
   `PLAYGROUND.md`（Markdown のプレビュー表示、[未検証] V9。駄目ならテキスト表示）、下のパネルに
   タスク「cybertrain server」の端末。Welcome タブ、Chat のサイドバー、信頼の確認、自動タスクの確認は出ない
   （それぞれを消す設定とフラグは [計測]、スパイク Interim 4）。
4. **サーバー。** フォルダを開いたときのタスク（`runOn: folderOpen`）が `playground-server` を実行する。
   バナー（アプリの URL `https://3000-<pid>.<DOMAIN>/`、ガイドの場所、残り時間と終了時刻）を出してから
   `cybertrain server` を前面で起動する。ビルド済みなのでコンパイルせず、待ち受けまで 0.08〜0.48 s [計測]。
5. **プレビュー。** ポート 3000 の待ち受けを VS Code が検出し（端末の子孫のプロセスだから、[計測]）、
   `onAutoForward: "openPreview"` が Simple Browser をエディタの横に開いて記事一覧を出す [計測]。
6. **フォーム。** プレビューの中で記事を作ると 303 で詳細ページへ進む。エディタ `<sid>.<DOMAIN>` と
   プレビュー `3000-<pid>.<DOMAIN>` は同じ登録可能ドメインの兄弟なので同一サイトで、`SameSite=Lax` の
   Cookie が iframe の中でも往復する（[計測]、スパイク Interim 2 の配置 (iii)。Chromium。Firefox と Safari は [未検証]）。
7. **編集。** ビューの編集は次のリクエストで出る（20 ms 未満 [計測]）。Ruby の編集は再ビルドで、1 CPU で
   約 46 s [計測、arm64]、その後サーバーが自分で再起動する。プレビューは自動では再読み込みしない。
8. **終わりの予告。** 終了の 5 分前と 1 分前に、開いている端末すべてに黄色の 1 行が出る
   （"This session ends in 5 minutes: it is deleted with its files. Download what you want to keep."）。
   エクスプローラの右クリック「Download」でファイルを持ち帰れる（アップロードは無効、§4.2）。
9. **時間切れ。** 制御面がコンテナとネットワークを消す。エディタは「再接続中」の表示の後、再接続できないと
   出す。再読み込みするとルーターの「No session at this address」ページ（新しいセッションへのリンク、
   Codespaces へのリンク）が出る（§4.10）。
10. **タブを閉じた場合。** code-server の `--idle-timeout-seconds 300` で、最後のクライアントが離れてから
    約 6 分で終わり、枠が空く（[計測]: 90 秒の設定で離脱から 153 s 後に終了。既定の 300 では約 360 s と [推論]）。
11. **満員のとき。** ランディングに "All 5 sessions are in use" と出る。押すと `503` のページ
    （数分で空くこと、Codespaces の案内、Retry-After 60）。同じアドレスで 2 つ目を作ろうとすると `429` のページ
    （今のセッションの終了時刻を示す）。

### 1.3 引用する計測値

| 項目 | 値 | 出典 |
| --- | --- | --- |
| code-server 1 セッションのメモリ | クライアント接続中 456 MiB、なし 70 MiB、77 PID | [計測] スパイク Interim 4 |
| 再ビルドの山 | anon 417 MiB、`memory.current` 427〜446 MiB | [計測] コンテナスパイク §4 |
| Ruby の編集から新しい動作まで | 1 CPU で 45.5〜46.6 s、0.5 CPU で約 107 s | [計測] コンテナスパイク §4 |
| ビルド済みでの起動 | 0.08〜0.48 s | [計測] |
| ビューの編集 | 次のリクエスト（20 ms 未満） | [計測] |
| アイドルの開発サーバー | 22 MB PSS | [計測] |
| `cybertrain new`（ミラー経由、ネットワークなし） | 3.6 s | [計測] |
| アイドル終了 | `--idle-timeout-seconds 90` で離脱から約 153 s | [計測] スパイク Interim 4 |
| 硬化フラグ | `--read-only` + tmpfs、`--cap-drop ALL`、`no-new-privileges`、`--pids-limit 512 --memory 1g --cpus 1` でエディタ、端末、自動プレビューが動く | [計測] スパイク Interim 4 |
| ネットワークの既定プール | 31 個（`docker0` と Kamal の分を引くと約 29） | [ソース] moby |
| x86 の VPS での上の値すべて | 未計測 | §8.6 |

## 2. スコープ外

- **Deploy now と GitHub ログイン（SP3）**。本書は SP3 を妨げない継ぎ目だけを決める（§13）。
- **訪問者の作業の保存**。セッションはファイルごと消える。持ち帰りはブラウザのダウンロードだけ。
- **アカウント、Cookie によるセッション管理**。制御面は Cookie を出さない。
- **複数サーバーへの振り分け**、待ち行列（満員なら「後でもう一度」）、事前に温めたコンテナのプール（脅威モデル N2）。
- **gVisor の採用判断**。実行環境は設定値にし、VPS で計測してから切り替える（§7.12）。
- **rootless Docker（S4）と userns-remap（S7）**。理由は §3.6。
- **Turnstile などの CAPTCHA**。必要になれば Cloudflare の WAF 規則で代える（§7.11）。
- **セッション内からのネットワーク**（`gem install`、外への `curl`、`git push`）。プレビューできるのはポート 3000 だけ。
- **拡張機能**（ruby-lsp、ERB 用のハイライト拡張を含む）。`.html.erb` は組み込みの HTML として表示する（§4.4）。
- **ライブリロード**、モバイル向けの調整、ランディングページの多言語化、アクセス解析。
- **フレームワークの変更**。端末を閉じたときに開発ループが SIGHUP を再起動と扱う件（SP1 §14.5）も直さない。
- **Cloudflare Tunnel**（オーナーの決定は Origin CA 証明書。§3.5 (f)）。

## 3. 構成

### 3.1 部品

| 部品 | 中身 | 管理 | ネットワーク |
| --- | --- | --- | --- |
| Cloudflare（Free） | プロキシする `<DOMAIN>` と `*.<DOMAIN>`、Universal SSL、キャッシュの迂回 | オーナー（ダッシュボード） | インターネット |
| kamal-proxy | TLS の終端（Origin CA のワイルドカード証明書）、ホスト名でサービスへ | Kamal | ホストの 80/443（Cloudflare の範囲だけ許す） |
| ルーター | 素の Caddy と静的な Caddyfile。`<DOMAIN>` を制御面へ、セッションのホスト名をコンテナへ | Kamal（サービス `cybertrain-play-router`） | `kamal` + 全セッションのネットワーク |
| 制御面 | Sinatra + Puma 1 プロセス。Docker の CLI と `/var/run/docker.sock` | Kamal（サービス `cybertrain-play`、プロキシなし） | `kamal` だけ |
| セッションのコンテナ | `cybertrain-playground-web` イメージ、code-server :8080、開発サーバー :3000 | 制御面（Kamal ではない） | 自分専用の `--internal` ネットワークだけ |
| セッションのネットワーク | `--internal`、明示した /28、ルーターと 1 つのコンテナだけ | 制御面 | — |
| ホストのファイアウォール | セッションの範囲からホストとメタデータへの通信を落とす。80/443 を Cloudflare に絞る | systemd のユニット（§7.5） | — |

### 3.2 図

```
 訪問者のブラウザ
   │ HTTPS / WSS:  <DOMAIN>（入口）  <sid>.<DOMAIN>（エディタ）  3000-<pid>.<DOMAIN>（プレビュー）
   ▼
 Cloudflare Free: 「*」と apex をプロキシ、Universal SSL、全体のキャッシュを迂回、CF-Connecting-IP を付ける
   │ HTTPS（Full (strict)、Origin CA *.<DOMAIN>）。オリジンの 443 は Cloudflare の範囲からだけ
   ▼
 VPS（Ubuntu 24.04、Docker、Kamal 2）─────────────────────────────────────────────────────────
 │ kamal-proxy :443 ── hosts <DOMAIN>, *.<DOMAIN> ──▶ ルーター（Caddy :80、network alias ctplay-router）
 │                                                     │  <DOMAIN>              → ctplay-control:9292
 │  ネットワーク "kamal"                                │  <sid>.<DOMAIN>        → s-<sid>:8080（code-server）
 │  ┌──────────────────────────────┐                   │  3000-<pid>.<DOMAIN>   → p-<pid>:3000（開発サーバー）
 │  │ 制御面（Sinatra、/data、       │◀──────────────────┘  セッションの範囲（10.250/16）からの接続 → abort
 │  │  docker.sock、alias ctplay-control）                 その他のホスト名         → 404「No session」
 │  └───────┬──────────────────────┘
 │          │ docker CLI（argv の配列。シェルを通さない）
 │          ▼
 │       dockerd ──作成──▶ ┌ ctplay-n-<h1>（--internal 10.250.0.0/28）──────────┐
 │                         │ ctplay-s-<h1>（alias s-<sid1>, p-<pid1>） ◀─ ルーター │
 │                         └──────────────────────────────────────────────────┘
 │                         ┌ ctplay-n-<h2>（--internal 10.250.0.16/28）─────────┐
 │                         │ ctplay-s-<h2>（alias s-<sid2>, p-<pid2>） ◀─ ルーター │
 │                         └──────────────────────────────────────────────────┘
 │ ファイアウォール: INPUT と DOCKER-USER で 10.250.0.0/16 から外（ホスト自身を含む）を落とす、
 │                  169.254.169.254 を落とす、公開ポート 80/443 は Cloudflare の範囲だけ
 └───────────────────────────────────────────────────────────────────────────────────────
```

### 3.3 ホスト名（本 spec での決定）

| 用途 | ホスト名 | 中身 |
| --- | --- | --- |
| 入口・作成・利用条件 | `<DOMAIN>` | 制御面 |
| エディタ | `<sid>.<DOMAIN>` | `<sid>` = `SecureRandom.hex(16)`（128 ビット、小文字 16 進 32 文字） |
| プレビュー | `3000-<pid>.<DOMAIN>` | `<pid>` = 別の `SecureRandom.hex(16)` |

- **一段だけの平らな名前**: Cloudflare Free の Universal SSL が覆うのは apex と一段目だけ [文書]。
  脅威モデルの `*.edit.<DOMAIN>` / `*.view.<DOMAIN>` は使えない。オーナーの決定どおり。
- **エディタとプレビューで別々の乱数**（調査の案からの変更）: 調査の案（`<sid>` と `3000-<sid>`）では、
  訪問者が「自分のアプリを見て」とプレビューの URL を人に渡すと、先頭の `3000-` を外すだけでエディタ
  （= シェル）の URL になる。別々の 128 ビットにすれば、プレビューの URL はアプリだけを渡す。費用は
  乱数 1 つとネットワークの別名 1 つ。
- 登録可能ドメインは Public Suffix List に載っていてはいけない（載っているとエディタとプレビューが別サイトに
  なり、Lax の Cookie が落ちる [計測]）。オーナーが買うドメインで確かめる（§11.2 の Q1）。
- `www.<DOMAIN>` は作らない。来れば 404 のページ（入口へのリンク付き）。
- 内部の名前: ハンドル `<h>` = `SHA-256(<sid>)` の先頭 16 桁。コンテナ `ctplay-s-<h>`、ネットワーク
  `ctplay-n-<h>`、ラベル `cybertrain-play.handle=<h>`。ルーターが引く名前はコンテナのネットワーク別名
  `s-<sid>` と `p-<pid>` で、`docker ps` の出力やイベントには現れない（`docker inspect` には出る）。
  ログと運用の手順はハンドルだけを使う（§5.11）。
- 別名に接頭辞 `s-` / `p-` を付ける理由: 32 桁がすべて数字になる確率は小さいが 0 ではなく、数字だけの
  名前の扱いに頼らないため。

### 3.4 リクエストの経路

**エディタ（HTTP）**: ブラウザ → Cloudflare（TLS 1 回目、ワイルドカードの Universal SSL）→ VPS:443 →
kamal-proxy（TLS 2 回目、Origin CA 証明書。`*.<DOMAIN>` はサービス `cybertrain-play-router` へ。Host はそのまま [ソース]）
→ ルーター :80（`kamal` ネットワーク）→ Caddy の `@editor`（Host が `<32 桁>.<DOMAIN>`）→ Docker の内蔵 DNS で
`s-<sid>` を引き（ルーターがつながっているセッションのネットワークの上でだけ解決できる）→ code-server :8080。

**エディタの WebSocket**: 同じ経路で `Upgrade` が通る。Cloudflare は全プランで WebSocket を通す [文書]。
kamal-proxy はアップグレードした接続にアイドル・書き込みのタイムアウトを掛けない [ソース]。Caddy は
WebSocket を自動で通す [文書]。code-server は `Origin` のホストを `X-Forwarded-Host`（無ければ `Host`）と比べる
[計測]。Caddy は元の Host を保ち、`X-Forwarded-Host` に元の Host を入れるので一致する。`--trusted-origins` は
設定しない（M7）。

**プレビュー**: エディタの Simple Browser の iframe → `https://3000-<pid>.<DOMAIN>/` → 同じ経路 → Caddy の
`@preview` → `p-<pid>:3000` → `cybertrain server`（コンテナ内で `0.0.0.0:3000` で待つ）。code-server は
経路に入らない（§3.5 (b)）。

**入口と作成**: `https://<DOMAIN>/` → … → Caddy の `@apex` → `ctplay-control:9292`（`kamal` ネットワークの別名）→ Sinatra。

**準備確認（制御面から）**: 制御面 → `http://ctplay-router/healthz`、`Host: <sid>.<DOMAIN>` → Caddy の `@editor` →
そのセッションの code-server の `/healthz`。制御面はセッションのネットワークに一切つながらない。
この確認が通れば、ルーターの接続、DNS、code-server の 3 つが揃っている。

### 3.5 選択肢と決定

**(a) 誰がホスト名をセッションへ振り分けるか**

| 案 | 長所 | 短所 |
| --- | --- | --- |
| **A1 素の Caddy と静的な Caddyfile**（採用） | 設定の書き換えも再読み込みもない（Caddy の再読み込みは WebSocket を切る [文書]）。WebSocket は組み込み。Docker のソケットが要らない。存在しないセッションは DNS で失敗して 404 のページになり、M8 が自然に満たされる | ルーターを各セッションのネットワークにつなぐ手間（制御面が行う）。ルーターの入れ替えの直後、新しいルーターがつながるまで数秒届かない（§7.8） |
| A2 制御面が自分でプロキシ | 終了したセッションに凝ったページを出せる | WebSocket を Rack の hijack で書く必要がある。ソケットを持つ一番大事なプロセスが訪問者の全通信を解釈する。制御面を出すたびに全エディタの接続が切れる |
| A3 Traefik と Docker のラベル | 経路がコンテナと一緒に現れて消える | Traefik にも Docker のソケットが要る（M9 と脅威モデルの資産 2 に反する）。ネットワークの接続は結局必要 |

（kamal-proxy 自身に動的にサービスを足す案は、Kamal の管理するコンテナを外から操作し、共有のプロキシを
セッションのネットワークに入れることになるので調査の段階で外れている。）

**(b) プレビューがアプリに届く道**

| 案 | 長所 | 短所 |
| --- | --- | --- |
| B1 code-server のドメインプロキシ経由（`--proxy-domain`、アプリは 127.0.0.1） | アプリの待ち受けアドレスを変えない | code-server が全プレビューの経路に入る。プロキシを有効にすると `/proxy/<port>/` がコンテナ内の全ポートに届く [計測] |
| **B2 ルーターから直接 :3000**（採用） | 経路が短い。code-server が落ちてもプレビューは動く。`--disable-proxy` で code-server のプロキシを閉じられる [計測] | アプリが `0.0.0.0` で待つ必要がある → web ステージで `CYBERTRAIN_HOST=0.0.0.0`。届くのはルーターだけ（専用ネットワーク） |

B2 では `VSCODE_PROXY_URI=https://{{port}}-<pid>.<DOMAIN>` を制御面がコンテナに渡す。`asExternalUri` と
openPreview はこの値から URL を作る [計測、`--proxy-domain` と併用した状態で]。`--proxy-domain` なし・
`--disable-proxy` ありで同じように動くかは [未検証]（V1）。動かなければ `--disable-proxy` を外して
`--proxy-domain '{{port}}-<pid>.<DOMAIN>'` を足す（ルーターはプレビューを 8080 に送らないので、code-server の
ドメインプロキシは誰にも届かない。`/proxy/<port>/` はエディタの URL を持つ人、つまりシェルを持つ人にしか
届かないので、守るべき境界は増えない）。

**(c) 制御面の言語と形**

| 案 | 長所 | 短所 |
| --- | --- | --- |
| **C1 Ruby + Sinatra + Puma、1 プロセス**（採用） | オーナーの手に馴染む（spinel scope と同じ）。CLI を argv の配列で呼ぶ型も、レート制限も、minitest と偽物のランナーでの試験も先例がある | Go ほど軽くない（どうでもよい規模） |
| C2 Go の単一バイナリ | 速い。プロキシも書ける | 新しい言語を 1 人で保守することになる |
| C3 cybertrain 自身で書く | 自分の食べ物を食べる | Spinel のサブセットでの子プロセス、スレッド、HTTP クライアントの扱いが未知数 |

**(d) 制御面の Docker へのアクセス**

| 案 | 守れること | 費用 |
| --- | --- | --- |
| **D1 ソケットを制御面にマウント**（採用、SP2 の間） | M9（セッションには渡さない、argv の配列、訪問者の入力を使わない）を満たす | 制御面の RCE がそのままホストの root になる |
| D2 docker-socket-proxy の許可リスト | `exec`、ビルドなどを止められる | 許可は API の区画単位で、本文を見ない。コンテナの作成を許す以上、`--privileged` や `-v /:/host` の作成も許すので、肝心の場面で守れない（[ソース] tecnativa の README の仕組み） |
| D3 ソケットを持つ最小のオーケストレーターを分離（S1） | Web 層の RCE でもできるのは決まった型のセッションの作成と削除だけ | プロセス 1 つ、内部 API、二重の設定と試験 |

採用の理由: SP2 の Web の表面はとても小さい（読むのは `CF-Connecting-IP`、`Origin`、`Sec-Fetch-Site` の 3 つの
ヘッダだけで、フォームの中身は使わない）。spinel scope はもっと大きな表面（1 MB の C ソースを受け取る）で D1 を
採っている。同じホストの最大の危険は Web 層ではなく、コンパイラ付きのシェルからのカーネル脱出（R2）で、
そちらはソケットの置き場所に関係なくホストの root になる。D3 の価値が大きくなるのは、GitHub ログインと
利用者の入力を持つ SP3 の Web 層が来たとき。そこで、Docker を触るコードを 1 つの狭いインターフェース
（`Play::Sessions#create / #teardown / #reconcile`、テンプレートは `Play::Templates`）に閉じ込め、SP3 の前に
別プロセスへ移す（§13 の 1）。（本 spec での決定。オーナーへの質問 §11.2 の Q6）

**(e) ネットワークの形**

| 案 | 判定 |
| --- | --- |
| **E1 セッションごとの `--internal` ネットワーク + ルーターを接続**（採用） | 隣のセッションが同じネットワークにいない。明示した /28 でアドレスプールの 31 個の上限を避ける |
| E2 共有の内部ネットワーク + `enable_icc=false` | ICC はブリッジ全体に効き、ルーターからセッションへの通信も止まる [推論]。ルーターをホストのネットワークに置き IP の表を持つことになる |
| E3 共有の内部ネットワーク（ICC あり） | セッション同士が直接届き、`--auth none` の code-server を走査で乗っ取れる。不可 |

**(f) エッジと TLS**: オーナーの決定（Cloudflare Free + Origin CA + kamal-proxy）どおり。Cloudflare Tunnel なら
受信ポートも証明書も要らないが、決定と違い、ワイルドカードの扱いも [未検証] なので採らない。

**(g) 実行環境**: 初日は硬化した runc。`PLAY_RUNTIME` が空でなければ `--runtime <値>` を付ける（`runsc`）。
VPS で計測して決める（§7.12）。

### 3.6 脅威モデル §3 との対応

| 項目 | 本書での扱い |
| --- | --- |
| M1 決まった `docker run` | §5.4 の argv。訪問者の入力は 1 つも入らない。単体テストが argv 全体を固定する。メモリは 512m ではなく 1536m（再ビルド + エディタで 1 GiB の上限まで 8 % の余裕しかないため、§5.4） |
| M2 絶対の TTL と刈り取り | 制御面が `expires-at` で消す（5 秒ごと）。加えてコンテナ自身が `timeout` で終了時刻 + 60 秒に止まり、`--rm` で消える（制御面が落ちていても残らない）。早めの回収に `--idle-timeout-seconds 300` |
| M3 外への通信なし、セッションごとの内部ネットワーク | §3.5 (e)。イメージは焼き切り（SP1 のミラーとビルド済みのブログ、§4.3 の種）。外の名前が引けないことも E2E で確かめる。ホストのファイアウォールで二重に（§7.5） |
| M4 全体と IP ごとの上限 | 全体 `PLAY_MAX_SESSIONS`、IP ごとの同時数（IPv6 は /64 単位）、IP ごとの作成回数。§5.6 |
| M5 専用の登録可能ドメイン | オーナーが買う。平らな一段の名前（§3.3） |
| M6 128 ビットの能力 URL、`no-referrer`、`noindex` | §3.3、§6.3。ログに sid を出さない（§5.11） |
| M7 code-server のフラグ | `--auth none`、Origin の検査はそのまま（`--trusted-origins` なし）、テレメトリと更新確認なし、拡張のギャラリーを空に（§4.1、§4.2）。`--cookie-suffix` は使わない: `--auth none` では code-server が認証 Cookie を出さず、Cookie はセッションごとのホストにしか付かないので衝突しない |
| M8 生きているセッションのホスト名だけを通す | ルーターはホスト名の形と Docker の DNS での存在で判断し、それ以外は 404。セッションからルーターへの接続は切る（§6.1） |
| M9 ソケットは制御面だけ、argv の配列 | §3.5 (d)、§5.4 |
| M10 停止スイッチと監視 | `paused` フラグ、`playctl kill-all`、生の Docker コマンドの予備、`/status.json`、CPU を使い続けるセッションの記録（§5.9、§7.10） |
| S1 オーケストレーターの分離 | SP3 の前に行う（§13 の 1）。SP2 では継ぎ目だけ |
| S2 ソケットプロキシ | 採らない（§3.5 (d) の D2） |
| S3 gVisor | 設定値として用意し、VPS で計測（§7.12） |
| S4 rootless Docker | 先送り。セッションを別のデーモンに置くとルーターが同じネットワークに入れず、本書の経路が成り立たない。Kamal も root のデーモンを前提にしている |
| S5 セキュリティヘッダ | §6.3（frame-ancestors、`nosniff`、入口の CSP。HSTS は公開確認の後に Cloudflare で） |
| S6 利用条件、`security.txt`、窓口 | §5.13、§9.5 |
| S7 userns-remap | 先送り。デーモン全体の設定で、制御面のソケットのマウントが `--userns=host` なしでは使えなくなる。セッションは既に uid 1000 + `no-new-privileges` + 全ケーパビリティなし |

## 4. イメージの web ステージ

### 4.1 `playground/Dockerfile` への追加（全文、ファイルの最後に足す）

```dockerfile
# ---------------------------------------------------------------------------
# The hosted playground's session image (SP2): the playground stage plus
# code-server. Only the control plane runs it (playground/control): a
# read-only root file system, empty tmpfs mounts on /tmp, /home/dev,
# /workspace and /opt/cybertrain-cache, and no network but its own internal
# one. Nothing here changes the playground stage, which Codespaces runs.
#
#   docker build -f playground/Dockerfile --target web -t cybertrain-playground-web:local .
FROM playground AS web

ARG TARGETARCH
ARG CODE_SERVER_VERSION=4.139.1
# sha256 of code-server-<version>-linux-<arch>.tar.gz on the GitHub release.
ARG CODE_SERVER_SHA256_AMD64=<filled in by the plan's first task>
ARG CODE_SERVER_SHA256_ARM64=<filled in by the plan's first task>

USER root
RUN set -eu; \
    case "$TARGETARCH" in \
      amd64) sum="$CODE_SERVER_SHA256_AMD64" ;; \
      arm64) sum="$CODE_SERVER_SHA256_ARM64" ;; \
      *) echo "playground/Dockerfile: no code-server for $TARGETARCH" >&2; exit 1 ;; \
    esac; \
    tarball="code-server-${CODE_SERVER_VERSION}-linux-${TARGETARCH}.tar.gz"; \
    curl -fsSL -o "/tmp/$tarball" \
        "https://github.com/coder/code-server/releases/download/v${CODE_SERVER_VERSION}/$tarball"; \
    echo "$sum  /tmp/$tarball" | sha256sum -c -; \
    mkdir /usr/lib/code-server; \
    tar -xzf "/tmp/$tarball" -C /usr/lib/code-server --strip-components 1 --no-same-owner; \
    rm "/tmp/$tarball"; \
    ln -s /usr/lib/code-server/bin/code-server /usr/local/bin/code-server; \
    test "$(HOME=/tmp/cs-home code-server --version | head -n 1 | cut -d ' ' -f 1)" = "$CODE_SERVER_VERSION"; \
    rm -rf /tmp/cs-home

# code-server's user settings (the entrypoint copies them into the session's
# home) and the session's entrypoint.
COPY playground/web/settings.json /opt/cybertrain-web/settings.json
COPY --chmod=0755 playground/web/playground-web /usr/local/bin/playground-web
# The router reaches the dev server at the session's own address, so the app
# listens on every interface (only the router shares the session's network).
# An empty gallery: an install could not download anything here (no network),
# and the visitor's browser then contacts no extension marketplace.
ENV CYBERTRAIN_HOST=0.0.0.0 \
    EXTENSIONS_GALLERY={}

USER dev
WORKDIR /workspace/blog
# The folderOpen task that starts the server in a visible terminal. It is the
# playground's, not the visitor's, so Source Control does not show it.
COPY --chown=dev:dev playground/web/tasks.json .vscode/tasks.json
# This environment's guide replaces the Codespaces one inside the one commit.
COPY --chown=dev:dev playground/web/PLAYGROUND.md PLAYGROUND.md
RUN echo '/.vscode/' >> .git/info/exclude \
 && git add PLAYGROUND.md \
 && git -c user.name="cybertrain playground" -c user.email="playground@cybertrain.invalid" \
        commit -q --amend --no-edit \
 && test -z "$(git status --porcelain)" \
 && test "$(git rev-list --count HEAD)" = 1

# What the entrypoint copies into the empty tmpfs mounts. cp -a keeps file
# times, so the copy is as fresh as the build (spin compares mtimes).
USER root
RUN mkdir -p /opt/cybertrain-web/seed \
 && cp -a /workspace /opt/cybertrain-web/seed/workspace \
 && cp -a /opt/cybertrain-cache /opt/cybertrain-web/seed/cybertrain-cache

USER dev
WORKDIR /workspace/blog
EXPOSE 8080 3000
ENTRYPOINT ["/usr/local/bin/playground-web"]
CMD []
```

- 配布物の取り方（本 spec での決定）: GitHub のリリースの tar.gz を SHA-256 で検証して `/usr/lib/code-server` に
  展開する。deb は依存の解決に apt が要り、インストールスクリプトはパイプでシェルに流すことになる。公式イメージ
  からの `COPY --from` もダイジェストの固定が要る点で同じ手間なので、取得物が目に見える tar.gz にした。
  2 つのチェックサムは plan の最初のタスクがリリースから取って埋める（今は空欄）。
- `--version` を `HOME=/tmp/cs-home` で走らせて消すのは、code-server が root のホームに設定ファイルを作って
  レイヤーに残すのを避けるため（作るかどうかは [未検証]。作らなくても害はない）。
- `EXTENSIONS_GALLERY={}`: code-server は既定で Open VSX をギャラリーにしている（スパイクのブラウザが
  `open-vsx.org` に問い合わせた [計測]。脅威モデル E4 の「マーケットプレイスなし」はこの点で誤り）。空の
  オブジェクトでギャラリーが消えるかは [未検証]（V10）。消えなければこの行を外す（外への通信がないので
  インストールはどのみち失敗する [推論]。ブラウザが Open VSX に問い合わせることを利用条件に書く）。
- 種（seed）の 2 つの写しは約 7 MB（ブログ 4.1 MB、spin のキャッシュ 2.9 MB [計測]）。
- `playground` ステージ、`smoke.sh`、Codespaces には何も影響しない: 新しいファイルはすべて `web` ステージで
  入り、置き場所は `/opt/cybertrain-web/` と `/usr/lib/code-server/` とブログの `.vscode/`（web のイメージにだけ
  ある）。SP1 のイメージの `PLAYGROUND.md` も元のまま。
- ビルドコンテキストは SP1 の `playground/Dockerfile.dockerignore`（`!playground/` を含む）のままで足りる。

### 4.2 code-server の固定と起動フラグ

版は 4.139.1（2026-09-26 リリース、Code 1.139.1）に固定する。スパイクがブラウザで確かめた版で、上げるときは
チェックサム 2 つを替え、§8.3 のスモークと §8.5 の実ブラウザの確認表をやり直す（設定の効く範囲が版で変わり
うるため）。

| フラグ | 理由 |
| --- | --- |
| `--bind-addr 0.0.0.0:8080` | ルーターがセッションのアドレスで届くように |
| `--auth none` | ログインなしが製品の形。URL が能力（R1） |
| `--disable-telemetry`、`--disable-update-check` | 外へ出ない。更新の確認先を消す [計測] |
| `--disable-workspace-trust` | 「Restricted Mode」の表示と確認を消す [計測] |
| `--disable-getting-started-override` | Coder の宣伝カードを消す [計測] |
| `--disable-proxy` | §3.5 (b)。`/proxy/<port>/` が 403 になる [計測] |
| `--disable-file-uploads` | 持ち込みを減らす（プレビューのホストからフィッシングキットを配る手間を増やす）。ダウンロードは残す: 作業を持ち帰る唯一の道（本 spec での決定） |
| `--idle-timeout-seconds "$PLAYGROUND_IDLE_TIMEOUT"`（既定 300） | タブを閉じた枠を早く空ける。60 より大きい必要がある [計測] |
| 位置引数 `/workspace/blog` | 既定のフォルダ |

使わないもの: `--trusted-origins`（M7）、`--proxy-domain`（V1 が通れば）、`--cookie-suffix`（§3.6 M7）、
`--disable-file-downloads`（上）、`--app-name`（版での有無を確かめていない。見た目だけなので入れない）。

### 4.3 ファイルと置き場所

| リポジトリ | イメージ内 | 何 |
| --- | --- | --- |
| `playground/web/playground-web` | `/usr/local/bin/playground-web` | セッションのエントリポイント（§4.6） |
| `playground/web/settings.json` | `/opt/cybertrain-web/settings.json` → 起動時に `~/.local/share/code-server/User/settings.json` | ユーザー設定（§4.4） |
| `playground/web/tasks.json` | `/workspace/blog/.vscode/tasks.json`（`.git/info/exclude` で隠す） | 開発サーバーを端末で起動するタスク（§4.5） |
| `playground/web/PLAYGROUND.md` | `/workspace/blog/PLAYGROUND.md`（1 つのコミットに畳み込む） | SP2 のガイド（§4.8） |
| （ビルド時に作る） | `/opt/cybertrain-web/seed/{workspace,cybertrain-cache}` | tmpfs に写す元 |

- タスクだけはブログの `.vscode/` に置く（自動タスクはフォルダのタスクとして測ったもの [計測]。ユーザーの
  タスクで `folderOpen` が効くかは確かめていない）。ポートの設定（`remote.portsAttributes` などウィンドウの
  範囲の設定）はユーザー設定に置く（本 spec での決定）: ウィンドウの範囲の設定はユーザー設定からも効く
  [文書: VS Code の設定の範囲]。スパイクはワークスペースの設定で測っているので [未検証]（V9）。駄目なら
  `.vscode/settings.json` に移す（同じく exclude で隠れる）。
- アプリケーションの範囲の設定（`task.allowAutomaticTasks` など）はユーザー設定にしか置けない [計測]。

### 4.4 `playground/web/settings.json`（全文）

> §16.2 が優先: 実装では `workbench.editorAssociations` の 2 行を外し（ガイドはテキスト表示。整形表示だとプレビューが上に重なる）、`"window.restoreWindows": "preserve"` を足した（再読み込みでプレビューが戻るため）。

```jsonc
// code-server's User settings in the hosted playground (playground-web
// copies this file into the session's home). Lines marked "checked" were
// measured on code-server 4.139.1 / Code 1.139.1 in the VS Code web spike.
{
  // No first-run noise (checked).
  "workbench.startupEditor": "none",
  "workbench.secondarySideBar.defaultVisibility": "hidden",
  "workbench.welcomePage.walkthroughs.openOnInstall": false,
  "workbench.tips.enabled": false,
  "workbench.enableExperiments": false,
  "telemetry.telemetryLevel": "off",
  "update.mode": "none",
  "update.showReleaseNotes": false,
  "extensions.autoUpdate": false,
  "extensions.autoCheckUpdates": false,
  "extensions.ignoreRecommendations": true,
  "chat.disableAIFeatures": true,
  // .vscode/tasks.json starts the dev server when the folder opens. This is
  // application-scoped: a workspace file cannot set it (checked).
  "task.allowAutomaticTasks": "on",
  // Port 3000 opens in the editor's preview; other ports are not offered,
  // since only 3000 is routed (checked from a workspace file; from here: V9).
  "remote.portsAttributes": {
    "3000": { "label": "cybertrain", "onAutoForward": "openPreview" }
  },
  "remote.otherPortsAttributes": { "onAutoForward": "ignore" },
  // A Ruby save is a ~1 minute rebuild: save on purpose (as in Codespaces).
  "files.autoSave": "off",
  // ERB views highlight as HTML with the built-in grammar (no extension).
  "files.associations": { "*.html.erb": "html" },
  // The guide opens rendered (V9).
  "workbench.editorAssociations": { "**/PLAYGROUND.md": "vscode.markdown.preview.editor" },
  "editor.minimap.enabled": false,
  "terminal.integrated.confirmOnKill": "never",
  "terminal.integrated.showExitAlert": false,
  "terminal.integrated.gpuAcceleration": "off",
  // Closing the tab loses nothing (the session runs on), so no "Leave site?".
  "window.confirmBeforeClose": "never"
}
```

- スパイクの設定から外したもの: `security.workspace.trust.enabled`（フラグと二重）、`files.autoSave: afterDelay`
  （SP1 の devcontainer と同じく `off`。自動保存は Ruby を打つたびに再ビルドを起こす [ソース]、コンテナスパイク §4）、
  `breadcrumbs.enabled`（好みの問題）。
- ERB の拡張（`vortizhe.simple-ruby-erb`）は入れない（本 spec での決定）: 第三者のダウンロードとライセンスの
  扱いが増える一方、ビューの大半は HTML で、組み込みの HTML 文法なら Emmet と HTML の補完も効く。
  `<% %>` の中の Ruby に色が付かないのは受け入れる。

### 4.5 `playground/web/tasks.json`（全文）

```jsonc
// The hosted playground's dev server: started when the folder opens, in a
// terminal the visitor sees (the Codespaces image uses postAttachCommand
// instead). instancePolicy "silent": a page reload re-attaches the terminal
// and starts nothing (checked in the VS Code web spike).
{
  "version": "2.0.0",
  "tasks": [
    {
      "label": "cybertrain server",
      "type": "shell",
      "command": "playground-server",
      "isBackground": true,
      "problemMatcher": [],
      "presentation": {
        "reveal": "always",
        "panel": "dedicated",
        "focus": false,
        "clear": true,
        "showReuseMessage": false
      },
      "runOptions": {
        "runOn": "folderOpen",
        "instanceLimit": 1,
        "instancePolicy": "silent"
      }
    }
  ]
}
```

起動の仕方の選択（本 spec での決定）: タスクが `playground-server` を直接起動する（スパイクの「tasks」型 [計測]）。
エントリポイントが tmux でサーバーを持ち、タスクが tmux に接続する型（スパイクの hybrid3 [計測]）も動くが、
tmux の追加、`remote.autoForwardPortsSource: "output"` の細工、再起動ループが要り、そのループは
「ブログのサーバーを止めて新しいアプリを 3000 で起動する」というガイドの流れとぶつかる（Ctrl-C しても 1 秒後に
ブログが戻る）。タスク型の既知の限界は SP1 と同じ: 端末をゴミ箱のアイコンで閉じると、開発ループは SIGHUP を
再起動と扱うので、端末のないサーバーがポートとロックを持ち続ける（プレビューは動き続け、タスクを再び走らせると
`already running` と出る）。

### 4.6 エントリポイント `playground/web/playground-web`（全文）

```bash
#!/usr/bin/env bash
# playground-web -- the entrypoint of the hosted playground's session image
# (playground/Dockerfile, stage web).
#
# The control plane (playground/control) runs the image with a read-only root
# file system and empty tmpfs mounts on /workspace, /opt/cybertrain-cache,
# /home/dev and /tmp, and sets
#   VSCODE_PROXY_URI         https://{{port}}-<preview id>.<domain>: where the
#                            editor's preview and Ports view open a port
#   PLAYGROUND_ENDS_AT       the session's end, in seconds since the epoch
#   PLAYGROUND_IDLE_TIMEOUT  seconds without a browser before code-server
#                            exits (more than 60; default 300)
# This script fills the tmpfs mounts from the image's seed, installs
# code-server's user settings, schedules two notices in the terminals and
# execs code-server, bounded by the session's end: the container stops (and
# --rm removes it) even when the control plane is not there to do it.
#
# By hand, for a look without the rest of the service (no time limit):
#   docker run --rm -it --init -p 127.0.0.1:8080:8080 -p 127.0.0.1:3000:3000 \
#     -e 'VSCODE_PROXY_URI=http://localhost:{{port}}' cybertrain-playground-web:local
# then open http://localhost:8080/?folder=/workspace/blog
set -eu

seed=/opt/cybertrain-web/seed
ends_at=${PLAYGROUND_ENDS_AT:-}
idle=${PLAYGROUND_IDLE_TIMEOUT:-300}
case "$ends_at" in *[!0-9]*) echo "playground-web: PLAYGROUND_ENDS_AT is not a number" >&2; exit 2 ;; esac
case "$idle" in ''|*[!0-9]*) echo "playground-web: PLAYGROUND_IDLE_TIMEOUT is not a number" >&2; exit 2 ;; esac

# 1. The writable state. Empty tmpfs mounts get the image's copy (cp -a keeps
#    the times spin compares, so nothing rebuilds); a run without them finds
#    the image's own directories in place and copies nothing.
if [ -z "$(ls -A /workspace)" ]; then cp -a "$seed/workspace/." /workspace/; fi
if [ -z "$(ls -A /opt/cybertrain-cache)" ]; then cp -a "$seed/cybertrain-cache/." /opt/cybertrain-cache/; fi
if [ -z "$(ls -A "$HOME")" ]; then cp -a /etc/skel/. "$HOME/"; fi

# 2. code-server's user settings: task.allowAutomaticTasks and the other
#    application-scoped settings take effect only from here.
user_dir="$HOME/.local/share/code-server/User"
mkdir -p "$user_dir"
[ -e "$user_dir/settings.json" ] || cp /opt/cybertrain-web/settings.json "$user_dir/settings.json"

# 3. A notice in every open terminal 5 minutes and 1 minute before the end.
#    Writing to a terminal's device prints on its screen; it is not input.
#    Double fork: tini (--init) reaps the notifier, not code-server's timeout.
notice() {
  local tty
  for tty in /dev/pts/[0-9]*; do
    [ -w "$tty" ] && printf '\r\n\033[1;33m[playground] %s\033[0m\r\n' "$1" > "$tty" 2>/dev/null || true
  done
}
notice_at() { # SECONDS_BEFORE_THE_END MESSAGE
  local wait=$(( ends_at - $1 - $(date +%s) ))
  if [ "$wait" -gt 0 ]; then sleep "$wait"; notice "$2"; fi
}
if [ -n "$ends_at" ]; then
  ( ( notice_at 300 "This session ends in 5 minutes: it is deleted with its files. Download what you want to keep."
      notice_at 60 "This session ends in 1 minute." ) & )
fi

# 4. code-server. The router sends the preview straight to port 3000, so
#    code-server's own port proxy stays off.
args=(--bind-addr 0.0.0.0:8080 --auth none
      --disable-telemetry --disable-update-check --disable-workspace-trust
      --disable-getting-started-override --disable-proxy --disable-file-uploads
      --idle-timeout-seconds "$idle"
      /workspace/blog)
if [ -n "$ends_at" ]; then
  left=$(( ends_at + 60 - $(date +%s) ))
  [ "$left" -gt 0 ] || exit 0
  exec timeout --kill-after=10 "$left" code-server "${args[@]}"
fi
exec code-server "${args[@]}"
```

- セッション ID と ドメインの渡し方: 制御面が `VSCODE_PROXY_URI` を完成した形で渡す（エントリポイントは
  組み立てない）。エディタの sid はコンテナに渡さない（code-server は自分のホスト名を知る必要がない。`payload`
  の URL は制御面が作る）。プレビューの pid は `VSCODE_PROXY_URI` に入るので訪問者のシェルから見えるが、
  訪問者自身のものなので問題ない。
- 読み取り専用のルートで動くための写し: `/workspace`（ブログと、隣に作る新しいアプリ）、`/opt/cybertrain-cache`
  （`cybertrain new` と再ビルドが書く、SP1 §4.6）、ホーム（code-server のデータ、`/etc/skel` の写し）。
  `/tmp` は空のまま（spin の一時ファイル、ロック、IPC のソケット）。`/opt/cybertrain`（Spinel）は読むだけで
  足りるはず [推論: SP1 §4.6 の「実行時に書く場所」に無い]。§8.3 の W8、W9 で確かめる（V5）。
- 終了時刻 + 60 秒の猶予: 制御面の刈り取り（5 秒ごと）が先に動くのが普通で、`timeout` は制御面がいないときの
  安全網。`timeout` が code-server を止めると tini（PID 1）が終わり、コンテナが止まり、`--rm` が消す。
  残るのは空の内部ネットワークだけで、制御面の起動時の照合が消す（§5.8）。
- サーバーの起動とプレビューのきっかけ: エントリポイントはサーバーを起動しない。ブラウザがフォルダを開いた
  ときにタスクが起動する（§4.5）。そのためブラウザが来ないセッションでは開発サーバーは動かず、アイドル終了で
  消える。

### 4.7 `playground/playground-server` の変更（差分の形）

SP1 の起動スクリプトに 2 つ足す。どちらも環境変数があるときだけ効き、Codespaces とローカルの Docker の
振る舞い（SP1 のスモークの C2 など）は変わらない。

1. アプリの URL: Codespaces の分岐の次に、`VSCODE_PROXY_URI` が `{{port}}` を含めばそれを使う。

   ```bash
   if [ "${CODESPACES:-}" = "true" ] && [ -n "${CODESPACE_NAME:-}" ]; then
     url="https://${CODESPACE_NAME}-${port}.${GITHUB_CODESPACES_PORT_FORWARDING_DOMAIN:-app.github.dev}/"
   elif [[ -n "${VSCODE_PROXY_URI:-}" && "${VSCODE_PROXY_URI}" == *'{{port}}'* ]]; then
     # code-server (the hosted playground): its address for a port.
     url="${VSCODE_PROXY_URI//'{{port}}'/$port}"
     url="${url%/}/"
   else
     url="http://localhost:${port}/"
   fi
   ```
2. バナーの行: `PLAYGROUND_ENDS_AT` が数字なら、`Guide` の行の後に
   `  Ends   in 29 minutes (14:32 UTC): the session and its files are deleted then.` を出す
   （分は切り捨て、時刻は `date -u -d @<秒> +%H:%M`）。数字でなければ出さない。

SP2 でのバナーの例:

```

  cybertrain playground
  App    https://3000-0f3c…9a.<DOMAIN>/
  Guide  /workspace/blog/PLAYGROUND.md
  Ends   in 29 minutes (14:32 UTC): the session and its files are deleted then.

  Views reload on the next request. A Ruby change rebuilds the app (about a
  minute), then the server restarts by itself. Reload the page to see either.
  Ctrl-C stops the server; run playground-server to start it again.

```

`code` コマンドでガイドを開く処理は SP1 のまま（code-server の端末に `code` があるかは [未検証]。無ければ何も
しない。ガイドは `payload` で開く）。

### 4.8 ガイド `playground/web/PLAYGROUND.md`（全文、web のイメージの `/workspace/blog/PLAYGROUND.md`）

SP1 のガイドと共通の部分（Try this、Start a fresh app）は一字一句同じにする。片方を直したらもう片方も直す
（playground/README.md に書く）。数字（30 分、5 分）は書かない: 設定で変わるので、端末の表示に任せる。

````markdown
# cybertrain playground

This is the blog from the cybertrain tutorial, already set up: `cybertrain new blog`,
the article scaffold, the root route and the first migration (tutorial steps 02, 03,
04 and 07). The development server runs in the terminal below and the preview shows
the app.

This session ends at the time the terminal shows, and everything in it is deleted
then. To keep a file or a folder, right-click it in the Explorer and choose Download.

The preview does not reload by itself: after a change, press its reload button.

## Try this

1. **Edit a view.** Change the `<h1>` in `app/views/articles/index.html.erb`, save,
   reload the preview. Views are read from disk on every request, so there is
   nothing to build.
2. **Add a validation.** In `app/models/article.rb`, add this line inside the class
   and save:

   ```ruby
   validates :body, presence: true, length: { minimum: 10 }
   ```

   Ruby is compiled, so the terminal shows a rebuild. After about a minute the
   server restarts by itself: an article with a short body now fails with "Body is
   too short (minimum is 10 characters)". If a change does not compile, the previous
   build keeps serving and every page shows the compiler's message at the top.
3. **Carry on with the tutorial** from step 08, "Scaffold comments":
   https://saeki-mototsune.github.io/CyberTrain/tutorial.html#scaffold-comment
   Stop the server first (Ctrl-C in its terminal), run the step's commands in a new
   terminal, then start it again with `cybertrain server`.

The Source Control view shows what you changed: the app is a git repository with
one commit.

## Start a fresh app

```sh
cd ..
cybertrain new shop && cd shop
cybertrain g scaffold product name:string
cybertrain db migrate
cybertrain server
```

Stop the blog's server first: both use port 3000. `cybertrain new` needs no network
here, and the first `cybertrain server` of a new app compiles it (about a minute).
The new app has no root route, so `/` shows "Not Found": its pages start at
`/products`.

## Good to know

- The Ports view's "Open in Browser" on port 3000 shows the app in a normal tab.
  Inside the preview, pop-ups and `confirm()` dialogs do not work.
- The session has no network: `gem install`, `curl` to the internet and `git push`
  do not work. Only port 3000 can be previewed.
- Anyone with this page's address can use this session, terminal included: do not
  share it. The preview's address shows only the app.
- Closing the tab ends the session a few minutes later.
- Everything else is in the README: https://github.com/saeki-mototsune/cybertrain#readme
````

### 4.9 イメージが期待する `docker run`

本番の形は制御面のテンプレート（§5.4）だけが持つ。イメージの側の約束:

| 期待 | 理由 |
| --- | --- |
| `--init` | tini が PID 1 で子を刈り、`timeout` の終了でコンテナを止める |
| `--user 1000:1000` | SP1 の `dev`。tmpfs の所有者もこれに合わせる |
| `--read-only` + 4 つの tmpfs（`/tmp`、`/home/dev`、`/workspace`、`/opt/cybertrain-cache`） | §4.6 の 1。tmpfs が空なら種を写す |
| `-e VSCODE_PROXY_URI=…`（必須） | プレビューの URL。無いと Simple Browser が訪問者自身の localhost を開く [計測、input-hack の行] |
| `-e PLAYGROUND_ENDS_AT=…`（任意） | 無ければ時間制限なし（手で動かす形） |
| `-e PLAYGROUND_IDLE_TIMEOUT=…`（任意、既定 300） | 61 以上 |
| ネットワーク: ルーターが届く 1 つ | 8080 と 3000 |

手で動かす最小形（ルーターなし、時間制限なし）は §4.6 の冒頭のコメントのとおり。`http://localhost:8080` の
エディタが `http://localhost:3000` のプレビューを枠に入れる形で、どちらも `localhost` なので同一サイト
（ポートはサイトの判定に入らない [文書: schemeful same-site]）。開発者がイメージだけを試すのに使う。

### 4.10 時間切れのときに訪問者が見るもの

| 時刻 | 起きること | 訪問者に見えるもの |
| --- | --- | --- |
| 0 | 作成、準備確認 | 「Starting…」の後でエディタ |
| 終了の 5 分前 / 1 分前 | エントリポイントの通知 | 端末に黄色の 1 行 |
| 終了時刻（± 5 秒） | 制御面の刈り取りが `docker rm -f` | エディタが「再接続中」→「Cannot reconnect. Please reload the window.」（VS Code の表示 [推論]） |
| 再読み込み | ルーターの DNS が引けず 502 → 404 のページ | "No session at this address"、入口と Codespaces へのリンク |
| 終了時刻 + 60 秒 | （制御面が無いときだけ）`timeout` がコンテナを止める | 同上 |

## 5. 制御面

### 5.1 形

- Ruby（イメージ `ruby:4.0-slim`、spinel scope と同じ系統。パッチ版は実装時に固定）、Sinatra 4.1、Puma 7 の
  シングルモード（スレッド 4〜16）、Docker の CLI（`docker:28-cli` から静的バイナリを写す。先例と同じ）。
  状態はメモリだけで、起動時に Docker のラベルから作り直す。データベース、キュー、アカウントはない。
- 置き場所 `playground/control/`（本 spec での決定）:

| ファイル | 役割 |
| --- | --- |
| `Dockerfile`、`Dockerfile.dockerignore`、`Gemfile`、`Gemfile.lock`、`config.ru` | イメージと起動 |
| `lib/play/config.rb` | 環境変数の読み取りと検証（§5.10） |
| `lib/play/templates.rb` | Docker の argv を作る純粋な関数（§5.4）。訪問者の値を受け取る引数を持たない |
| `lib/play/docker_cli.rb` | `docker` を呼ぶ唯一の場所。`Open3.capture3(*argv)` 相当にタイムアウトと伏せ字（§5.11）を足す |
| `lib/play/subnets.rb` | /28 の割り当て（§5.5） |
| `lib/play/limits.rb` | IP ごとの作成回数の窓、クライアントの鍵（IPv6 は /64） |
| `lib/play/probe.rb` | ルーター経由の準備確認（§5.7） |
| `lib/play/sessions.rb` | 記録、作成、削除、照合、刈り取り、CPU の見張り（§5.3、§5.8） |
| `lib/play/app.rb`、`views/*.erb` | ルートとページ（§5.2、§5.13） |
| `bin/playctl` | 運用のコマンド（§5.9） |
| `test/*_test.rb`、`test/fakes.rb` | 単体テスト（§8.2） |

`playground/control/Dockerfile`（全文）:

```dockerfile
# playground/control/Dockerfile -- the hosted playground's control plane (SP2).
# Kamal builds it (playground/deploy/control.yml); playground/dev/compose.yml
# runs it locally. It talks to the host's Docker through the mounted socket.
FROM ruby:4.0-slim
# build-essential: puma's native extension. The docker CLI is the static
# binary of the official cli image; the daemon is the host's.
RUN apt-get update \
 && apt-get install -y --no-install-recommends build-essential \
 && rm -rf /var/lib/apt/lists/*
COPY --from=docker:28-cli /usr/local/bin/docker /usr/local/bin/docker
ENV RACK_ENV=production BUNDLE_DEPLOYMENT=1 BUNDLE_WITHOUT=test
WORKDIR /app
COPY playground/control/Gemfile playground/control/Gemfile.lock ./
RUN bundle install
COPY playground/control/ ./
EXPOSE 9292
HEALTHCHECK --interval=10s --timeout=3s --start-period=10s \
  CMD ["ruby", "-rnet/http", "-e", "exit(Net::HTTP.get_response(URI('http://127.0.0.1:9292/up')).code == '200' ? 0 : 1)"]
# Single-mode puma: the limits and the session records live in this process.
CMD ["bundle", "exec", "puma", "-p", "9292", "-t", "4:16"]
```

- 1 プロセスに 2 つのスレッド群: Puma のリクエスト、刈り取りのループ（`Thread.abort_on_exception = true`。
  予期しない例外でプロセスごと落ち、Kamal の `--restart unless-stopped` が起こし直し、起動時の照合から続く。
  止まったままの刈り取りより安全）。
- Sinatra の Host の許可: `PLAY_PUBLIC_URL` のホストと `127.0.0.1` / `localhost` だけ（`host_authorization`）。

### 5.2 ルート

| メソッドとパス | 要求 | 応答 |
| --- | --- | --- |
| `GET /` | — | 200 HTML（§5.13 の入口）。空き、制限、ボタン |
| `POST /sessions` | フォームの POST。本文は読まない。`Origin`（あれば `PLAY_ALLOWED_ORIGINS` のどれか）、無ければ `Sec-Fetch-Site` が無いか `same-origin` / `none` | 303 `Location: <エディタの URL>`、`Cache-Control: no-store`。拒否は下の表 |
| `GET /status.json` | — | 200 `{"accepting":true,"paused":false,"live":2,"capacity":5,"ttl_seconds":1800}`、`no-store` |
| `GET /terms` | — | 200 HTML（利用条件、プライバシー、窓口） |
| `GET /robots.txt` | — | `User-agent: *` / `Disallow: /sessions` |
| `GET /.well-known/security.txt` | — | `Contact: mailto:<PLAY_ABUSE_CONTACT>`、`Expires:`（起動から 1 年）、`Policy:`（SECURITY.md） |
| `GET /up` | — | 200 `OK`（刈り取りの最後の成功が 60 秒以内のとき。そうでなければ 503）。コンテナの HEALTHCHECK が使う |
| `GET /internal/sessions` | `REMOTE_ADDR` が 127.0.0.1 のときだけ（ルーターは `/internal/*` を 404 にする） | 200 JSON `[{"handle","created_at","expires_at","client":"<IP か /64>","cpu":…}]`。`playctl status` が使う |

`POST /sessions` の拒否（文面は §5.6）:

| 状況 | 状態コード | 付けるもの |
| --- | --- | --- |
| 他のオリジンからの POST | 403 | 入口へのリンク |
| 停止中（`paused`）、イメージがない、ルーターがいない | 503 | `Retry-After: 300` |
| 満員 | 503 | `Retry-After: 60` |
| 同じアドレスのセッションが生きている | 429 | `Retry-After: <そのセッションの残り秒>` |
| 同じアドレスの作成回数が窓の上限 | 429 | `Retry-After: <窓が空くまでの秒>` |
| 作成の失敗（片付けの後） | 503 | `Retry-After: 60` |

オリジンの検査（本 spec での決定）: 他のサイトのページが訪問者のブラウザから黙ってセッションを作り（`fetch` の
`no-cors` の POST でも作れる）、枠を埋めるのを防ぐ。プレビューのホスト（訪問者が書いたページ）は同一サイトなので、
`same-site` も拒む（`same-origin` だけ通す）。許可するオリジンは入口自身と、サイトの GitHub Pages
（`https://saeki-mototsune.github.io`）: サイトのボタンから 1 回の押下でエディタまで行けるようにするため（§9.1）。

エディタの URL（例、本番）:

```
https://<sid>.<DOMAIN>/?folder=%2Fworkspace%2Fblog&payload=%5B%5B%22openFile%22%2C%22vscode-remote%3A%2F%2F<sid>.<DOMAIN>%2Fworkspace%2Fblog%2FPLAYGROUND.md%22%5D%5D
```

`vscode-remote://` の権限部はエディタの `host:port`（ローカルでは `<sid>.play.localhost:8080`）[計測、非既定ポートで]。
既定のポート（443）でポートを書かない形は [未検証]（V12）。

### 5.3 セッションの記録と状態

```ruby
Session = Struct.new(:handle, :subnet, :created_at, :expires_at, :client, :state)
# state: :creating -> :ready -> :ending -> (記録から消える)
# client: "203.0.113.7" / "2001:db8:1:2::/64"、起動前からあったセッションは nil
```

- sid と pid は記録しない。作成のリクエストの中で使い、エディタの URL を返したら捨てる。
- 正はいつも Docker: コンテナとネットワークのラベル（`cybertrain-play.role=session`、`.handle`、`.created-at`、
  `.expires-at`）。メモリの記録は表示と IP ごとの上限のためのもの。

```
           作成の受付（ロック内）            準備確認 OK
 (なし) ─────────────────────▶ creating ─────────────────▶ ready
                                  │ 失敗・時間切れ               │ expires-at / 停止 / コンテナが無い・止まった
                                  ▼                              ▼
                               ending（片付け: rm -f → 切断 → network rm）──▶ (記録から消える)
```

### 5.4 Docker の argv テンプレート（全文）

変数は 6 つだけで、どれも制御面が作る: `<h>`（ハンドル）、`<sid>`、`<pid>`、`<subnet>`、`<created>` / `<expires>`
（Unix 秒）。残りは運用者の設定（`PLAY_*`）。訪問者のリクエストから来る値はない。

**ネットワークの作成**

```
docker network create
  --driver bridge
  --internal
  --subnet <subnet>
  --opt com.docker.network.bridge.inhibit_ipv4=true
  --label cybertrain-play.role=session
  --label cybertrain-play.handle=<h>
  --label cybertrain-play.created-at=<created>
  --label cybertrain-play.expires-at=<expires>
  ctplay-n-<h>
```

`inhibit_ipv4=true` はブリッジ（ホスト側）に IP を与えない [文書]。セッションからホストへの L3 の入口が消え、
ルーターとセッションは L2 で話す。`--internal` との併用を Docker が受け付けるかは [未検証]（V3）。受け付けなければ
この 1 行を外し、ホストのファイアウォール（§7.5）だけで守る。

**ルーターの接続**（`docker ps` で見つけた動いているルーターすべてに。0 なら作成を始めない）

```
docker network connect ctplay-n-<h> <ルーターのコンテナ ID>
```

**セッションの起動**

```
docker run
  --detach --rm --init
  --pull never
  --name ctplay-s-<h>
  --hostname playground
  --network ctplay-n-<h>
  --network-alias s-<sid>
  --network-alias p-<pid>
  --label cybertrain-play.role=session
  --label cybertrain-play.handle=<h>
  --label cybertrain-play.created-at=<created>
  --label cybertrain-play.expires-at=<expires>
  --user 1000:1000
  --cap-drop ALL
  --security-opt no-new-privileges
  --read-only
  --tmpfs /tmp:rw,exec,nosuid,nodev,size=256m,mode=1777
  --tmpfs /home/dev:rw,nosuid,nodev,size=128m,uid=1000,gid=1000,mode=0755
  --tmpfs /workspace:rw,exec,nosuid,nodev,size=256m,uid=1000,gid=1000,mode=0755
  --tmpfs /opt/cybertrain-cache:rw,nosuid,nodev,size=64m,uid=1000,gid=1000,mode=0755
  --memory 1536m --memory-swap 1536m
  --cpus 1
  --pids-limit 512
  --log-driver json-file --log-opt max-size=1m --log-opt max-file=1
  [--runtime <PLAY_RUNTIME>]                       # PLAY_RUNTIME が空でないときだけ
  --env VSCODE_PROXY_URI=<scheme>://{{port}}-<pid>.<domain><:port>
  --env PLAYGROUND_ENDS_AT=<expires>
  --env PLAYGROUND_IDLE_TIMEOUT=<PLAY_IDLE_TIMEOUT>
  <PLAY_SESSION_IMAGE>
```

- 数値（`1536m`、`1`、`512`、tmpfs の大きさ）は設定値（§5.10）で、上は既定。
- `--memory 1536m`（オーケストレーターの既定 1g から変更）: エディタ接続中 456 MiB + 再ビルドの山 約 420 MiB +
  サーバー 22 MB + tmpfs 数十 MB で約 0.95 GiB [計測値の和]。1 GiB では 5〜8 % しか余らず、拡張ホストの成長、
  ファイル検索、新しいアプリのビルドを同時に走らせる（2 つのコンパイル）だけで OOM になる。上限は天井で、
  予約ではない。容量の計算は上限ではなく実際の山（約 1 GiB）で行う（§7.9）。
- tmpfs のページはそのコンテナのメモリに数えられる [文書: cgroup v2 の memory コントローラは shmem を数える]。
  ディスクを埋める乱用は自分のメモリの上限で止まる（脅威モデル A4）。
- `exec` を付けるのは `/workspace`（`build/bin/*` を実行する）と `/tmp`（spin と cc の一時ファイル）だけ。
  ホームと spin のキャッシュは `--tmpfs` の既定の `noexec` のまま [文書: `--tmpfs` の既定は `noexec,nosuid,nodev`]。
  そこから何かを実行する必要があれば §8.3 の W8、W9 が落ちるので、そのとき `exec` を足す。
- `--tmpfs` に `uid=` / `gid=` / `mode=` を渡せることは [未検証]（V22。tmpfs のマウントオプションとしては正当）。
- `--pull never`: 事前に取ったイメージだけを使う。無ければ失敗し（§5.12）、勝手に取りに行かない。
- ログ: 1 MB を 1 つ。`--rm` でコンテナと一緒に消える。
- 出さないもの: `--privileged`、`--cap-add`、`-v` / `--mount`（ホストのものを何もマウントしない）、`-p`、
  `--network host`、`--pid host`、`--ipc host`、`--device`、`--security-opt seccomp=unconfined`、
  `--restart`。単体テストが「argv にこれらが無い」ことも確かめる。

**片付け**（どの段も「無い」は成功と見なす）

```
docker rm --force ctplay-s-<h>
docker network inspect --format '{{range $id, $c := .Containers}}{{$id}} {{end}}' ctplay-n-<h>
docker network disconnect --force ctplay-n-<h> <つながっている各コンテナ ID>
docker network rm ctplay-n-<h>
```

**一覧と見張り**

```
docker ps --all --no-trunc --filter label=cybertrain-play.role=session
  --format '{{.ID}}\t{{.Names}}\t{{.State}}\t{{.Label "cybertrain-play.handle"}}\t{{.Label "cybertrain-play.created-at"}}\t{{.Label "cybertrain-play.expires-at"}}'
docker network ls --no-trunc --filter label=cybertrain-play.role=session
  --format '{{.ID}}\t{{.Name}}\t{{.Label "cybertrain-play.handle"}}\t{{.Label "cybertrain-play.created-at"}}'
docker network inspect --format '{{(index .IPAM.Config 0).Subnet}}' ctplay-n-<h>
docker ps --filter <PLAY_ROUTER_FILTERS の各項目> --filter status=running --format '{{.ID}}'
docker stats --no-stream --format '{{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}' <セッションのコンテナ名…>
docker image inspect --format '{{.Id}}' <PLAY_SESSION_IMAGE>
```

すべて `Open3` に配列で渡す（シェルを通さない）。各呼び出しにタイムアウト（作成と片付け 30 秒、一覧 10 秒）。
時間切れはプロセスを殺して失敗として扱う。

### 5.5 サブネットの割り当て

- プール `PLAY_SUBNET_POOL`（既定 `10.250.0.0/16`）を `/PLAY_SUBNET_PREFIX`（既定 28）に切る: 4096 個、各 16 アドレス
  （ゲートウェイの予約、セッション、ルーター、入れ替え中の 2 台目のルーター、予備）。
- 作成のロックの中で、Docker のネットワーク一覧（ラベル `cybertrain-play.role=session`）から使用中を求め、
  一番小さい空きを使う。`docker network create` が "Pool overlaps" で失敗したら（ラベルの無い別のネットワークが
  その範囲にある）、その範囲をプロセスの間だけ「使えない」にして次を試す（3 回まで）。
- 起動時の検査: プールが Docker の既定のプール（172.17〜31、192.168/16）と重なれば起動しない。VPS の私設網と
  重ならないことはオーナーが `ip route` で確かめる（§7.6）。

### 5.6 上限と訪問者への文言

| 設定 | 既定 | 意味 |
| --- | --- | --- |
| `PLAY_MAX_SESSIONS` | 5 | 同時のセッション（`creating` を含む） |
| `PLAY_MAX_SESSIONS_PER_IP` | 1 | 同じクライアントの同時数。IPv4 はアドレス、IPv6 は先頭 64 ビット（本 spec での決定: 1 人の利用者は普通 /64 以上を持つ） |
| `PLAY_CREATE_LIMIT` / `PLAY_CREATE_WINDOW` | 3 / 600 秒 | 同じクライアントの作成回数（成功したものだけ数える。満員で断られた試行は数えない） |

クライアントのアドレスは `PLAY_CLIENT_IP_HEADER`（本番 `CF-Connecting-IP`）から読む。Cloudflare はこのヘッダを
自分で上書きする [文書]。オリジンの 443 を Cloudflare の範囲に絞るので（§7.5）、直接の接続で偽ることはできない。
kamal-proxy の `X-Forwarded-For` の最後の値は Cloudflare のエッジの IP なので使えない（先例の方式はここでは
多くの訪問者を 1 つにまとめてしまう）。ヘッダが無ければ `REMOTE_ADDR`（ルーター）で、全員が 1 つの枠になる（安全側）。

NAT の注意: 学校や会社、携帯の CGNAT では多くの人が 1 つのアドレスを共有し、2 人目から断られる。ワークショップの
日は `PLAY_MAX_SESSIONS_PER_IP` を上げ、VPS を大きくして出し直す（§7.9）。オーナーへの質問 §11.2 の Q5。

文面（英語、ページの見出しと本文。`{}` は値）:

| 状況 | 見出し | 本文 |
| --- | --- | --- |
| 満員 | All sessions are in use | All {cap} playground sessions are in use right now. A session lasts at most {ttl} minutes, so one usually frees up within a few minutes: try again shortly. [Try again] [Open in GitHub Codespaces] (needs a GitHub account) |
| 同じアドレス | A session from your network address is already running | Only one session runs per network address. If it is yours, go back to its tab. If you closed the tab, it ends a few minutes later; at the latest it ends at {HH:MM} UTC. |
| 回数 | Too many sessions from your network address | Try again in {n} minutes. |
| 停止中 | The playground is paused | {メッセージ、既定 "for maintenance"}. Try again later, or use GitHub Codespaces. |
| 失敗 | The session could not be started | Something went wrong on our side. Try again in a minute. |
| 他オリジン | Start a session from {DOMAIN} | [Go to {DOMAIN}] |

### 5.7 準備確認

- 作成のロックの外で、`http://<PLAY_ROUTER_URL>/healthz` に `Host: <sid>.<domain>` で GET（250 ms ごと、最大
  `PLAY_READY_TIMEOUT` = 30 秒、1 回のタイムアウト 2 秒）。200 で本文に `"status"` があれば準備完了。
- 確認はこの間だけで、刈り取りは `/healthz` を叩かない（code-server の心拍を動かしてアイドル終了を
  妨げないため。`/healthz` が心拍を動かさないことは [推論: クライアントがいない間 `lastHeartbeat` が止まった、計測]）。
- 準備に要した時間をログに出す（`ready_ms`）。§8.6 で VPS の値を記録する。
- Kamal の `response_timeout` はルーターのサービスで 60 秒（§7.2）、Cloudflare の待ちは 125 秒 [文書]。

### 5.8 刈り取りと起動時の照合

刈り取りのループ（`PLAY_REAP_INTERVAL` = 5 秒ごと。起動時に 1 回すぐ走らせる。これが照合を兼ねる）:

1. セッションのコンテナ一覧とネットワーク一覧、ルーターの一覧を取る（§5.4）。
2. コンテナ: `expires-at` を過ぎた、または `running` でない → 片付け（理由 `ttl` / `exited`）。
3. ネットワーク: 同じハンドルのコンテナが無く、作成から 60 秒以上たったもの → 片付け（理由 `orphan`）。
   60 秒の猶予は、Kamal の入れ替えで 2 つの制御面が重なる数秒の間に、もう一方が作っている途中の
   ネットワークを消さないため。
4. ルーター: 生きているセッションのネットワークそれぞれに、動いているルーターがすべてつながっていなければ
   つなぐ（Kamal がルーターを入れ替えた後、5 秒以内に新しいルーターが届くようになる）。
5. メモリの記録を合わせる: Docker に無いものを消し、記録に無いもの（制御面の再起動の前からのもの）を
   `client: nil` で足す。
6. 60 秒に 1 回 `docker stats` を取り、CPU 90 % 以上が 10 回続いたセッションを `event=suspect` で記録する
   （止めはしない。外への通信がないので採掘しても払い出しがなく、自分の 1 CPU と 30 分を使うだけ）。
7. 停止スイッチの `kill-all` 要求のファイル（§5.9）があれば全部片付けてファイルを消す。

制御面が落ちても: セッションは動き続け、終了時刻 + 60 秒で自分で止まる。再起動した制御面は 1 回目の
ループで期限切れと孤児を片付け、ルーターをつなぎ直す。

作成と刈り取りの排他: 作成の「上限の確認から `docker run` まで」は `/data/create.lock` の `flock` の中で行う
（スレッド間でも、入れ替えで重なる 2 つの制御面の間でも効く。同じホストの同じファイル）。片付けは冪等なので
ロックを取らない。

### 5.9 停止スイッチ `playctl`

`bin/playctl` は制御面のイメージに入る小さな Ruby スクリプトで、Docker とフラグのファイルを直接触る
（動いている制御面のプロセスに頼らない。`status` の IP だけは `/internal/sessions` から読む）。

| コマンド | すること |
| --- | --- |
| `playctl status` | セッションごとにハンドル、経過、残り、CPU、メモリ、（動いていれば）クライアントのアドレス。全体の数、停止中か |
| `playctl pause [message]` | `/data/paused` にメッセージを書く。新しい作成を止め、入口に表示する。動いているセッションはそのまま |
| `playctl resume` | `/data/paused` を消す |
| `playctl end <handle>` | そのセッションを片付ける |
| `playctl kill-all` | 停止したうえで、全セッションを片付ける（`pause` を自動で行う。再開は `resume`） |

実行の仕方（運用ガイドに書く）: `kamal app exec -c playground/deploy/control.yml --reuse 'bin/playctl pause "maintenance"'`。
制御面が動いていないときの予備（VPS で直接）:

```sh
docker ps -aq --filter label=cybertrain-play.role=session | xargs -r docker rm -f
for n in $(docker network ls -q --filter label=cybertrain-play.role=session); do
  for c in $(docker network inspect -f '{{range $id, $x := .Containers}}{{$id}} {{end}}' "$n"); do
    docker network disconnect -f "$n" "$c"; done
  docker network rm "$n"
done
sudo touch /var/lib/cybertrain-play/paused
```

### 5.10 設定（環境変数）

| 変数 | 既定 | 意味 |
| --- | --- | --- |
| `PLAY_PUBLIC_URL` | （必須） | `https://<DOMAIN>`、ローカルは `http://play.localhost:8080`。スキーム、ドメイン、ポートを導く |
| `PLAY_SESSION_IMAGE` | （必須） | `ghcr.io/saeki-mototsune/cybertrain-playground-web@sha256:…`（本番はダイジェスト固定、§7.4） |
| `PLAY_ROUTER_URL` | `http://ctplay-router` | 準備確認の宛先 |
| `PLAY_ROUTER_FILTERS` | `label=service=cybertrain-play-router,label=role=web` | 接続するルーターを探す `docker ps --filter` の並び |
| `PLAY_ALLOWED_ORIGINS` | `PLAY_PUBLIC_URL` のオリジン | `POST /sessions` を許すオリジン（カンマ区切り）。本番はサイトのオリジンを足す |
| `PLAY_CLIENT_IP_HEADER` | （空 = `REMOTE_ADDR`） | 本番 `CF-Connecting-IP` |
| `PLAY_MAX_SESSIONS` / `PLAY_MAX_SESSIONS_PER_IP` | 5 / 1 | §5.6 |
| `PLAY_CREATE_LIMIT` / `PLAY_CREATE_WINDOW` | 3 / 600 | §5.6 |
| `PLAY_TTL` | 1800 | 秒 |
| `PLAY_IDLE_TIMEOUT` | 300 | 秒（61 以上） |
| `PLAY_READY_TIMEOUT` | 30 | 秒 |
| `PLAY_REAP_INTERVAL` | 5 | 秒 |
| `PLAY_SUBNET_POOL` / `PLAY_SUBNET_PREFIX` | `10.250.0.0/16` / 28 | §5.5 |
| `PLAY_SESSION_MEMORY` / `PLAY_SESSION_CPUS` / `PLAY_SESSION_PIDS` | `1536m` / `1` / 512 | §5.4 |
| `PLAY_TMPFS_TMP` / `_HOME` / `_WORKSPACE` / `_CACHE` | `256m` / `128m` / `256m` / `64m` | §5.4 |
| `PLAY_RUNTIME` | （空 = runc） | `runsc` で gVisor |
| `PLAY_DATA_DIR` | `/data` | `paused`、`kill-all`、`create.lock` |
| `PLAY_CODESPACES_URL` | `https://codespaces.new/saeki-mototsune/CyberTrain?quickstart=1` | 満員のページの案内 |
| `PLAY_ABUSE_CONTACT` | （必須） | 入口、利用条件、`security.txt` |
| `DOCKER_HOST` | （Docker の既定） | — |

起動時に検証し、必須の欠け、数値でない値、`PLAY_IDLE_TIMEOUT` ≤ 60、プールの重なりは起動を止める
（`error: …` を出して終了 1）。起動時に `docker version` と `docker image inspect <PLAY_SESSION_IMAGE>` を行い、
イメージが無ければ「停止中（session image missing）」として作成を断り続け、ログに大きく出す。

### 5.11 ログの規則

sid と pid、エディタとプレビューの URL、セッションのホスト名は持参人払いの秘密として扱う（本 spec での決定）。

- 制御面は 1 つの出来事を 1 行の `key=value` で出す。セッションを指すのはハンドルだけ:
  `play event=created handle=1f2e3d4c5b6a7980 subnet=10.250.0.16/28 ready_ms=1830 live=3/5`、
  `play event=ended handle=… reason=ttl|idle|exited|orphan|killed|failed age_s=1800`、
  `play event=refused reason=full|per_ip|rate|paused|origin live=5/5`、
  `play event=docker_error step=run handle=… status=125 stderr="…"`、`play event=suspect handle=… cpu=99.8%`。
- **IP アドレスはログに出さない**。メモリの記録（生きているセッションの間）にだけ持ち、`playctl status` で見る。
  不正利用への対処（Cloudflare でのブロック）は生きているうちに行う（§7.11）。
- `docker run` の argv はログに出さない（別名と `VSCODE_PROXY_URI` に sid と pid が入る）。Docker のエラー出力は、
  その作成の sid と pid を `<sid>` / `<pid>` に置き換え、さらに 32 桁の 16 進を `<hex32>` に置き換えてから 200 文字で切る。
  単体テストが「作成、失敗、片付けのどのログにも sid が出ない」ことを確かめる。
- ルーター（Caddy）はアクセスログを持たず、実行時のログも既定で捨てる（`ROUTER_LOG_OUTPUT=discard`）。上流への
  接続の失敗のメッセージに `s-<sid>` が入るため。調べるときだけ `stderr` にして出し直す（§7.10）。
- kamal-proxy の要求ログにはホスト名が入る（[推論]、V14）。読めるのは VPS の root と docker グループだけ。
  `kamal proxy boot_config set --log-max-size=1m` で保持を短くする。生きているログを人に渡さない
  （運用ガイドに書く）。セッションは 30 分で無効になる。
- Cloudflare はすべてを見る（利用条件に書く）。

### 5.12 失敗のときの扱い

| 段 | 失敗 | 制御面がすること | 訪問者 |
| --- | --- | --- | --- |
| 起動時の `docker version` | デーモンに届かない | `/up` が 503、作成を断る、10 秒ごとに再試行 | 503「失敗」 |
| ルーターの一覧 | 0 台 | 何も作らずに断る | 503「停止中」に近い文面（"is starting up"） |
| ネットワークの作成 | "Pool overlaps" | 次の範囲で再試行（3 回）。尽きたら断る | 503「失敗」 |
| ネットワークの作成 | その他 | 断る | 503「失敗」 |
| ルーターの接続 | 失敗 | ネットワークを片付ける | 503「失敗」 |
| `docker run` | "No such image" | 片付け。「イメージなし」の停止状態にする | 503「停止中」 |
| `docker run` | その他 | 片付け | 503「失敗」 |
| 準備確認 | 30 秒で答えない | 片付け。`event=ended reason=failed` | 503「失敗」 |
| 片付けの各段 | 「無い」 | 成功と見なす | — |
| 片付けの各段 | その他（"active endpoints" など） | ログに出し、次のループで再試行 | — |
| `docker` の呼び出し | タイムアウト | プロセスを殺して失敗として扱う | 上のどれか |
| 刈り取りのループ | 予期しない例外 | プロセスが落ちる → Docker が起こし直す → 照合 | 数秒入口が使えない |

作れなかったセッションは何も残さない: 作成の途中のどこで失敗しても、そのハンドルの片付け（§5.4）を必ず
走らせる。片付けそのものが失敗しても、ラベルの付いた残りは次のループの 2〜3 が消す。

### 5.13 ページ

- 入口 `GET /`（英語、JavaScript なしで動く。CSS はページ内に少し、外部の読み込みなし）:
  - 見出し "Try cybertrain in your browser, no account"。
  - 1 段落: "Start a session and VS Code opens in your browser on the blog from the tutorial: its development
    server running in a terminal and the app in the editor's preview. Edit a view and reload the preview;
    change Ruby and the app rebuilds itself in about a minute."
  - 事実の一覧: "Lasts: {ttl} minutes, then the session is deleted with its files" / "Inside: Spinel, the
    cybertrain CLI and the blog; no network access" / "At a time: {cap} sessions, one per network address" /
    "Works best in: a desktop browser (Chrome, Edge or Firefox)".
  - 空き: "{free} of {cap} sessions are free." または "All {cap} sessions are in use: try again in a few minutes."
  - ボタン（`<form method="post" action="/sessions">`）"Start a session"。押したらボタンを無効にして
    "Starting…" にするだけの小さなスクリプト（二重送信の防止。無くても動く）。
  - 注意: "Anyone with a session's address can use it, terminal included, so do not share it. Do not put
    secrets or personal data in it." と [Terms and privacy]、[Open in GitHub Codespaces instead]、サイトと GitHub への
    リンク、窓口のメールアドレス。
- `GET /terms`: 利用条件（S6）とプライバシーの要点:
  - "The playground is provided as is, for trying cybertrain. Sessions are temporary and deleted with their files when
    they end; nothing is backed up. We may end any session at any time."
  - "Do not use it to host or send phishing, malware or spam, for illegal content, or to attack anything. Sessions
    have no network access."
  - "What we keep: while a session runs, the network address that started it, in memory only, to enforce the
    limits. Server logs record when sessions start and end with an internal number, not your address.
    Cloudflare, our network provider, carries all traffic, including what you type, under its own privacy
    policy, and may set its own security cookies. Your browser asks no extension marketplace" （V10 が駄目なら
    "Your browser may contact the Open VSX extension registry"）. "This site sets no cookies; the app in the
    preview sets its own."
  - "Report abuse or a security problem: {contact}."
  - 文面はオーナーが承認する（§11.2 の Q7）。
- 拒否のページ（§5.6）: 同じ見た目、`Cache-Control: no-store`。

すべてのページに付けるヘッダ（制御面が出す）: `Content-Security-Policy: default-src 'none'; style-src 'unsafe-inline';
script-src 'sha256-<ボタンのスクリプト>'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'`、
`Referrer-Policy: no-referrer`、`X-Content-Type-Options: nosniff`。

## 6. ルーティングとヘッダ

### 6.1 `playground/router/Caddyfile`（全文）

```caddyfile
# playground/router/Caddyfile -- the hosted playground's router (SP2).
#
# kamal-proxy terminates TLS and hands this Caddy every request for
# {$PLAY_DOMAIN} and *.{$PLAY_DOMAIN} as plain HTTP (locally the browser
# talks to it directly). Nothing here changes per session: a session is
# reachable exactly while a container with the network alias s-<editor id>
# or p-<preview id> shares a network with this router (the control plane
# attaches it) and answers. Never reloaded: a reload would close every
# editor's WebSocket.
{
	admin off
	auto_https off
	persist_config off
	log default {
		output {$ROUTER_LOG_OUTPUT:discard}
		level ERROR
	}
}

:80 {
	# route keeps the written order (Caddy would otherwise sort handle
	# blocks with path matchers ahead of the others).
	route {
		# A session container can reach this router on its own network. It
		# gets nothing: not another session, not the control plane.
		@from_session remote_ip {$PLAY_SUBNET_POOL}
		handle @from_session {
			abort
		}

		@editor {
			host *.{$PLAY_DOMAIN}
			header_regexp editor Host ^([0-9a-f]{32})\.
		}
		handle @editor {
			header {
				defer
				Referrer-Policy no-referrer
				X-Robots-Tag "noindex, nofollow"
				X-Content-Type-Options nosniff
				+Content-Security-Policy "frame-ancestors 'self'"
			}
			reverse_proxy s-{re.editor.1}:8080
		}

		@preview {
			host *.{$PLAY_DOMAIN}
			header_regexp preview Host ^3000-([0-9a-f]{32})\.
		}
		handle @preview {
			header {
				defer
				Referrer-Policy no-referrer
				X-Robots-Tag "noindex, nofollow"
				Cache-Control no-store
				+Content-Security-Policy "frame-ancestors *.{$PLAY_DOMAIN}:*"
			}
			reverse_proxy p-{re.preview.1}:3000
		}

		@apex host {$PLAY_DOMAIN}
		handle @apex {
			handle /internal/* {
				error 404
			}
			handle {
				reverse_proxy {$PLAY_CONTROL_UPSTREAM:ctplay-control:9292}
			}
		}

		# kamal-proxy's health check (its Host is the container's address).
		handle /up {
			respond "OK" 200
		}

		handle {
			error 404
		}
	}

	handle_errors {
		header {
			Cache-Control no-store
			X-Robots-Tag "noindex, nofollow"
			Referrer-Policy no-referrer
		}
		root * /srv/pages
		@apex_error host {$PLAY_DOMAIN}
		handle @apex_error {
			rewrite * /unavailable.html
			templates
			file_server {
				status 503
			}
		}
		@preview_error header_regexp Host ^3000-[0-9a-f]{32}\.
		handle @preview_error {
			rewrite * /app-down.html
			templates
			file_server {
				status 502
			}
		}
		handle {
			rewrite * /ended.html
			templates
			file_server {
				status 404
			}
		}
	}
}
```

- 環境変数: `PLAY_DOMAIN`（例 `<DOMAIN>`、ローカル `play.localhost`）、`PLAY_PUBLIC_URL`（ページのリンク用）、
  `PLAY_SUBNET_POOL`（制御面と同じ値）、任意で `PLAY_CONTROL_UPSTREAM`、`ROUTER_LOG_OUTPUT`。
- `host *.{$PLAY_DOMAIN}` は一段のラベルだけに合い、ポートを無視する [文書]。`header_regexp` の Host には
  ポートが付きうる（ローカルの `:8080`）ので、先頭のラベルだけを錨付きで見る。
- 上流の名前に置換子を使う形（`s-{re.editor.1}:8080`）は「動的だが静的」な上流として許される [文書]。
  `header_regexp` の捕獲の書き方と合わせて [未検証]（V2）。ローカルの E2E が最初に確かめる。
- `+Content-Security-Policy` は追加: アプリや code-server が自分の CSP を出していれば両方が効く（上書きして
  弱めない）。`defer` は上流の応答ヘッダの後に適用し、`Cache-Control` などをこちらの値にそろえるため。
- Caddy の実行時のログを捨てる理由は §5.11。

`playground/router/Dockerfile`（全文）:

```dockerfile
# playground/router/Dockerfile -- the hosted playground's router (SP2): stock
# Caddy with a static Caddyfile and three static pages. Kamal builds it
# (playground/deploy/router.yml); playground/dev/compose.yml runs it locally.
FROM caddy:2.10-alpine
COPY playground/router/Caddyfile /etc/caddy/Caddyfile
COPY playground/router/pages/ /srv/pages/
# Defaults for validation and local runs; Kamal sets the real values.
ENV PLAY_DOMAIN=play.localhost \
    PLAY_PUBLIC_URL=http://play.localhost:8080 \
    PLAY_SUBNET_POOL=10.250.0.0/16
RUN caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
```

（Caddy のパッチ版は実装時に最新の 2.x に固定する。`Dockerfile.dockerignore` は `*` と `!playground/router/`。）

ページ（`playground/router/pages/`、Caddy の `templates` で `{{env "PLAY_PUBLIC_URL"}}` を埋める。外部の読み込みなし、
ライトとダークの両方の色、幅 16 px の余白）:

| ファイル | 状態 | 見出しと本文 |
| --- | --- | --- |
| `ended.html` | 404 | "No session at this address" / "Playground sessions last a limited time, end a few minutes after their tab is closed, and are deleted with their files. If you just started this one or the playground was just updated, reload in a few seconds." [Start a new session] [Open in GitHub Codespaces] |
| `app-down.html` | 502 | "No app is answering here" / "If your session is still running, start the server in its terminal with `playground-server`, then reload. Sessions also end after a limited time." |
| `unavailable.html` | 503 | "The playground is not available right now" / "Try again in a few minutes, or open it in GitHub Codespaces." |

### 6.2 不明なセッション、終わったセッション

| 状況 | ルーターの判断 | 応答 |
| --- | --- | --- |
| ホスト名が形に合わない（`foo.<DOMAIN>`、`www.<DOMAIN>`、他のドメイン） | どの handle にも合わない | 404 `ended.html` |
| 形は合うが別名が無い（作られていない、終わった、ルーターがまだつながっていない） | 上流の名前が引けず 502 | エディタ 404 `ended.html`、プレビュー 502 `app-down.html` |
| コンテナはあるが待ち受けていない（code-server の起動前、開発サーバーを止めた） | 接続拒否で 502 | 同上 |
| セッションの範囲からの接続 | `@from_session` | 接続を切る（`abort`） |
| 入口で制御面が落ちている | 502 | 503 `unavailable.html` |

DNS リバインディング（脅威モデル F5）: 他人のドメインの名前でこのオリジンに来た要求は、kamal-proxy にその
ホストのサービスが無く 404 で終わる。ルーターの Host の形の検査がもう一段。

### 6.3 オリジンごとのヘッダ

| ヘッダ | 入口 `<DOMAIN>`（制御面が出す） | エディタ `<sid>.<DOMAIN>` | プレビュー `3000-<pid>.<DOMAIN>` | エラーのページ |
| --- | --- | --- | --- | --- |
| `Referrer-Policy` | `no-referrer` | `no-referrer` | `no-referrer` | `no-referrer` |
| `X-Robots-Tag` | なし（入口は検索されてよい） | `noindex, nofollow` | `noindex, nofollow` | `noindex, nofollow` |
| `Content-Security-Policy` | §5.13 の厳しいもの（`frame-ancestors 'none'`） | 追加 `frame-ancestors 'self'` | 追加 `frame-ancestors *.<DOMAIN>:*` | なし |
| `X-Content-Type-Options` | `nosniff` | `nosniff` | 付けない（訪問者のアプリの応答を変えない） | なし |
| `Cache-Control` | ページと拒否は `no-store` | code-server のまま | `no-store` | `no-store` |
| HSTS | Cloudflare で（§6.4、公開確認の後） | 同 | 同 | 同 |
| `X-Frame-Options` | 付けない（CSP で足りる） | 付けない | 付けない | — |

- エディタを `'self'` にする理由: code-server は webview を同じオリジンから配り、ワークベンチがそれを枠に入れる
  [計測: フレームの連鎖]。`DENY` や `'none'` は Markdown のプレビューや Simple Browser を壊す [推論]。
- プレビューを `*.<DOMAIN>:*` にする理由: スパイクで `X-Frame-Options: SAMEORIGIN` と `frame-ancestors 'self'` は
  プレビューを `chrome-error://` にした [計測]。祖先はエディタのオリジン（`<sid>.<DOMAIN>`）で、プレビューとは別の
  ホスト。ルーターはプレビューの pid からエディタの sid を知らないので、ドメイン全体を許す。目的は外のサイトが
  訪問者のアプリ（フィッシングかもしれない）を枠に入れられないようにすること。スキームの無いホスト源は保護対象と
  同じスキームに合い、`:*` は任意のポートに合う [文書: CSP3]。実ブラウザでの確認は V11。
- `Referrer-Policy: no-referrer` はプレビューの中のリンクから外へ出たときに能力 URL が漏れないため（M6）。

### 6.4 Cloudflare の設定

必ずすること:

| 設定 | 値 | 理由 |
| --- | --- | --- |
| DNS | `A <DOMAIN>` と `A *` を VPS の IPv4 へ、どちらも Proxied。AAAA は作らない | Universal SSL がプロキシしたホスト名だけを覆う。オリジンを IPv4 だけにしてファイアウォールを 1 系統にする（訪問者には Cloudflare が IPv6 でも答える） |
| SSL/TLS の暗号化モード | Full (strict) | Origin CA 証明書の前提 [文書] |
| Origin Server | Origin CA 証明書を作る: ECC、ホスト名 `<DOMAIN>` と `*.<DOMAIN>`、有効期限は最長 | kamal-proxy に入れる。更新の手間が数年ない。期限の通知は来ないので暦に書く [文書] |
| Edge Certificates | Always Use HTTPS: on、Minimum TLS: 1.2 | — |
| Cache Rules | 1 つ: 条件「Hostname ends with `<DOMAIN>`」（または All incoming requests）→ Bypass cache | Cloudflare は既定で css/js などの拡張子を保存する [未検証、調査]。編集した CSS がプレビューで古いままになる |
| Network | WebSockets: on（既定） | エディタ |
| 切るもの | Rocket Loader、Email Address Obfuscation、Automatic HTTPS Rewrites、Always Online、Bot Fight Mode | 前の 3 つは訪問者の HTML を書き換える。Bot Fight Mode の確認はエディタの XHR と WebSocket が答えられず、Free では範囲を絞れない |
| HSTS | §7.7 が通った後で: max-age 6 か月、includeSubDomains、preload なし | 一度出すと戻せないので最後に |

してはいけないこと:

- **Under Attack モード**: すべての要求に確認を挟み、エディタの WebSocket と XHR を壊す。範囲を絞った WAF 規則を
  使う（§7.11）。
- 一部のレコードだけをプロキシすること（Origin CA 証明書はブラウザに信頼されない）。
- キャッシュ、HTML の変換、Workers での書き換え。

任意（手順書で使う、既定は無効）: WAF のカスタム規則「`(http.host eq "<DOMAIN>")` → Managed Challenge」
（入口だけに確認を挟む。エディタとプレビューには掛けない）、レート制限の規則（Free で 1 つ）「`POST /sessions`、
同じ IP で 10 秒に 5 回」→ Block。Google Search Console でドメインを確認しておく（DNS の TXT。Safe Browsing の
通知と再審査の窓口）。

## 7. デプロイ

### 7.1 Kamal の 2 つのサービス（本 spec での決定）

| サービス | 中身 | 出す頻度 | 出したときの影響 |
| --- | --- | --- | --- |
| `cybertrain-play-router`（`playground/deploy/router.yml`） | ルーターの小さなイメージ（Caddy + Caddyfile）。kamal-proxy が `<DOMAIN>` と `*.<DOMAIN>` をここへ送る | まれ（Caddy の版、ヘッダの変更） | kamal-proxy が古いルーターを抜くとき全エディタの WebSocket が切れる [ソース]。VS Code が再接続する。新しいルーターがセッションにつながるまで最長 5 秒（§5.8） |
| `cybertrain-play`（`playground/deploy/control.yml`） | 制御面。kamal-proxy を使わない（`proxy: false`）。ネットワーク別名 `ctplay-control` でルーターから届く | ふつう（コード、設定、セッションのイメージの更新） | 入口が数秒使えない。動いているセッションは影響なし（データの経路に入らない） |

1 つのサービスに 2 つの役割を置く形は、`kamal deploy` のたびにルーターも入れ替わり、毎回全エディタの接続を
切るので採らない。両サービスは同じ VPS、同じ kamal-proxy、同じ `kamal` ネットワークを使う。
Kamal の版: プロキシの `ssl.certificate_pem`、ワイルドカードのホスト、`hooks_path`、役割の `proxy: false` と
`options` を持つ版を plan の最初のタスクで確かめ、両方の設定に `minimum_version` を書く（[未検証] V13）。

### 7.2 `playground/deploy/router.yml.example`（全文）

```yaml
# Kamal config of the hosted playground's router (SP2): a stock Caddy that
# kamal-proxy hands every request for <DOMAIN> and *.<DOMAIN>. Copy to
# playground/deploy/router.yml (git-ignored) and fill in the placeholders.
#
#   kamal setup  -c playground/deploy/router.yml   # once, before the control plane
#   kamal deploy -c playground/deploy/router.yml   # rarely: live editors reconnect (playground/deploy/README.md)
service: cybertrain-play-router
image: <GHCR_OWNER>/cybertrain-play-router

servers:
  web:
    hosts:
      - <VPS_IP>
    options:
      network-alias: ctplay-router

proxy:
  hosts:
    - <DOMAIN>
    - "*.<DOMAIN>"
  app_port: 80
  ssl:
    certificate_pem: CERTIFICATE_PEM
    private_key_pem: PRIVATE_KEY_PEM
  forward_headers: false
  # POST /sessions waits for the new session (up to PLAY_READY_TIMEOUT, 30 s).
  response_timeout: 60
  healthcheck:
    path: /up
    interval: 1
    timeout: 3

registry:
  server: ghcr.io
  username: <GHCR_OWNER>
  password:
    - KAMAL_REGISTRY_PASSWORD

builder:
  arch: amd64
  context: .
  dockerfile: playground/router/Dockerfile

env:
  clear:
    PLAY_DOMAIN: <DOMAIN>
    PLAY_PUBLIC_URL: https://<DOMAIN>
    PLAY_SUBNET_POOL: 10.250.0.0/16

logging:
  options:
    max-size: 10m
    max-file: "3"

# Non-root deploy user in the docker group on the VPS.
ssh:
  user: deploy
```

### 7.3 `playground/deploy/control.yml.example`（全文）

```yaml
# Kamal config of the hosted playground's control plane (SP2). Copy to
# playground/deploy/control.yml (git-ignored) and fill in the placeholders.
# Rendered through ERB: PLAY_SESSION_IMAGE pins the tested session image
# (CI's cybertrain-playground-web:latest) by digest at each deploy, and the
# pre-deploy hook pulls exactly that onto the host.
#
#   kamal setup  -c playground/deploy/control.yml   # once, after the router
#   kamal deploy -c playground/deploy/control.yml   # any time: live sessions keep running
service: cybertrain-play
image: <GHCR_OWNER>/cybertrain-play-control

servers:
  web:
    hosts:
      - <VPS_IP>
    proxy: false
    options:
      network-alias: ctplay-control

registry:
  server: ghcr.io
  username: <GHCR_OWNER>
  password:
    - KAMAL_REGISTRY_PASSWORD

builder:
  arch: amd64
  context: .
  dockerfile: playground/control/Dockerfile

env:
  clear:
    PLAY_PUBLIC_URL: https://<DOMAIN>
    PLAY_SESSION_IMAGE: <%= `playground/deploy/session-image`.strip %>
    PLAY_ALLOWED_ORIGINS: https://<DOMAIN>,https://saeki-mototsune.github.io
    PLAY_CLIENT_IP_HEADER: CF-Connecting-IP
    PLAY_ROUTER_URL: http://ctplay-router
    PLAY_ROUTER_FILTERS: label=service=cybertrain-play-router,label=role=web
    PLAY_MAX_SESSIONS: "5"
    PLAY_MAX_SESSIONS_PER_IP: "1"
    PLAY_TTL: "1800"
    PLAY_SESSION_MEMORY: 1536m
    PLAY_SUBNET_POOL: 10.250.0.0/16
    PLAY_RUNTIME: ""
    PLAY_ABUSE_CONTACT: <ABUSE_EMAIL>

volumes:
  - /var/run/docker.sock:/var/run/docker.sock
  - /var/lib/cybertrain-play:/data

hooks_path: playground/deploy/hooks

logging:
  options:
    max-size: 10m
    max-file: "3"

ssh:
  user: deploy
```

### 7.4 秘密、フック、セッションのイメージ

> §16.5 が優先: `.kamal/secrets` の `$(cat "${PLAY_ORIGIN_CERT:-/dev/null}")` の形は Kamal 2.12 の解釈で証明書が空になる（実装は `$(test -n "$VAR" && cat "$VAR")`）。ロールバックは古いイメージを**今の設定**で起動するので、セッションのイメージは巻き戻らない（`PLAY_SESSION_IMAGE_REF` で指定する）。フックは `pre-build`（ツリーの検査）、`pre-deploy`（ロールバックでも取得、プールの一致、証明書の確認、参照の検証）、`post-deploy`（固定したイメージは消さない）に変わった。

**イメージの作り方（本 spec での決定、先例からの変更）**: spinel scope は pre-deploy フックでサンドボックスの
イメージを手元で作っている。このイメージは Spinel とブログのビルド（コンパイル 3 回）を含み、arm64 の Mac で
amd64 をエミュレーションすると数十分かかる [推論]。そこで CI（amd64 のランナーで本物のビルド）がテスト済みの
`cybertrain-playground-web:latest` を出し、デプロイはそのダイジェストを固定して、フックは VPS に pull するだけにする。
ロールバックは古い制御面の環境変数（古いダイジェスト）に戻るので、セッションのイメージも一緒に戻る。

`.kamal/secrets`（リポジトリの最上位に置く。値は持たず参照だけなのでコミットしてよい。Kamal はこの場所を読む）:

```sh
# Kamal secrets of the hosted playground (playground/deploy/*.yml): references
# to the operator's environment and files only; nothing secret is committed.
KAMAL_REGISTRY_PASSWORD=$KAMAL_REGISTRY_PASSWORD
CERTIFICATE_PEM=$(cat "${PLAY_ORIGIN_CERT:-/dev/null}")
PRIVATE_KEY_PEM=$(cat "${PLAY_ORIGIN_KEY:-/dev/null}")
```

複数行の PEM がこの形で kamal-proxy まで届くかは [未検証]（V13）。§7.7 の P4 で確かめる。

`playground/deploy/session-image`（全文）:

```sh
#!/bin/sh
# playground/deploy/session-image [REPOSITORY] -- prints the session image a
# control-plane deploy pins: REPOSITORY:latest (default
# ghcr.io/saeki-mototsune/cybertrain-playground-web, which CI pushes only
# after its smoke and end-to-end tests pass) resolved to its digest. Also
# writes it to playground/deploy/.session-image (git-ignored) for the
# pre-deploy hook. control.yml calls it through ERB whenever Kamal reads the
# config. PLAY_SESSION_IMAGE_REF set: that reference, as it is.
set -eu
repo=${1:-ghcr.io/saeki-mototsune/cybertrain-playground-web}
here=$(cd "$(dirname "$0")" && pwd)
if [ -n "${PLAY_SESSION_IMAGE_REF:-}" ]; then
  ref=$PLAY_SESSION_IMAGE_REF
else
  digest=$(docker buildx imagetools inspect "$repo:latest" --format '{{.Manifest.Digest}}')
  case "$digest" in sha256:*) ;; *) echo "session-image: no digest for $repo:latest" >&2; exit 1 ;; esac
  ref="$repo@$digest"
fi
printf '%s\n' "$ref" > "$here/.session-image"
printf '%s' "$ref"
```

`playground/deploy/hooks/pre-deploy`（全文）:

```sh
#!/bin/sh
# Run by `kamal deploy -c playground/deploy/control.yml` (hooks_path). Pulls
# the session image that PLAY_SESSION_IMAGE names onto every host, so the
# control plane's `docker run --pull never` finds it. Any failure aborts the
# deploy: the control plane never goes live naming an image the host lacks.
# Rollbacks skip it: the older image is still on the host (post-deploy keeps
# three).
set -eu
[ "${KAMAL_COMMAND:-}" = "rollback" ] && exit 0
HOSTS="${KAMAL_HOSTS:?KAMAL_HOSTS must be set (this hook is run by kamal deploy)}"

git diff-index --quiet HEAD || {
  echo "pre-deploy: uncommitted changes: commit first (the control image is built from this tree)" >&2
  exit 1
}
ref_file=playground/deploy/.session-image
[ -s "$ref_file" ] || { echo "pre-deploy: $ref_file is missing (playground/deploy/session-image writes it)" >&2; exit 1; }
REF=$(cat "$ref_file")
SSH_USER=$(sed -n 's|^ *user: *\(.*\)|\1|p' playground/deploy/control.yml | head -n 1)
SSH_USER="${SSH_USER:-root}"

for HOST in $(echo "$HOSTS" | tr ',' ' '); do
  echo "pre-deploy: pulling $REF on $HOST"
  ssh "$SSH_USER@$HOST" "docker pull '$REF' > /dev/null && docker image inspect --format '{{.Id}}' '$REF'"
done
```

`playground/deploy/hooks/post-deploy`（全文）:

```sh
#!/bin/sh
# Run after `kamal deploy -c playground/deploy/control.yml`: keeps the three
# newest session images on every host. docker rmi refuses an image a live
# session uses, which is fine.
set -u
[ "${KAMAL_COMMAND:-}" = "deploy" ] || exit 0
SSH_USER=$(sed -n 's|^ *user: *\(.*\)|\1|p' playground/deploy/control.yml | head -n 1)
for HOST in $(echo "${KAMAL_HOSTS:-}" | tr ',' ' '); do
  ssh "${SSH_USER:-root}@$HOST" \
    "docker images ghcr.io/saeki-mototsune/cybertrain-playground-web --format '{{.ID}}' | awk '!seen[\$0]++' | tail -n +4 | xargs -r docker rmi > /dev/null 2>&1 || true"
done
```

`.gitignore` に足す: `playground/deploy/router.yml`、`playground/deploy/control.yml`、`playground/deploy/.session-image`、
`playground/dev/data/`。

### 7.5 ホストのファイアウォール

> §16.5 が優先: 本文のスクリプトは Cloudflare の一覧の最終行（改行なし）を落とし、iptables の失敗を見ず、途中で止まると 80/443 が開いたままになる。実装は適用前に検証し、`iptables-restore -w --noflush` の 1 トランザクションで適用し、`flock` を取り、失敗は非ゼロで終わる。ユニットは `Restart=on-failure`、`RestartSec=10`、`WantedBy=multi-user.target docker.service`。

`playground/deploy/host/cybertrain-play-firewall`（全文、VPS の `/usr/local/sbin/` に置く）:

```bash
#!/usr/bin/env bash
# cybertrain-play-firewall -- host rules of the hosted playground (SP2), run
# by cybertrain-play-firewall.service after Docker starts and whenever Docker
# restarts; safe to run again (it rebuilds its own chains).
#   POOL     the session subnet pool (PLAY_SUBNET_POOL)   default 10.250.0.0/16
#   EXT_IF   the public interface                         default: the default route's
#   CF_LIST  Cloudflare's IPv4 ranges, one per line        default /etc/cybertrain-play/cloudflare-ips-v4
#            (from https://www.cloudflare.com/ips-v4)
# Session rules always apply. The Cloudflare-only rule for ports 80/443 needs
# a non-empty CF_LIST; without one the script says so and exits 1, leaving
# the ports open (per-IP limits can then be spoofed; the global cap holds).
set -uo pipefail
POOL=${POOL:-10.250.0.0/16}
EXT_IF=${EXT_IF:-$(ip -4 route show default | awk '{print $5; exit}')}
CF_LIST=${CF_LIST:-/etc/cybertrain-play/cloudflare-ips-v4}
status=0

chain() { iptables -N "$1" 2>/dev/null || iptables -F "$1"; }

# 1. A session never talks to the host itself (its bridge has no host address
#    with inhibit_ipv4; this covers the case where it has one).
iptables -C INPUT -s "$POOL" -j DROP 2>/dev/null || iptables -I INPUT 1 -s "$POOL" -j DROP

# 2. Forwarded traffic, checked before Docker's own rules (DOCKER-USER).
chain CTPLAY
iptables -A CTPLAY -d 169.254.169.254/32 -j DROP          # cloud metadata, from any container
if [ -s "$CF_LIST" ]; then
  chain CTPLAY-EDGE
  while read -r range; do
    [ -n "$range" ] && iptables -A CTPLAY-EDGE -s "$range" -j RETURN
  done < "$CF_LIST"
  iptables -A CTPLAY-EDGE -j DROP
  for port in 80 443; do
    iptables -A CTPLAY -i "$EXT_IF" -p tcp -m conntrack --ctorigdstport "$port" --ctdir ORIGINAL -j CTPLAY-EDGE
  done
else
  echo "cybertrain-play-firewall: $CF_LIST is empty: ports 80/443 stay open to everyone" >&2
  status=1
fi
iptables -A CTPLAY -m physdev --physdev-is-bridged -j RETURN  # router <-> session on one bridge
iptables -A CTPLAY -s "$POOL" -j DROP                         # anything routed out of a session network
iptables -C DOCKER-USER -j CTPLAY 2>/dev/null || iptables -I DOCKER-USER 1 -j CTPLAY
exit "$status"
```

`playground/deploy/host/cybertrain-play-firewall.service`（全文、`/etc/systemd/system/`）:

```ini
[Unit]
Description=cybertrain playground host firewall rules
After=docker.service
Requires=docker.service
PartOf=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/cybertrain-play-firewall

[Install]
WantedBy=multi-user.target
```

`playground/deploy/host/daemon.json.example`（全文、`/etc/docker/daemon.json`）:

```json
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" },
  "live-restore": true
}
```

- `live-restore`: Docker の更新や再起動でコンテナ（セッション、Kamal のアプリ）が止まらない。
- ufw: `default deny incoming`、`allow 22/tcp`（できれば運用者の IP だけ）。Docker が公開する 80/443 の IPv4 は
  ufw（INPUT）ではなく FORWARD を通るので、上の DOCKER-USER の規則で絞る [文書: Docker のパケットフィルタ]。
  IPv6 の 80/443 は docker-proxy が受けるので INPUT を通り、ufw が落とす [推論]。§7.7 の P3 で確かめる。
- Ubuntu 24.04 の `iptables` は nft の裏側で動き、Docker の連鎖と同じ表を見る [推論]。

### 7.6 オペレーターの初回手順（チェックリスト）

> §16.5 が優先: 手順 5 の `kamal setup` は sudo の無い `deploy` では Docker を入れられない。手順 6 の `curl | tee` は一時ファイルに落として検証してから置く。手順 10 の個人のトークンは、公開イメージを push できないデプロイ専用の GitHub アカウントのトークンに替える。ホストのパッチ運用（unattended-upgrades、再起動の方針、docker-ce / containerd.io の更新）が要る。実際の手順は運用ガイドの第 1〜4 部。

1. **ドメインを買う**（オーナー）。Public Suffix List に載っていない登録可能ドメイン（例えば新しい `.dev`）。
   `mototsune.dev` の下は使わない（オーナーの決定）。
2. **Cloudflare**: Free のアカウントにゾーンを足し、レジストラのネームサーバーを Cloudflare に替える。
3. **VPS を契約する**: Tokyo、Ubuntu 24.04 LTS、IPv4。推奨は「メモリ 12 GB / 6 vCPU」級（調査の時点で
   ConoHa 12 GB / 6 vCPU ¥7,348/月 [文書、2026-10、税の扱いは未確認]、同時 8 セッション）。最小は 8 GB 級
   （さくら 8 GB / 6 コア ¥7,920/月 [文書]、同時 5 セッション）。4 GB 級（¥3,608）は 2 セッションしか入らない。
   KVM は不要（gVisor の systrap は VM の中で動く [文書]）。
4. **ユーザーと SSH**: `deploy` ユーザー（鍵だけ、`docker` グループ）、`PermitRootLogin no`、
   `PasswordAuthentication no`。VPS の私設網の範囲を `ip route` で見て `10.250.0.0/16` と重ならないことを確かめる
   （重なれば `PLAY_SUBNET_POOL` を変え、ルーターと制御面の両方に同じ値を書く）。
5. **Docker**: Docker の公式 apt リポジトリから入れる（`kamal setup` に任せてもよい）。`daemon.json.example` を
   `/etc/docker/daemon.json` に置き、`systemctl restart docker`（まだ何も動いていないうちに）。cgroup v2 であること
   （`docker info | grep -i cgroup`、24.04 の既定）。
6. **ファイアウォール**: `ufw default deny incoming && ufw allow 22/tcp && ufw enable`。
   `curl -fsS https://www.cloudflare.com/ips-v4 | sudo tee /etc/cybertrain-play/cloudflare-ips-v4`、
   スクリプトとユニットを置いて `systemctl enable --now cybertrain-play-firewall`。`iptables -S DOCKER-USER` と
   `iptables -S CTPLAY` で規則を見る。
7. **データのディレクトリ**: `sudo install -d -m 0750 /var/lib/cybertrain-play`。
8. **Cloudflare の DNS と TLS**: §6.4 の「必ずすること」を上から（HSTS を除く）。Origin CA の PEM と鍵を手元の
   安全な場所（例 `~/.secrets/cybertrain-play/`）に保存し、期限を暦に書く。
9. **窓口のメールアドレス**を決める（入口、利用条件、`security.txt` に出る）。
10. **GitHub**: CI が初めて `cybertrain-playground-web` を出したら、そのパッケージを Public にしてリポジトリに
    結び付ける（SP1 と同じ手順）。Kamal 用に `write:packages` の PAT を作る（ルーターと制御面のイメージを
    push し、VPS が pull する。この 2 つのパッケージは private のままでよい）。リポジトリの Private Vulnerability
    Reporting を有効にする（§9.5）。
11. **手元の Kamal**: `gem install kamal -v <plan が決めた版>`。`playground/deploy/*.yml.example` を写して
    `<VPS_IP>`、`<DOMAIN>`、`<GHCR_OWNER>`、`<ABUSE_EMAIL>` を埋める。
    `export KAMAL_REGISTRY_PASSWORD=… PLAY_ORIGIN_CERT=~/.secrets/cybertrain-play/origin.pem PLAY_ORIGIN_KEY=…`。
12. **kamal-proxy のログ**: `kamal proxy boot_config set -c playground/deploy/router.yml --log-max-size=1m`
    （ホスト名を長く残さない、§5.11）。
13. **最初のデプロイ**: `kamal setup -c playground/deploy/router.yml`、続けて `kamal setup -c playground/deploy/control.yml`。
14. **確認**: §7.7 をすべて。結果（作成時間、再ビルド時間、メモリ）を `playground/deploy/README.md` に書く。
15. **HSTS** を Cloudflare で有効にする（§6.4）。
16. **gVisor の計測**（最初の週、§7.12）。
17. **公開**: §9.1 の入口のコミットをマージする（オーナーの判断）。
18. 任意: Google Search Console でドメインを確認する。外形監視（§7.10）を有効にする。

### 7.7 デプロイ後の確認（VPS とドメイン）

| # | 確かめること | 期待 |
| --- | --- | --- |
| P1 | `curl -sI https://<DOMAIN>/` | 200、`server: cloudflare`、入口の CSP |
| P2 | `curl -s https://<DOMAIN>/status.json` | `accepting: true`、`live: 0` |
| P3 | 手元から `curl -sk --max-time 5 --resolve <DOMAIN>:443:<VPS_IP> https://<DOMAIN>/status.json`、IPv6 があれば同じく `[<v6>]` | どちらも時間切れ（Cloudflare 以外は届かない） |
| P4 | VPS の上で `curl -vk --resolve <DOMAIN>:443:127.0.0.1 https://<DOMAIN>/status.json` と `--resolve x.<DOMAIN>:443:127.0.0.1 https://x.<DOMAIN>/` | 発行者が Cloudflare Origin の証明書、apex と任意の一段の名前の両方で（複数行の PEM が届いた証拠、V13） |
| P5 | 実ブラウザ（§8.5 の B1〜B14、Chrome、Firefox、Safari） | すべて |
| P6 | セッションの中（VPS で `docker exec -u 1000 ctplay-s-<h> …`）から §8.4 の E8 の各項目 | すべて失敗（外、メタデータ、ホスト、ゲートウェイ、別セッション） |
| P7 | 同じブラウザで 2 つ目を作る | 429 のページ（`CF-Connecting-IP` が届いている、V15）。`playctl status` に自分の IP |
| P8 | `curl -sI https://3000-<pid>.<DOMAIN>/` を 2 回 | `cf-cache-status` が `DYNAMIC` か `BYPASS` |
| P9 | エディタを 20 分放置 | 使えるまま、または自分で再接続する（V16） |
| P10 | 時間切れ: `PLAY_TTL=300` で出し直して 1 つ作る | 5 分で消え、ネットワークも残らない。元に戻す |
| P11 | 時間: ログの `ready_ms`、ワークベンチの表示まで、Ruby の編集から再起動まで、`docker stats` のメモリ | 記録する（V17）。再ビルドが 120 秒を超えたら、ガイド・入口・サイトの「about a minute」を実測に合わせて直す |
| P12 | 停止スイッチ: `pause` → 入口と作成、`resume`、テスト用セッションで `kill-all` | §5.9 のとおり |
| P13 | `kamal app logs -c …control.yml` を P5〜P12 で使った sid で検索 | 出ない。`kamal proxy logs` にはホスト名が出る（想定どおり、V14） |
| P14 | VPS を再起動 | ファイアウォールの規則が戻る、ルーターと制御面が戻る、照合で残りが消える |

### 7.8 更新とロールバック

- **制御面とセッションのイメージ**: main に入れる → CI が web のイメージを試験して `latest` を出す →
  `kamal deploy -c playground/deploy/control.yml`（ERB が新しいダイジェストを固定し、フックが pull する）。
  動いているセッションは元のイメージで最後まで動き、新しいセッションから新しいイメージになる。
- **ロールバック**: `kamal app containers -c …control.yml` で版を見て `kamal rollback <version> -c …control.yml`。
  古いダイジェストに戻る（post-deploy が 3 世代残す）。
- **ルーター**: できれば静かなときに。`playctl pause` → 生きているセッションが終わるのを待つ（最長 30 分、
  `playctl status` で 0）→ `kamal deploy -c playground/deploy/router.yml` → `playctl resume`。急ぐときはそのまま出す
  （エディタは数秒で再接続する。プレビューは再読み込みが要ることがある）。
- **code-server の版**: `CODE_SERVER_VERSION` とチェックサムを替える PR → CI → §8.5 の確認表 → 制御面の deploy。
- **証明書**: Origin CA を作り直したら、秘密を替えて `kamal deploy -c …router.yml`（kamal-proxy は証明書をデプロイ
  のときにだけ読む [ソース]）。

### 7.9 容量を変える

1 セッションの実際の山は約 1 GiB（§5.4）、ホストの取り分は約 2 GiB（OS、Docker、kamal-proxy、ルーター、制御面）。
目安は `PLAY_MAX_SESSIONS = (RAM の GiB − 2) を切り捨て、少し引く`、かつ `vCPU × 2` 以下（全員が同時に Ruby を保存
しても再ビルドが 2 倍程度に収まる）。

| VPS | 上限の目安 | 全員が同時に保存したときの再ビルド |
| --- | --- | --- |
| 8 GB / 4〜6 vCPU | 5 | 46 s × 5/4 ≈ 1 分（4 vCPU） |
| 12 GB / 6 vCPU | 8 | 46 s × 8/6 ≈ 1 分 |
| 16 GB / 8 vCPU | 12 | 46 s × 12/8 ≈ 70 s |
| 24 GB / 8 vCPU | 16 | 46 s × 16/8 ≈ 90 s |

（46 s は arm64 の計測。x86 では P11 の値で読み替える。）手順: プロバイダでプランを上げる（再起動を伴う）→
`control.yml` の `PLAY_MAX_SESSIONS` を変える → `kamal deploy -c …control.yml`。他は何も変えない。
ワークショップの日は `PLAY_MAX_SESSIONS_PER_IP` も上げる。

### 7.10 ログと監視

| 見るもの | どうやって |
| --- | --- |
| 制御面の出来事 | `kamal app logs -c …control.yml -f`（作成、終了と理由、拒否、Docker のエラー、`suspect`） |
| 生きているセッション | `kamal app exec -c …control.yml --reuse 'bin/playctl status'` |
| 公開の状態 | `https://<DOMAIN>/status.json` |
| ルーター | 普段はログなし。調べるときは `ROUTER_LOG_OUTPUT: stderr` を足して出し直し、`kamal app logs -c …router.yml` |
| kamal-proxy | `kamal proxy logs -c …router.yml`（ホスト名を含む。人に渡さない） |
| ホスト | `df -h`、`docker system df`、プロバイダのグラフ。週に 1 度 |
| 外形監視（任意） | `.github/workflows/playground-uptime.yml`: 30 分ごとに `status.json` を取り、失敗すると GitHub が失敗の通知メールを送る。リポジトリの変数 `PLAYGROUND_URL` を設定したときだけ動く |

警報の仕組み（メールの送信など）を VPS に置かない（本 spec での決定）: 1 人の運用で、外形監視と週 1 の確認で足りる。

### 7.11 不正利用の手順書

> §16.5 が優先: 攻撃時の WAF 規則は `/status.json` を除く（稼働監視が 30 分ごとに落ちる）。ルーターへの接続の洪水の行、`playctl kill-all` の待ち、ロールバックの注意が運用ガイドの第 7 部にある。

| 兆候 | すること |
| --- | --- |
| CPU を使い続けるセッション（`suspect` の行、`playctl status`） | `playctl status` でハンドルとアドレス → `playctl end <handle>`。繰り返すなら Cloudflare の Security → WAF → Tools の IP Access Rules でそのアドレスを Block |
| 多くのアドレスからの大量の作成 | WAF のカスタム規則（入口だけ Managed Challenge）を有効に、必要ならレート制限の規則も。まだ多ければ `playctl pause` |
| プレビューのホストのフィッシング・マルウェアの通報 | 30 分以内に消えているはず。`playctl status` で生きていれば `end`。分からなければ `kill-all`。通報者に返信。Safe Browsing に載ったら Search Console で再審査を依頼 |
| Cloudflare からの不正利用の通知 | 上と同じ。ダッシュボードで返答 |
| 脱出・侵害の疑い | `playctl kill-all` → 両サービスを `kamal app stop` → プロバイダのスナップショットで保全 → VPS を作り直す → 秘密を替える（GHCR の PAT、Origin CA は失効して作り直す）→ SECURITY.md の窓口で記録 |
| ディスクが埋まる | `docker system df`、古いセッションのイメージを消す（post-deploy と同じコマンド）、ログの大きさ |

停止スイッチのコマンドは §5.9。制御面が動かないときは同じ節の生の Docker コマンド。

### 7.12 gVisor の計測と切り替え

> §16.5 が優先: イメージに `/usr/bin/time` は無い。bash の `time` で測る（手元の runc は 39.9 s）。目標は同じ VPS の runc の値の 1.5 倍以内。

1. VPS で: gVisor の apt リポジトリを足して `apt-get install runsc`、`sudo runsc install`、
   `sudo systemctl reload docker`（再起動ではないので動いているコンテナは止まらない [文書]）。
2. 計測（同じイメージ、同じ制限で runc と runsc を比べる）:
   `docker run --rm --cpus 1 --memory 1536m [--runtime runsc] --entrypoint bash <session image> -lc 'cd /workspace/blog && touch app/controllers/articles_controller.rb && /usr/bin/time -v cybertrain spin build blog'`、
   code-server の起動から `/healthz` まで、エディタ接続中のメモリ。
3. 互換性: §8.3 の web スモークを `PLAY_RUNTIME=runsc` 相当で走らせる（`web-smoke.sh` に `RUNTIME` 変数）。
4. 判断の目安: 再ビルドが runc の 1.5 倍以内（約 70 s）で、スモークがすべて通れば `PLAY_RUNTIME: runsc` にして
   制御面を出し直す。新しいセッションから gVisor になる。ルーターは runc のまま（後からネットワークを足すのは
   ルーターだけで、セッションのネットワークは作成時に 1 つ与える）。
5. 結果を運用ガイドに書く。採らない場合も数字と理由を残す（R2 の受け入れの根拠になる）。

## 8. ローカル開発とテスト

### 8.1 手元で全体を動かす

`playground/dev/compose.yml`（全文）:

```yaml
# playground/dev/compose.yml -- the whole hosted playground on this machine,
# without Cloudflare or Kamal, at http://play.localhost:8080 (browsers resolve
# *.localhost to this machine). Build the session image first:
#   docker build -f playground/Dockerfile --target web -t cybertrain-playground-web:local .
#   docker compose -f playground/dev/compose.yml up --build
name: ${PLAY_PROJECT:-ctplay-dev}
services:
  router:
    build:
      context: ../..
      dockerfile: playground/router/Dockerfile
    environment:
      PLAY_DOMAIN: play.localhost
      PLAY_PUBLIC_URL: http://play.localhost:${PLAY_PORT:-8080}
      PLAY_SUBNET_POOL: ${PLAY_SUBNET_POOL:-10.250.0.0/16}
      ROUTER_LOG_OUTPUT: stderr
    ports:
      - "127.0.0.1:${PLAY_PORT:-8080}:80"
    networks:
      default:
        aliases: [ctplay-router]
  control:
    build:
      context: ../..
      dockerfile: playground/control/Dockerfile
    environment:
      PLAY_PUBLIC_URL: http://play.localhost:${PLAY_PORT:-8080}
      PLAY_SESSION_IMAGE: ${PLAY_SESSION_IMAGE:-cybertrain-playground-web:local}
      PLAY_ROUTER_URL: http://ctplay-router
      PLAY_ROUTER_FILTERS: label=com.docker.compose.project=${PLAY_PROJECT:-ctplay-dev},label=com.docker.compose.service=router
      PLAY_CLIENT_IP_HEADER: CF-Connecting-IP
      PLAY_MAX_SESSIONS: ${PLAY_MAX_SESSIONS:-3}
      PLAY_MAX_SESSIONS_PER_IP: ${PLAY_MAX_SESSIONS_PER_IP:-1}
      PLAY_CREATE_LIMIT: ${PLAY_CREATE_LIMIT:-3}
      PLAY_TTL: ${PLAY_TTL:-1800}
      PLAY_SUBNET_POOL: ${PLAY_SUBNET_POOL:-10.250.0.0/16}
      PLAY_ABUSE_CONTACT: abuse@playground.invalid
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - ./data:/data
    networks:
      default:
        aliases: [ctplay-control]
```

使い方（playground/README.md に書く）:

```sh
docker build -f playground/Dockerfile --target web -t cybertrain-playground-web:local .
bash playground/web-smoke.sh cybertrain-playground-web:local      # §8.3
docker compose -f playground/dev/compose.yml up --build -d
# Chrome か Firefox で http://play.localhost:8080/ → Start a session
bash playground/dev/e2e.sh                                          # §8.4（自分で別の project を上げ下げする）
docker compose -f playground/dev/compose.yml down
(cd playground/control && bundle install && bundle exec rake test)  # §8.2
```

- ブラウザは `*.localhost` を 127.0.0.1 に解決する（Chromium、Firefox [計測: スパイク]。Safari は [未検証]）。
  `play.localhost` は登録可能ドメインとして振る舞うので、エディタとプレビューは同一サイト（スパイクの配置 (iii) [計測]）。
- ブラウザからの要求には `CF-Connecting-IP` が無いので、手元の全要求は 1 つのクライアント（ルーターのアドレス）に
  なる。E2E はこのヘッダを付けて別々のクライアントを装う。
- プールの `10.250.0.0/16` が社内 VPN などと重なる開発者は `PLAY_SUBNET_POOL` で変える。
- Docker Desktop（Mac）でも Linux の VM の中で同じく動く。ホストの到達性の検査は VM が相手になる。

### 8.2 制御面の単体テスト（minitest、`playground/control/test/`）

偽物（`test/fakes.rb`）:

| 偽物 | 代わりにするもの | 振る舞い |
| --- | --- | --- |
| `FakeDocker` | `Play::DockerCLI#run(argv, timeout:)` | argv の先頭の語で台本の応答（成功と出力、"Pool overlaps"、"No such container"、"No such network"、"No such image"、"has active endpoints"、時間切れの例外）を返し、呼び出しを順に記録する |
| `FakeProbe` | 準備確認 | N 回目に準備完了、または永遠に未完了 |
| `FakeClock` | 壁時計、単調時計、`sleep` | 値を進められる |
| 一時ディレクトリ | `PLAY_DATA_DIR` | 本物の `flock`、`paused`、`kill-all` |
| `StringIO` | ロガー | 内容を検査する |

項目:

- `templates_test.rb`: ネットワークの作成、接続、起動、片付け、一覧の argv が §5.4 と完全に一致する。起動の argv に
  硬化のフラグがすべてあり、禁止のもの（`--privileged`、`--cap-add`、`-v`、`--mount`、`-p`、`--network host`、
  `--pid`、`--ipc`、`--device`、`seccomp=unconfined`、`--restart`）が無い。`--runtime` は設定したときだけ。
  数値は設定から来る。
- `sessions_test.rb`:
  - 作成の成功: 呼び出しの順（ロック → 一覧 → ネットワーク作成 → ルーター一覧 → 接続 → 起動 → 準備確認）、
    sid と pid が 32 桁の小文字 16 進で互いに違う、ハンドルが `SHA-256(sid)` の先頭 16 桁、エディタの URL の形。
  - 拒否: 停止中、満員（`creating` を数える）、同じクライアントの同時数（IPv6 の /64 で同じ扱い）、作成回数の窓
    （時計を進めると空く）。拒否のとき Docker を 1 回も呼ばない（一覧を除く）。
  - 失敗の片付け: 作成の各段の失敗と準備の時間切れで、そのハンドルのコンテナもネットワークも残らない
    （偽物の記録で片付けの呼び出しを確かめる）。"Pool overlaps" で次の範囲を試し、3 回で諦める。
  - 刈り取り: 期限切れ、止まったコンテナ、60 秒より古い孤児のネットワーク（若いものは残す）、つながっていない
    ルーターの接続、再起動の後の記録の作り直し（`client: nil`）、`kill-all` のファイル、CPU 90 % が 10 回で `suspect`。
  - 片付けは冪等（「無い」は成功）。
  - どのログにも sid と pid が出ない（作成、Docker のエラー、片付けの後で `StringIO` を検索）。
- `subnets_test.rb`: 一番小さい空き、使用中と「使えない」を飛ばす、尽きたとき、プールの検証（Docker の既定と重なる、
  接頭辞の範囲）。
- `limits_test.rb`: 窓のすべり、IPv4 の鍵、IPv6 の /64 の鍵、壊れたヘッダは `REMOTE_ADDR` に戻る。
- `config_test.rb`: 必須、数値、`PLAY_IDLE_TIMEOUT` ≤ 60 の拒否、`PLAY_PUBLIC_URL` からスキーム・ドメイン・ポート、
  `PLAY_ALLOWED_ORIGINS` の既定。
- `app_test.rb`（rack-test、`Play::Sessions` は偽物）: 入口の空きの表示、`POST /sessions` の 303 と URL の形
  （payload のエンコードと権限部のポート）、他のオリジン 403、`Sec-Fetch-Site: same-site` 403、`Origin` も
  `Sec-Fetch-Site` も無ければ通す、503 と 429 のページと `Retry-After`、`/status.json` の形、`/up` が刈り取りの
  心拍で 200 / 503、`/internal/sessions` は 127.0.0.1 だけ、セキュリティヘッダ、他のホスト名を拒む。
- `playctl_test.rb`: `pause` / `resume` がファイルを書く・消す、`end` と `kill-all` が偽物の Docker で片付ける。
- `drift_test.rb`: `playground/web-smoke.sh` の `# BEGIN hardened run` 〜 `# END hardened run` の間のフラグが
  `Play::Templates` の起動の硬化フラグ（名前、ラベル、環境変数を除く）と同じ。スモークと本番の型がずれない。

### 8.3 web イメージのスモークテスト `playground/web-smoke.sh IMAGE`

SP1 の `smoke.sh` と同じ流儀（bash 3.2、`PASS`/`FAIL` の 1 行、最後に要約、失敗したコンテナのログの末尾、
`trap` で片付け）。テスト用の `--internal` ネットワークを作り、セッションは §5.4 の硬化フラグ（`# BEGIN hardened run`
の区画）で起動し、同じネットワークの補助コンテナ（同じイメージを `--entrypoint curl` で）から HTTP を当てる。
環境変数 `RUNTIME` で `--runtime` を足せる（gVisor の計測、§7.12）。

| ID | 検査 | 上限 |
| --- | --- | --- |
| W1 | `code-server --version` の 1 語目が 4.139.1 | 30 s |
| W2 | ユーザー dev（uid 1000）、`cybertrain version`、環境に `CYBERTRAIN_HOST=0.0.0.0` と `EXTENSIONS_GALLERY={}` | 30 s |
| W3 | ブログ: 作業ツリーがクリーン、コミット 1 つ、`PLAYGROUND.md` が web 版（"ends at the time the terminal shows" を含む）、`.vscode/tasks.json` があり `git check-ignore` で無視される、tasks.json に `"runOn": "folderOpen"` | 30 s |
| W4 | 種と元が同じ: `diff -r` が空、`build/bin/blog` の mtime が同じ | 30 s |
| W5 | 硬化した起動で code-server の `/healthz` が補助コンテナから 200（起動にかかった秒を出す） | 30 s |
| W6 | 起動で何もコンパイルしていない: tmpfs の `build/bin/blog` の mtime がイメージと同じ | W5 の後 |
| W7 | ユーザー設定が入っている（`task.allowAutomaticTasks` が `on`） | W5 の後 |
| W8 | タスクの代わりに `docker exec -u 1000 C bash -lc 'playground-server > /tmp/s.log 2>&1 &'` → `GET /articles` が 200、バナーに `App    https://3000-<pid>.example.test/` と `Ends` の行 | 30 s |
| W9 | 読み取り専用のルートでモデルの編集が再ビルドされ、短い本文の POST が 422（SP1 の A9 と同じ手順） | 300 s |
| W10 | ネットワークなしで新しいアプリ: `cd /workspace && cybertrain new shop && cd shop && cybertrain spin build shop` が 0（tmpfs の外に書かない証拠、V5） | 420 s |
| W11 | 読み取り専用と権限: `touch /usr/local/bin/x` が失敗、`CapEff` 0、`NoNewPrivs` 1、`df` に 4 つの tmpfs の大きさ | 30 s |
| W12 | 自滅: `PLAYGROUND_ENDS_AT=now+5` のコンテナが 90 秒以内に消える（`--rm`、V8） | 90 s |
| W13 | アイドル終了: `PLAYGROUND_IDLE_TIMEOUT=61` でクライアントなしのコンテナが 240 秒以内に消える（V7。他と並行に走らせる） | 240 s |

所要の目安: コンパイル 2 回（W9、W10）と W13 の待ちで CI 5〜8 分 [推論]。

### 8.4 全体の E2E `playground/dev/e2e.sh`

compose の別プロジェクト（`PLAY_PROJECT=ctplay-e2e`、`PLAY_PORT=18080`）を
`PLAY_TTL=150 PLAY_MAX_SESSIONS=2 PLAY_CREATE_LIMIT=2` で上げ、終わったら消す。要求は
`curl -H 'Host: …play.localhost:18080' http://127.0.0.1:18080/…`、クライアントは `CF-Connecting-IP` で装う。
コンテナの中の検査は `docker exec -u 1000`。sid は 303 の Location から、pid は
`docker exec … printenv VSCODE_PROXY_URI` から得る。

| ID | 検査 |
| --- | --- |
| E1 | 入口が 200 で "2 of 2 sessions are free."、`/status.json` が `live: 0` |
| E2 | `POST /sessions`（Origin は入口、クライアント 198.51.100.1）が 30 秒以内に 303、Location が `^http://[0-9a-f]{32}\.play\.localhost:18080/\?folder=%2Fworkspace%2Fblog&payload=`（時間を出す） |
| E3 | エディタが 200 で `vscode-workbench-web-configuration` を含み、`Referrer-Policy: no-referrer`、`X-Robots-Tag: noindex, nofollow`、`frame-ancestors 'self'` |
| E4 | エディタへの WebSocket の握手: 正しい Origin で 101、`Origin: http://evil.localhost:18080` で 403（code-server の検査がルーター越しでも生きている） |
| E5 | タスクの代わりにサーバーを起動 → プレビュー `/articles` が 200、`no-store`、`noindex`、`frame-ancestors *.play.localhost:*`。バナーに `App    http://3000-<pid>.play.localhost:18080/` |
| E6 | プレビューのホストでフォーム: トークンと Cookie（`SameSite=Lax`、`Secure` なし）で POST が 303 `Location: /articles/<id>`、その GET が 200 で題名を含む |
| E7 | 別々の乱数: `3000-<sid>` は 502 の「No app is answering」、`<pid>` だけのホストは 404 |
| E8 | セッションの中から: `curl https://example.com` 失敗、`getent hosts example.com` 失敗（DNS も外へ出ない、V4）、`curl http://1.1.1.1` 失敗、`169.254.169.254` 失敗、ネットワークのゲートウェイのアドレスの 22/80/443/2375 失敗、ルーターのそのネットワーク上のアドレスに `Host: play.localhost` で接続が切られる（V20）、別セッションのアドレスの 8080/3000 失敗、`getent hosts ctplay-control` 失敗 |
| E9 | セッションの中: uid 1000、`CapEff` 0、`NoNewPrivs` 1、ルートに書けない、`/workspace` に書ける、`memory.max` 1610612736、`pids.max` 512、`cpu.max` `100000 100000`、`/var/run/docker.sock` が無い |
| E10 | 上限: 2 つ目のクライアントで 303、3 つ目で 503 の "All sessions are in use"。Docker のセッションのコンテナとネットワークがちょうど 2 つ |
| E11 | 同じクライアント: 198.51.100.1 でもう一度 → 429 と `Retry-After`。回数: 別のクライアントで作成 → `playctl end` → 作成 → `end` → 3 回目が 429 |
| E12 | オリジン: `Origin: http://evil.localhost` で 403、Origin なしで `Sec-Fetch-Site: same-site` も 403 |
| E13 | 不明なホスト: 乱数 32 桁 → 404 のページ、`foo.play.localhost` → 404、入口の `/internal/sessions` をルーター越しに → 404 |
| E14 | 制御面の再起動: `docker restart` の後 10 秒以内に `live: 2`、エディタが答え続ける |
| E15 | ルーターの作り直し（`--force-recreate router`）: 10 秒以内にエディタがまた答える（つなぎ直し） |
| E16 | 停止スイッチ: `playctl pause` で入口が停止の表示、POST が 503。`resume` で 303。`kill-all` でセッション 0、ネットワークも 0 |
| E17 | 失敗は何も残さない: ルーターを止めて POST → 503、Docker の数が変わらない。ルーターを戻す |
| E18 | 時間切れ: 作成から約 150〜160 秒でエディタが 404 のページ、ラベル付きのコンテナもネットワークも残らない |
| E19 | ログ: 制御面の `docker logs` に E2〜E18 の sid と pid がどれも無い |

所要の目安: 時間切れの待ちで 4〜6 分 [推論]。

### 8.5 実ブラウザで確かめること

まずローカル（`play.localhost`、Chrome と Firefox）、次に本番のドメイン（加えて Safari）。スパイクの
`browser-tests/`（Playwright）を下敷きに `playground/dev/browser-check.js` を作ってもよい（任意、CI では回さない）。
手で行う確認表が正。

| # | 確かめること | 期待 |
| --- | --- | --- |
| B1 | 入口 → Start | エディタに描画済みの `PLAYGROUND.md`（V9）、端末にバナーと `Listening`、10 秒以内に手を触れずにプレビューが記事一覧（V1） |
| B2 | プレビューで記事を作る | 303 → 詳細ページ（本物の webview の枠の中で Lax の Cookie が往復） |
| B3 | ビューの編集と再読み込み、モデルの編集 | ビューは即、モデルは再ビルドの後で短い本文が 422 |
| B4 | ページの再読み込み | サーバーは 1 つ、"Select an instance" の確認なし、端末とプレビューが戻る |
| B5 | 最初の表示 | Welcome、Chat のサイドバー、信頼の確認、自動タスクの確認、Coder の宣伝がどれも出ない |
| B6 | 枠のヘッダ | Markdown のプレビューと Simple Browser が描画される（V11） |
| B7 | 拡張機能のビュー | ギャラリーなし、DevTools のネットワークに `open-vsx.org` が無い（V10） |
| B8 | `.html.erb` | 言語が HTML、Emmet が効く |
| B9 | Ports ビュー | 3000 が正しい URL で出る。Open in Browser で通常のタブに開き、そこでは `confirm()` が動く |
| B10 | 終わりの予告と時間切れ（ローカルで `PLAY_TTL=420`） | 5 分前に黄色の行（V19）、時間切れで再接続の表示 → 再読み込みで 404 のページ |
| B11 | タブを閉じる | 約 6 分で `status.json` の `live` が減る |
| B12 | エクスプローラ | フォルダの Download が動く。ドラッグでのアップロードは拒まれる |
| B13 | Firefox、Safari（Safari は本番のドメインで） | B1〜B4 |
| B14 | 本番で 20 分放置（V16） | 使えるまま、または自分で再接続 |

### 8.6 実機（VPS とドメイン）でしか確かめられないこと

- Cloudflare: プロキシしたワイルドカードと Universal SSL、Full (strict) と Origin CA、キャッシュの迂回、
  `CF-Connecting-IP` が kamal-proxy と Caddy を素通りすること（V15）、WebSocket のアイドル切断と再接続（V16）。
- Kamal: `"*.<DOMAIN>"` の受け入れ、複数行の PEM の秘密、1 台のサーバーという条件、`hooks_path`、
  `proxy: false` の役割と `network-alias`、制御面の入れ替えの重なり（V13、V23）。
- ファイアウォールが本当に直接の接続を落とすこと（P3）、再起動の後に戻ること（P14）、プロバイダのメタデータと IPv6。
- x86 の vCPU での作成時間、再ビルド時間、エディタ接続中のメモリ（V17）。gVisor（V18）。
- Safari とスマートフォンでの本物の HTTPS、東京からの体感。
- kamal-proxy のログの中身と保持（V14）。

### 8.7 CI

| ワークフロー | 変更 | 中身 |
| --- | --- | --- |
| `.github/workflows/playground-image.yml` | 変更 | 新しいジョブ `web`（既存の `image` ジョブはそのまま）: `target: web`（linux/amd64、同じ GHA キャッシュ）→ `bash playground/web-smoke.sh cybertrain-playground-web:ci` → ルーターと制御面のイメージを手元で作り `PLAY_SESSION_IMAGE=cybertrain-playground-web:ci bash playground/dev/e2e.sh` → PR 以外で `ghcr.io/saeki-mototsune/cybertrain-playground-web` に押す（main から `latest`、タグ `vX.Y.Z` から `X.Y.Z` と `latest`、手動は指定のタグ。SP1 と同じ規則）。パスのフィルタは既存の `playground/**` で足りる |
| `.github/workflows/playground-control.yml` | 新規 | `playground/control/**` に触れる PR と push で、ruby/setup-ruby（4.0）+ `bundle exec rake test` |
| `.github/workflows/playground-uptime.yml` | 新規（任意で有効） | 30 分ごと、`vars.PLAYGROUND_URL` が空でなければ `curl -fsS --max-time 20 "$PLAYGROUND_URL/status.json"` |

## 9. サイトと文書

### 9.1 サイトの入口（公開のコミット、本 spec での決定）

サイトは静的でビルドが無いので、「設定値」は別のコミットにする: plan の最後のタスクとして入口の差分を用意し、
§7.7 が通ってオーナーが公開を決めてからマージする。それまでサイトにも README にも、まだ無いものへのリンクを
置かない（SP1 §2 と同じ規則）。サイトの内容規則に従い、同じコミットで README にも同じ事実を書く（§9.2）。

`site/playground.html` の変更:

1. `<main>` の目次の先頭に `<li><a href="#hosted"><span class="toc-n">01</span>Start a session</a></li>` を足し、
   以降の番号を 1 つずつ送る（02 Open a codespace … 05 Run it with Docker）。
2. ヒーロー: `doc-intro` を "The blog from the tutorial, already created, scaffolded and migrated, opens in VS Code in
   your browser, with its development server running in a terminal and the app in the editor's preview: on our
   playground server with no account, or in a GitHub Codespace." に、`doc-meta` の "You need" を
   "Nothing but a browser (or a GitHub account for Codespaces)"、"It runs on" を
   "Our playground server for 30 minutes, or your own Codespaces quota" にする。`<meta name="description">` と
   `og:description` も同じ趣旨に。
3. 新しい節（`#open` の前、全文）:

```html
  <section class="step" id="hosted" aria-labelledby="h-hosted">
    <p class="stage"><span class="stage-k">You are here<span class="sr-only">:</span></span>No account <span aria-hidden="true">&middot;</span> 30 minutes</p>
    <h2 id="h-hosted"><span class="step-num" aria-hidden="true">01</span>Start a session</h2>
    <p class="why"><span class="why-k">Why</span><span class="why-t">The quickest way in: VS Code opens in your browser on our playground server, with nothing to sign in to.</span></p>
    <form class="cta-row" method="post" action="https://<DOMAIN>/sessions">
      <button class="btn btn-primary" type="submit">Start a session<span class="btn-arrow" aria-hidden="true">&rarr;</span></button>
      <a class="btn btn-ghost" href="https://<DOMAIN>/terms" rel="noopener">Terms and privacy</a>
    </form>
    <p class="note">A session ends 30 minutes after it starts and is deleted with everything in it: download any file you want to keep. It has no network access. A few sessions run at a time, one per network address; when they are all in use, try again in a few minutes or open a codespace instead. Anyone with a session's address can use it, terminal included, so do not share it.</p>
  </section>
```

4. 既存の `#open` の節: 見出しを "Or open a codespace" に、`stage` の行は新しい節に移ったので消す。
5. `site/assets/style.css` に 1 規則: `button.btn { font: inherit; border: 0; cursor: pointer; }`（ボタンを `<a>` の
   `.btn` と同じ見た目にする。新しい色は足さない。BRAND.md の規則どおり）。
6. ボタンは同一オリジンの検査を通る: 制御面の `PLAY_ALLOWED_ORIGINS` にサイトのオリジン
   `https://saeki-mototsune.github.io` が入っている（§7.3）。押すとそのままエディタに着く（1 回の押下）。
   満員なら制御面の 503 のページ（Codespaces の案内付き）。

`index.html` のヒーローのボタン "Try it in your browser" と `tutorial.html` のヒントは変えない（行き先の
`playground.html` が両方の道を示す）。

### 9.2 README の「Try it in the browser」（公開のコミットで、節の先頭に足す全文）

```markdown
**No account needed:** [start a session on the hosted playground](https://<DOMAIN>/).
VS Code opens in your browser on the same blog, with the development server
running and the app in the editor's preview. A session ends 30 minutes after it
starts and is deleted with everything in it (download what you want to keep); it
has no network access; a few sessions run at a time, one per network address.
Anyone with a session's address can use it, so do not share it.
```

続く既存の段落の書き出しを "Or [open the playground in GitHub Codespaces](…)" にする。README の他の節は変えない。

### 9.3 `playground/README.md`（英語）に足すもの

- "What is inside" の表の後に節 **"The web stage (hosted playground)"**: `--target web` で何が足されるか
  （code-server 4.139.1、`/opt/cybertrain-web/`、ブログの `.vscode/tasks.json` と web 版の `PLAYGROUND.md`、種、
  `CYBERTRAIN_HOST=0.0.0.0`、`EXTENSIONS_GALLERY={}`）、§4.9 の `docker run` の約束、手で動かす最小形。
- 節 **"The hosted playground"**: 3 つの部品（`playground/router/`、`playground/control/`、web イメージ）、
  ホスト名、手元での動かし方（§8.1）、テスト（§8.2〜§8.4）、運用は `playground/deploy/README.md`（日本語）。
- "Smoke test" の節に `web-smoke.sh` の項目の表（W1〜W13）。
- "Limitations" に: 2 つのガイド（`playground/PLAYGROUND.md` と `playground/web/PLAYGROUND.md`）の共通部分は同じ
  文面に保つこと。

### 9.4 運用ガイド `playground/deploy/README.md`（日本語、docs/deploy.md と同じ書き方）

上から順にコピペで進められる手順書にする。構成:

1. 構成図（§3.2 を簡略に）と「この文書で使う名前」の表（`<DOMAIN>`、`<VPS_IP>`、`<GHCR_OWNER>`、`<ABUSE_EMAIL>`）。
2. 第 1 部 用意するもの: ドメイン、Cloudflare、VPS（§7.6 の 3 の選び方）、GitHub の PAT、手元の Kamal。
3. 第 2 部 VPS: ユーザーと SSH、ufw、Docker と `daemon.json`、ファイアウォールのスクリプトとユニット（全文を
   `playground/deploy/host/` から写す手順）、データのディレクトリ。
4. 第 3 部 Cloudflare: §6.4 の表を画面の操作の順に。Origin CA の保存と期限の暦。
5. 第 4 部 Kamal: 秘密、2 つの設定ファイル、`kamal proxy boot_config set --log-max-size=1m`、`setup` の順序。
6. 第 5 部 公開前の確認: §7.7 の P1〜P14 と §8.5 の確認表。結果の記録欄（作成時間、再ビルド時間、メモリ、
   gVisor の数字）。
7. 第 6 部 日々の運用: §7.8〜§7.10（更新、ロールバック、ルーターの出し方、容量、ログ、監視、イメージの掃除、
   証明書の期限）。
8. 第 7 部 緊急停止と不正利用: §5.9 と §7.11。生きているログ（kamal-proxy）を人に渡さない注意。
9. 第 8 部 gVisor: §7.12。
10. トラブルシューティング: エディタが「Cannot reconnect」（ルーターの接続、`docker network inspect`）、プレビューが
    開かない（V1 の代替）、作成が 503（`kamal app logs` の `docker_error`）、Cloudflare の 52x。

### 9.5 `SECURITY.md`（新規、リポジトリの最上位、英語）

- 報告は GitHub の Private Vulnerability Reporting で（公開の Issue にしない）。オーナーがリポジトリの設定で有効にする。
- 範囲: フレームワーク、CLI、playground のイメージ、ホスト型プレイグラウンド（`<DOMAIN>`）。特に歓迎するもの:
  セッションからの脱出、他のセッションへの到達、セッションからホスト・制御面・メタデータへの到達、上限の回避、
  能力 URL の漏れ。
- 範囲外: 自分のセッションの中で任意のコードが動くこと（設計どおり）、量による負荷、Cloudflare の挙動。
- 初回の返答の目安（7 日）と、修正の公開まで詳細を伏せるお願い（spinel scope と同じ）。

## 10. 変更対象

| 区分 | ファイル | 内容 |
| --- | --- | --- |
| 変更 | `playground/Dockerfile` | 最後に `web` ステージ（§4.1） |
| 変更 | `playground/playground-server` | `VSCODE_PROXY_URI` からのアプリの URL、`Ends` の行（§4.7） |
| 変更 | `playground/README.md` | web ステージ、ホスト型、手元での動かし方、web スモークの表、2 つのガイドの規則（§9.3） |
| 新規 | `playground/web/playground-web` | セッションのエントリポイント（§4.6） |
| 新規 | `playground/web/settings.json` | code-server のユーザー設定（§4.4） |
| 新規 | `playground/web/tasks.json` | folderOpen のタスク（§4.5） |
| 新規 | `playground/web/PLAYGROUND.md` | SP2 のガイド（§4.8） |
| 新規 | `playground/web-smoke.sh` | web イメージのスモーク（§8.3） |
| 新規 | `playground/router/Dockerfile`、`Dockerfile.dockerignore`、`Caddyfile`、`pages/{ended,app-down,unavailable}.html` | ルーター（§6.1） |
| 新規 | `playground/control/`（`Dockerfile`、`Dockerfile.dockerignore`、`Gemfile`、`Gemfile.lock`、`Rakefile`、`config.ru`、`lib/play.rb`、`lib/play/*.rb`、`views/*.erb`、`bin/playctl`、`test/*`） | 制御面（§5、§8.2） |
| 新規 | `playground/deploy/README.md` | 日本語の運用ガイド（§9.4） |
| 新規 | `playground/deploy/router.yml.example`、`control.yml.example` | Kamal（§7.2、§7.3） |
| 新規 | `playground/deploy/session-image`、`hooks/pre-deploy`、`hooks/post-deploy` | イメージの固定と pull と掃除（§7.4） |
| 新規 | `playground/deploy/host/cybertrain-play-firewall`、`cybertrain-play-firewall.service`、`daemon.json.example` | ホストの設定（§7.5） |
| 新規 | `playground/dev/compose.yml`、`playground/dev/e2e.sh`（任意で `browser-check.js`） | 手元の全体と E2E（§8.1、§8.4、§8.5） |
| 新規 | `.kamal/secrets` | 参照だけの秘密の定義（§7.4） |
| 変更 | `.gitignore` | 運用者の設定、`.session-image`、`playground/dev/data/`（§7.4） |
| 変更 | `.github/workflows/playground-image.yml` | `web` ジョブ（§8.7） |
| 新規 | `.github/workflows/playground-control.yml`、`playground-uptime.yml` | 単体テスト、任意の外形監視（§8.7） |
| 新規 | `SECURITY.md` | 報告の窓口と範囲（§9.5） |
| 公開のコミットで変更 | `site/playground.html`、`site/assets/style.css`、`README.md` | 入口（§9.1、§9.2） |

変えないもの: `cybertrain/`（フレームワーク）、`.devcontainer/`、`playground/smoke.sh`、`playground/PLAYGROUND.md`、
`playground/profile.sh`、`playground/Dockerfile.dockerignore`、`site/index.html`、`site/tutorial.html`、`ci.yml`、`pages.yml`。

## 11. オーナーの手作業と質問

### 11.1 手作業

1. 本書の承認と §11.2 への回答。
2. ドメインを買い、Cloudflare のゾーンにして、ネームサーバーを替える（§7.6 の 1〜2）。
3. VPS を契約する（§7.6 の 3、§11.2 の Q2）。
4. 窓口のメールアドレスを決める（受け取れるもの）。
5. 利用条件とプライバシーの文面（§5.13）を承認する。
6. GitHub: Kamal 用の PAT、CI が初めて出した `cybertrain-playground-web` を Public にしてリポジトリに結び付ける、
   Private Vulnerability Reporting を有効にする。
7. §7.6 の 4〜16（または、オーナーの SSH エージェントでオーケストレーターが進める）。秘密（PAT、Origin CA の鍵）は
   オーナーの手元に置き、チャットに貼らない。
8. §7.7 と §8.5 の実機確認（オーナー自身、またはオーナーがサインインしたブラウザをオーケストレーターが操作）。
9. gVisor の計測の結果で `PLAY_RUNTIME` を決める（§7.12）。
10. 公開のコミット（§9.1、§9.2）をマージする。
11. 任意: Search Console、外形監視の変数 `PLAYGROUND_URL`、必要になったら Cloudflare の WAF とレート制限の規則。
12. 暦: Origin CA の期限、code-server と Caddy とベースイメージの版上げ（月に 1 度を目安に確かめる）、
    Cloudflare の IP 範囲の見直し（まれ）。

### 11.2 オーナーへの質問（回答が要るものだけ）

2026-10-02 の承認の時点の扱い: Q2〜Q6 は本書の既定（12 GB / 6 vCPU 級を推奨し 8 GB 級でも動く、初日は硬化した
runc で gVisor は VPS での計測の後に決める、30 分・§7.9 の上限・10 分に 3 回・約 6 分のアイドル終了、
アドレスごとに 1 つ、SP2 では制御面がソケットを持つ）で進める。どれも設定値か後の作業で変えられる。
Q1（ドメインと窓口のメールアドレス）と Q7（利用条件の文面）はデプロイの前にオーナーが決める。実装とローカルの
検証はどちらにも依らない（`<DOMAIN>` と窓口は設定値）。

- **Q1 ドメインと窓口**: どのドメインを買うか（Public Suffix List に載っていないこと）、入口と `security.txt` に出す
  メールアドレス。
- **Q2 VPS**: 推奨は 12 GB / 6 vCPU 級（同時 8、ConoHa で約 ¥7,348/月）。8 GB 級（同時 5、さくらで ¥7,920/月）でもよいか。
- **Q3 gVisor**: 初日は硬化した runc で公開し、最初の週の計測で gVisor に切り替えるかを決める（それまでカーネルの
  脆弱性による脱出の危険 R2 を受け入れる）でよいか。計測の前に公開しない、という選択もある。
- **Q4 既定値**: 30 分、上限は §7.9 の表、作成は 1 アドレス 10 分に 3 回、タブを閉じて約 6 分で終了、でよいか。
- **Q5 アドレスごとに 1 つ**: NAT の向こう（学校、会社、携帯）では 2 人目から断られる。既定 1 でよいか（ワークショップの
  日は設定で上げる）。
- **Q6 Docker のソケット**: SP2 では制御面がソケットを直接持ち、ソケットを持つ小さなオーケストレーターへの分離は
  SP3 の前に行う（§3.5 (d)）。この順序でよいか、SP2 から分離するか（プロセス 1 つと内部 API が増える）。
- **Q7 利用条件**: §5.13 の文面でよいか（法的な約束になる）。

## 12. リスクと未確定事項

### 12.1 未検証で、plan が最初に確かめるもの

手元で確かめられるもの（plan の最初のタスク群。スモーク、E2E、ローカルのブラウザで）:

| # | 何 | 確かめ方 | 駄目なときの代わり |
| --- | --- | --- | --- |
| V1 | `--proxy-domain` なし・`--disable-proxy` ありで、`VSCODE_PROXY_URI` だけで openPreview と Ports ビューが外向きの URL を開く | B1、B9 | `--disable-proxy` を外し `--proxy-domain '{{port}}-<pid>.<domain>'` を足す（§3.5 (b)） |
| V2 | Caddy の `header_regexp` の捕獲を上流とヘッダの値に使える、Docker の DNS でネットワーク別名が引ける | E3、E5 | `expression`（CEL）の一致に書き換える。それも駄目ならルーターを nginx にする。スパイクで動いた形 [計測]: `server_name` の正規表現で id を捕獲し、`resolver 127.0.0.11 valid=5s;`、`set $upstream <別名の接頭辞>$sid; proxy_pass http://$upstream:8080;`、`proxy_http_version 1.1;`、`proxy_set_header Host $http_host;`、`Upgrade` と `Connection` の転送、`proxy_read_timeout 3600s;` |
| V3 | `--internal` と `inhibit_ipv4=true` の併用、そのうえでルーターとセッションが話せる | E3、E8 | オプションを外し、ファイアウォール（§7.5）だけで守る |
| V4 | セッションの中で外の名前が引けない（内部ネットワークの内蔵 DNS が外へ転送しない） | E8 | `--dns 127.0.0.1`（転送先を誰もいない所へ）を足して再試験 |
| V5 | 読み取り専用のルートと 4 つの tmpfs で code-server、タスク、再ビルド、新しいアプリが動く（`/opt/cybertrain` などに書かない） | W5、W8〜W10 | 書く場所を調べて tmpfs か種の写しを足す |
| V6 | 種を `cp -a` した tmpfs のブログとキャッシュが新しいまま（起動でコンパイルしない） | W6 | `tar` で写す。駄目なら spin の判定を調べる |
| V7 | クライアントが一度も来ないとき code-server のアイドル終了が起動から数える。`/healthz` が心拍を動かさない | W13 | 制御面が「作成から N 分クライアントなし」を自分で判定する（code-server の `/healthz` の `lastHeartbeat` を見る） |
| V8 | `timeout` + `--init` + `--rm` でコンテナが自分で消える | W12 | 制御面だけに頼る（M2 は刈り取りで満たす）と明記する |
| V9 | ユーザー設定の `remote.portsAttributes` が効く、`workbench.editorAssociations` で `PLAYGROUND.md` が描画されて開く | B1 | ポートの設定を `.vscode/settings.json` へ。描画はやめてテキストで開く |
| V10 | `EXTENSIONS_GALLERY={}` でギャラリーが消え、ワークベンチが壊れない | B7 | 行を外し、利用条件の文を替える（§5.13） |
| V11 | エディタの `frame-ancestors 'self'` とプレビューの `frame-ancestors *.<domain>:*` が webview と Simple Browser を壊さない（Chrome、Firefox、Safari） | B6、B13 | 壊れたほうのヘッダを外す（価値は小さい、§6.3） |
| V19 | 端末の装置への書き込みが VS Code の端末に表示される | B10 | 予告をやめ、バナーの終了時刻だけにする |
| V20 | `remote_ip` と `abort` でセッションからルーターへの接続を切れる | E8 | `respond 403` に替え、制御面の同一オリジン検査（§5.2）を頼りにする |
| V21 | `handle_errors` の中の `templates` と `file_server { status … }` | E7、E13、E18 | 状態コードだけ返す（本文は Caddy の既定） |
| V22 | `--tmpfs` に `uid=`、`gid=`、`mode=` を渡せる | W5 | エントリポイントを root で始めて所有者を直してから dev に降りる形は取らない（`no-new-privileges` と矛盾する）。代わりに tmpfs の下に dev 所有のディレクトリを作る手を探す |

VPS とドメインでしか確かめられないもの（§7.7、§8.6）:

| # | 何 | 確かめ方 |
| --- | --- | --- |
| V12 | `payload` の `vscode-remote://` の権限部が 443 でポートなしで通る | P5（B1） |
| V13 | Kamal: `"*.<DOMAIN>"`、複数行の PEM の秘密、ホストの並びと独自証明書、`hooks_path`、`proxy: false` と `options` の `network-alias`、`minimum_version` | `kamal setup`、P4 |
| V14 | kamal-proxy の要求ログにホスト名が入り、`--log-max-size` で短くできる | P13 |
| V15 | `CF-Connecting-IP` が kamal-proxy と Caddy を素通りする | P7 |
| V16 | Cloudflare の WebSocket のアイドル切断と VS Code の再接続 | P9、B14 |
| V17 | x86 の vCPU での作成時間、再ビルド時間、メモリ | P11 |
| V18 | gVisor での互換性と再ビルドの遅れ | §7.12 |
| V23 | 制御面の入れ替えでの 2 つのプロセスの重なりと `flock` | `kamal deploy` の最中に `POST /sessions` を続けて送り、上限を超えないこと |

### 12.2 リスク

- **R1 エディタの URL は持参人払いの能力**（受け入れ）: 手に入れた人はそのセッションのシェルを持つ。128 ビット、
  30 分、`no-referrer`、`noindex`、ログに出さない、入口とガイドの注意で抑える。プレビューの URL は別の乱数なので、
  人に見せてもシェルは渡らない。
- **R2 runc でのカーネル脱出**（gVisor の計測までは受け入れ、§11.2 の Q3）: コンパイラ付きのシェルが 30 分カーネルに
  触れる。全ケーパビリティなし、`no-new-privileges`、既定の seccomp と AppArmor、非 root、カーネルの更新
  （unattended-upgrades と定期の再起動）で抑える。
- **R3 内容の乱用**（受け入れ）: 専用ドメイン、`noindex`、30 分で消える、手順書（§7.11）。Safe Browsing に載ると
  ドメイン全体が止まりうる（そのための専用ドメイン）。
- **R4 外への通信なし**（受け入れ）: `gem install` などは使えない。ガイドと入口に書く。
- **R5 制御面がソケットを持つ**（§3.5 (d)、§11.2 の Q6）: Sinatra / Puma / Rack の RCE はホストの root になる。
  表面を小さく保ち、依存の更新を怠らない。SP3 の前に分離する。
- **ルーターの入れ替え**で全エディタの接続が数秒切れる（§7.8）。まれにしか出さない。
- **アドレスごとに 1 つ**は NAT の利用者を断る（§11.2 の Q5）。
- **Cloudflare への依存**: すべての通信と訪問者のコードを見る、フィッシングの警告ページを挟みうる、WebSocket を
  リリースのときに切る [文書]。利用条件に書き、VS Code の再接続に任せる。
- **Cloudflare の IP 範囲のファイルが空**だと 80/443 が誰にでも開き、`CF-Connecting-IP` を偽れる（アドレスごとの
  上限が破れる。全体の上限は残る）。スクリプトは失敗の終了コードで知らせる（§7.5）。
- **メモリの重ね売り**: 上限 1536m × セッション数はホストのメモリを超えうる。全員が同時に上限まで使うと
  ホストの OOM が大きなプロセス（たいてい cc）を殺す。容量は実際の山（約 1 GiB）で決め（§7.9）、
  ホストに小さなスワップ（2 GB 程度）を置くことを運用ガイドで勧める。
- **2 つのガイドの食い違い**: 共通部分を手で揃える（playground/README.md の規則）。
- **code-server の版**: 訪問者は攻撃者でもありうるので、code-server と VS Code サーバーの脆弱性の修正に遅れない
  （§11.1 の 12）。版上げのたびに §8.5 をやり直す手間がある。
- **x86 での時間**: 再ビルドが arm64 の 46 s より遅いかもしれない。P11 で測り、120 秒を超えたら文面を直す。
- **時刻の表示は UTC**: バナーの終了時刻は UTC、残り分も出すので読み違えは小さい。
- **kamal-proxy のログ**に 30 分有効な能力が残る（§5.11）。root だけが読め、保持を短くする。
- **セッションのイメージの大きさ**: SP1 のイメージ（ディスク 597 MB [計測]）に code-server を足して 1 GB 余り
  [推論]。デプロイの pull に数十秒、ディスクは 3 世代で数 GB。
- **ERB の解決**が Kamal のコマンドのたびに GHCR に問い合わせる。オフラインでは `PLAY_SESSION_IMAGE_REF` で固定する。
- **`.kamal/` をフレームワークのリポジトリの最上位に置く**: Kamal の決まった場所のため。中身は参照だけ。
- **端末を閉じたときのサーバーの孤児**（SP1 と同じ既知の限界、§4.5）。
- **ブラウザ**: VS Code の Web はデスクトップのブラウザ前提。スマートフォンでは使いにくい（入口に書く）。

## 13. SP3（Deploy now、GitHub ログイン、同じサーバー）のために

1. **オーケストレーターの分離**: SP3 の Web 層（OAuth、利用者の入力）を作る前に、`Play::Sessions`、`Play::Templates`、
   `Play::DockerCLI` を、ソケットを持つ別のコンテナ（UNIX ソケットの小さな API: 作成、削除、一覧）に移す。SP2 の入口と
   SP3 のダッシュボードはどちらもソケットを持たない。インターフェースは既に狭い（§3.5 (d)）。
2. **別の登録可能ドメイン**: SP3 のログイン後の画面を `*.<DOMAIN>`（訪問者の書いたページが動く）と同一サイトに
   置かない。同一サイトの攻撃者には SameSite の CSRF 対策が効かず、`Domain=<DOMAIN>` の Cookie を投げ込まれうる。
   公開するアプリも別のドメインに置き、できれば Public Suffix List の private の欄に載せてアプリ同士を別サイトにする。
   SP3 の Cookie は `__Host-` にする。
3. **名前の空間**: ラベル `cybertrain-play.*` とプール `10.250.0.0/16` は SP2 のもの。SP2 の刈り取りは
   `cybertrain-play.role=session` しか触らない。SP3 は `cybertrain-deploy.*` と別のプール（例 `10.251.0.0/16`）を使い、
   ファイアウォールのスクリプトの `POOL` を並びにする。
4. **経路**: kamal-proxy は別のサービスとして SP3 のワイルドカードを持てる [ソース]。SP2 の Caddyfile は
   `{$PLAY_DOMAIN}` にしか合わないので、SP3 のルーターや規則と干渉しない。
5. **容量**: SP3 の常駐アプリがメモリを取る分だけ `PLAY_MAX_SESSIONS` を下げる（設定だけで足りる）。
6. **状態**: SP2 は持たない。SP3 の永続データ（例 SQLite）はホストの別のディレクトリ（`/var/lib/cybertrain-deploy`）と
   バックアップを持つ。`/data` の扱いは同じ型で作れる。
7. **身元**: SP2 は Cookie を出さないので、GitHub OAuth を足しても衝突しない。
8. **ビルドのサンドボックス**: SP3 のビルドは `playground` イメージ（ツールチェーン）を、§5.4 と同じ規律
   （決まった argv、訪問者の入力を argv に入れない、外への通信なし）の別のテンプレートで使える。
9. **外への通信**: SP2 のセッションは SP3 があっても外へ出さない。「セッションからデプロイ」はオーケストレーターが
   ファイルを運ぶ（`docker cp` など）形にし、セッションにネットワークを与えない。
10. **停止スイッチと監視**: `playctl` と `/status.json` の型を広げる。SP3 には利用者ごとの割り当てが要る。

## 14. 本 spec での決定（一覧）

1. ホスト名は平らな一段: エディタ `<sid>.<DOMAIN>`、プレビュー `3000-<pid>.<DOMAIN>`、sid と pid は別々の 128 ビット（§3.3）。
2. 内部の名前はハンドル（`SHA-256(sid)` の先頭 16 桁）、ルーターが引くのはネットワーク別名 `s-<sid>` / `p-<pid>`（§3.3）。
3. ルーターは素の Caddy と静的な Caddyfile（§3.5 (a)）。
4. プレビューはルーターから直接 :3000、`CYBERTRAIN_HOST=0.0.0.0`、`--disable-proxy`（代わりの手つき）（§3.5 (b)）。
5. 制御面は Ruby + Sinatra + Puma の 1 プロセス、Docker の CLI を argv で（§3.5 (c)）。
6. SP2 では制御面がソケットを直接持ち、SP3 の前に分離する（§3.5 (d)）。
7. セッションごとの `--internal` の /28（`10.250.0.0/16` から）、`inhibit_ipv4`（§3.5 (e)、§5.5）。
8. Kamal はルーターと制御面の 2 サービス（§7.1）。
9. セッションのイメージは CI が作って試験し、デプロイがダイジェストで固定し、フックが pull する（§7.4）。
10. code-server はリリースの tar.gz を SHA-256 で検証して入れる（§4.1）。
11. 拡張機能なし、`.html.erb` は HTML として表示、ギャラリーは空（§4.1、§4.4）。
12. アップロードは無効、ダウンロードは有効（§4.2）。
13. 開発サーバーは folderOpen のタスクで起動する（tmux は使わない）（§4.5）。
14. ポートの設定はユーザー設定、タスクはブログの `.vscode/`（git の exclude で隠す）（§4.3）。
15. 読み取り専用のルート + 4 つの tmpfs + イメージ内の種の写し（§4.6、§5.4）。
16. 1 セッションのメモリは 1536m（既定案の 1g から）（§5.4）。
17. TTL は 2 重: 制御面の刈り取りとコンテナ自身の `timeout`（+60 秒）と `--rm`。早めの回収に 300 秒のアイドル終了（§4.6、§5.8）。
18. 終了の 5 分前と 1 分前に端末へ予告（§4.6）。
19. SP2 のガイドは別のファイルで、1 つのコミットに畳み込む（§4.8）。
20. `playground-server` は `VSCODE_PROXY_URI` から URL を作り、終了時刻を出す（§4.7）。
21. 準備確認はルーター越しに Host を付けて（§5.7）。
22. 上限: IPv6 は /64 単位、作成回数は成功だけ数える、アドレスは `CF-Connecting-IP` から（§5.6）。
23. `POST /sessions` は同一オリジンだけ（サイトのオリジンを許す）（§5.2）。
24. ログに sid、pid、IP を出さない。Caddy の実行時のログは捨て、kamal-proxy のログは 1 MB に（§5.11）。
25. 停止スイッチはフラグのファイル + `playctl` + 生の Docker の予備（§5.9）。
26. オリジンごとのヘッダ（§6.3）。
27. ホストのファイアウォールは独自の連鎖で、80/443 は Cloudflare の範囲だけ（§7.5）。
28. 監視は `/status.json` と任意の GitHub の定期実行。VPS に警報の仕組みを置かない（§7.10）。
29. サイトの入口は公開の別コミットで、サイトから 1 回の押下で作成する（§9.1）。
30. 最上位に `SECURITY.md`（§9.5）。

## 15. 承認後の検証と訂正（2026-10-02、実装の前）

§12.1 のうち Docker と Caddy とブラウザだけで確かめられる 7 項目を、実装の前に使い捨ての試験で確かめた
（Docker Engine 29.7.2 / Docker Desktop の linux/arm64、Caddy 2.10.2（`caddy:2.10-alpine`）で実行し 2.11.4 で
設定を検証、code-server 4.139.1、Chromium 154。試験のイメージは SP1 のイメージとスパイクの code-server で、
本書の `web` イメージそのものではない）。この節は本文の該当箇所に優先する。

| # | 結果 [計測] |
| --- | --- |
| V1 | 書いたとおり動く。`--disable-proxy` あり、`--proxy-domain` なし、`VSCODE_PROXY_URI` だけで、タスクが起動したサーバーが検出され、Simple Browser が `3000-<pid>` のホストで自分で開き、Ports ビューも同じ URL を示す。ポートの表示名と openPreview はユーザー設定から効いた（V9 の一部） |
| V2 | 書いたとおり動く。`header_regexp` の捕獲は上流のアドレスにもヘッダの値にも使え、ルーターは `s-` / `p-` の別名を引け、WebSocket は 101 で通る。存在しない別名はエディタで 404 のページ、プレビューで 502 のページになる |
| V3 | 書いたとおり動く。`--internal` + `inhibit_ipv4=true` + 明示した /28 は受け付けられ、ブリッジは IPv4 を持たず、セッションはゲートウェイにもホストにも届かない。対照: `inhibit_ipv4` なしの `--internal` はブリッジのアドレスでホストのリスナーに届く（このオプションは必須で、E2E で確かめ続ける） |
| V4 | 書いたとおり動く。セッションの中で外の名前は引けず、外への通信は一切ない |
| V20 | 書いたとおり動く。セッションの範囲からルーターへの接続は空の応答で切れ、それ以外は通る |
| V21 | 1 か所の変更で動く（訂正 2） |
| V22 | フラグは書いたとおり動く（uid、gid、mode、size が効き、uid 1000 が書ける）。ただし訂正 1 が要る |

訂正:

1. **§4.1（実装を止める誤り）**: web ステージを `WORKDIR /workspace/blog` で終えると、`--tmpfs /workspace` の下では
   runc がエントリポイントより先に、空で root 所有（755）の `/workspace/blog` を tmpfs の中に作る。§4.6 の手順 1 は
   `/workspace` が空でないと見て種の写しを飛ばし、dev は `/workspace/blog` に書けない。web ステージは
   `WORKDIR /workspace`（マウントポイントそのもの）で終える。タスクと端末はワークスペースのフォルダを使うので、
   他に影響はない。制御面の `docker run` と同じフラグで起動したコンテナに、種から写した dev 所有の
   `/workspace/blog` があることを web のスモークテストで確かめる。
2. **§6.1 の `handle_errors`**: `@apex_error host {$PLAY_DOMAIN}` は入口のすべてのエラーに合うので、`/internal/*` の
   `error 404` まで 503 の「unavailable」になる。次の形にする（`caddy adapt` は条件を
   `{http.error.status_code} >= 500` と表示する）:

   ```caddyfile
   	handle_errors {
   		header {
   			Cache-Control no-store
   			X-Robots-Tag "noindex, nofollow"
   			Referrer-Policy no-referrer
   		}
   		root * /srv/pages
   		# Only the control plane's own failures (5xx) get the "not available"
   		# page; a 404 on the apex (/internal/*) gets the 404 page below.
   		@apex_error {
   			host {$PLAY_DOMAIN}
   			expression {err.status_code} >= 500
   		}
   		handle @apex_error {
   			rewrite * /unavailable.html
   			templates
   			file_server {
   				status 503
   			}
   		}
   		@preview_error header_regexp Host ^3000-[0-9a-f]{32}\.
   		handle @preview_error {
   			rewrite * /app-down.html
   			templates
   			file_server {
   				status 502
   			}
   		}
   		handle {
   			rewrite * /ended.html
   			templates
   			file_server {
   				status 404
   			}
   		}
   	}
   ```

3. **ルーターは `--dns 127.0.0.1` で動かす（§7.2、§8.1）**: ルーターは内部でないネットワーク（`kamal`）にもいるので、
   生きた別名の無い id の問い合わせはホストのリゾルバへ転送される。終わったセッションの id（持参人払いの能力）が
   VPS の事業者のリゾルバへ出ていき、リゾルバが遅いと「No session」のページが約 3 秒遅れる。`--dns 127.0.0.1` なら
   404 / 502 は数ミリ秒で返り、何も外へ出ず、生きた別名と `ctplay-control` は引ける。ルーターは外の名前を
   必要としない（`auto_https off`）。compose では `dns: 127.0.0.1`、Kamal では `options` の `dns`
   （Kamal 側は V13 と一緒に VPS で確かめる）。
4. **片付けの順序と keep-alive（§5.4、§5.8、§6.1）**: 順序は §5.4 のとおり「セッションのコンテナを消す → ルーターを
   ネットワークから外す → ネットワークを消す」を守る。逆（先にルーターを外す）にすると、Caddy が上流への接続を
   使い回すため、生きているセッションへの次のリクエストが切れた経路の接続に乗って 3 分以上返らなかった。
   順序に頼らないよう、セッション向けの 2 つの上流は keep-alive を切る:

   ```caddyfile
   			reverse_proxy s-{re.editor.1}:8080 {
   				transport http {
   					keepalive off
   				}
   			}
   ```

   ```caddyfile
   			reverse_proxy p-{re.preview.1}:3000 {
   				transport http {
   					keepalive off
   				}
   			}
   ```

   この形で WebSocket は 101、プレビューは 200、コンテナを消した後もルーターを外した後も 404 のページが
   4〜13 ms で返った。片付けの argv の順序は単体テストで固定し、終わった直後のセッションへのリクエストが
   数秒以内に 404 のページになることを E2E で確かめる。
5. **§5.5**: `inhibit_ipv4` のネットワークにはゲートウェイが無く、最初のコンテナが `.1` を取る
   （`.IPAM.Config[0].Gateway` は空）。/28 の中のゲートウェイの予約は当たらない。害はない（§5.4 が読むのは
   `.Subnet` だけ）。
6. **ルーターの `ip_forward`（追加、念のため）**: ルーターのネットワーク名前空間ではホストから引き継いだ
   `net.ipv4.ip_forward=1` が立っており、ルーターは `kamal` と全セッションのネットワークにまたがる。セッションは
   全ケーパビリティなしなので他所あてのフレームを渡せないはず [推論] だが、ルーターを
   `--sysctl net.ipv4.ip_forward=0` で動かす（`docker run` では受け付けられ、中で 0 と読める。Kamal の `options` は
   V13 と一緒に確かめ、通らなければ外す）。
7. **ルーターの接続と切断は他のセッションを乱さない**: 別のセッションのネットワークへの
   `docker network connect` / `disconnect` の前後で、生きているエディタの接続は同じままで、ブラウザに再接続の
   表示は出なかった。

まだ手元で確かめていないもの: V5〜V11 と V19（本書の `web` イメージそのもので、plan のタスクが確かめる）。
Docker Desktop では確かめられず VPS で確かめるもの: セッションからホストの実サービスへの到達と §7.5 の規則、
事業者のメタデータと私設網、デーモンが IPv6 を有効にしている場合の IPv6、実際のリゾルバへの転送、kamal-proxy と
Cloudflare の経路（V12〜V16。切れた経路の接続はそこでは 504 / 524 として見える）、`runsc` の下でのこの節の全項目。

## 16. 実装後の実態（2026-10-03）

plan（`docs/superpowers/plans/2026-10-02-web-playground-sp2.md`）の 12 タスクを、タスクごとのレビューと合わせて
ブランチ `web-playground-sp2` で終え（`53acca1..ed01fcb`）、ブランチ全体のレビューと 1 回の修正を経た時点の記録。
出どころは plan の注記（"Correction:" と "As built"）、作業台帳（`.superpowers/sdd/2026-10-02-web-playground-sp2/progress.md`、
リポジトリに入れない）の裁定、最終レビューと再レビューの報告、コード。報告とコードが食い違えばコードに合わせた。
この節は §15 を含む本文の該当箇所に優先する。下の変更はどれも plan の訂正か、タスクと最終レビューの裁定で決めた
もので、各行に上書きする本文の節と理由を書いた。この節の [計測] は SP2 の実装の実行で測った値（Apple M5、
Docker Desktop 29.7.2、linux/arm64。x86 の VPS では未計測のまま）。

### 16.1 要約

作ったもの: §1.1 の 1〜5 と、6 の入口を当てていないパッチ（`playground/deploy/launch.patch`）。§10 に無いファイルは
`playground/router/entrypoint.sh`、`playground/control/config/puma.rb`、`lib/play/{guard,ctl}.rb`、`hooks/pre-build`、`launch.patch`。

| 検査 | 結果 [計測] | 時間 |
| --- | --- | --- |
| 制御面の単体テスト（minitest） | `143 runs, 773 assertions, 0 failures` | 1 s 未満 |
| web イメージのスモーク W1〜W13（§8.3） | 13/13 | 83 s |
| SP1 のスモーク | 29/29 | 125 s |
| ルーターの検査 R1〜R13（使い捨て、リポジトリの外） | 13/13 | 9 s |
| 全体の E2E E1〜E19（§8.4） | 19/19 | 196〜198 s |
| デプロイの検査 D1〜D10（使い捨て。Kamal 2.12.0 自身で設定と秘密を読む） | 10/10 | 6〜7 s |
| 文書の検査 K1〜K8、CI の検査（どちらも使い捨て） | 8/8、ok | 1 s |
| 実ブラウザ（§8.5、手元の Chromium） | B1〜B12 合格（B12 はメニューまで。保存は未確認）。B13 は未確認（Firefox が無い）。B14 は本番で | — |
| web イメージの `--no-cache` ビルド | 成功。`docker images` で 1.49 GB、うち `/usr/lib/code-server` 627 MB、種 4.7 MB と 3.8 MB（本文は「1 GB 余り」[推論]、種は約 7 MB） | 161 s |

訪問者の時間（手元、Cloudflare と kamal-proxy なし）[計測]: Start から 303 まで 0.57〜0.84 s（`ready_ms` は 258〜523 ms）、
ガイドが出るまで 2.0〜2.7 s、プレビューの記事一覧まで 6.6〜7.5 s（`Listening` の 1.3 s 後）。ビューの編集はプレビューの
再読み込みから 0.13 s。モデルの編集は再ビルド 46.8 s、保存から 47.3 s で再び待ち受け（W9 は 46 s）。タブを閉じてから
終わるまで約 5 分半（コンテナの終了 5 分 30 秒、`event=ended` 5 分 34 秒。§1.2 の 10 の「約 6 分」より短い）。

まだしていないこと（すべてオーナー）:

- push と PR（GitHub の SSH は 1Password のエージェントを通る）。CI は GitHub で一度も走っていない（amd64 のビルド、
  Linux での E2E、GHCR への push は [未検証]）。`cybertrain-playground-web` を Public にしてリポジトリに結び付けること。
- ドメイン、Cloudflare、Origin CA、VPS、最初のデプロイ（運用ガイドの第 1〜4 部）。VPS とドメインでしか確かめられない
  P1〜P14、B13・B14、5-3 の行（V12〜V18、V23。16.9）。gVisor の計測と判断（第 8 部、Q3）。公開（`launch.patch`、第 9 部）。
- SP2 は SP1 の未マージのブランチ `web-playground` の `6a8853a` の上に積んである。この節の前で main に無いコミットは
  62（SP1 の 22 と SP2 の 40）。SP1 の `85bc6a3 TEMP: live check` は SP2 に入っていない。

### 16.2 本文に優先する変更（セッションのイメージと最初の画面）

| 本文 | 実装 | 理由 |
| --- | --- | --- |
| §1.2 の 3・§4.4 | ガイドはテキストで開く。`workbench.editorAssociations` の 2 行を外した（V9 のガイドは fallback） | 描画したガイドではプレビューがその上のタブで開いた。テキストのエディタが前にあれば Simple Browser は横の自分のグループに開き、code-server 4.139.1 はそのグループに既定で鍵を掛ける（`AUTO_LOCK_DEFAULT_ENABLED`）ので、エクスプローラから開いたファイルは左に入り、プレビューは見えたまま [計測、ソース]。描画は Markdown: Open Preview で開ける |
| §4.4 | `"window.restoreWindows": "preserve"` を足した | エディタの URL の `payload` が読み込みのたびにガイドを開き、そのとき VS Code は他のエディタを戻さないので、再読み込みでプレビューが消えた（B4 が落ちた）。足した後は 0.70 s で 2 つのグループ、2.72 s でプレビュー、6.3 s で端末 [計測] |
| §4.1 | チェックサム 2 つを埋めた（リリースの API の `digest`）。`RUN mkdir .vscode` を `COPY` の前に。版の検査は `grep -m 1 '^[0-9]'` | 新しい HOME での初回は版の行の前に "Wrote default config file" を出す [計測]。`COPY --chown` が作るディレクトリの所有者は保証されない [推論] |
| §4.6 の 1 | 種を写す条件は「`/workspace` が空」ではなく「`/workspace/blog/spin.toml` が無い」。`/workspace/blog` があって書けなければ理由を出して 1 で終わる | §15 の訂正 1 の失敗（runc が root 所有の空の WORKDIR を作る）を、黙って進まずに名指しする [計測] |
| §4.7 | "1 minute" は単数。過ぎた終了時刻は "0 minutes" | "1 minutes" や負の分を出さない [推論] |
| §8.3 の W11 | `/usr/local/bin` ではなく `/opt/cybertrain`（dev のディレクトリ）に書けないこと。`CapEff` に加えて `CapBnd` も 0 | `/usr/local/bin` は書けるルートでも dev には書けず、何も示さない。`CapEff` は root でないどのプロセスでも 0 [計測: `--cap-drop ALL` なしの `CapBnd` は `a80425fb`] |
| §8.3 | 主のセッションは `--rm` なしで `PLAYGROUND_IDLE_TIMEOUT=1800`。W12・W13 は `/healthz` が答えたことと 50・55 秒以上生きたことも求める。補助のコンテナは `--entrypoint sleep … infinity` と `docker exec … curl`（裁定 P8） | ブラウザが来ないので、既定の 300 s では遅いホストで W9・W10 の途中に終わる。起動で落ちたセッションが W12・W13 を通らないように [推論] |
| §1.2 の 8・§4.10 | 予告は 420 s のセッションの 120.1 s と 360.1 s に出た（V19 ok）。時刻を過ぎた予告は出ない（5 分の TTL では 1 分前の行だけ） | [計測]。ガイドの B10 はこの形で書いた |
| §4.10 | 表示は "Attempting to reconnect in N seconds..."（Reload Window、Reconnect Now）で、コンテナが止まってから約 40 秒後（40.1 s、別の回で 36〜38 s）。再読み込みは 39〜95 ms で 404 のページ | [計測]。本文は終了時刻（± 5 秒）に「再接続中」と見ていた [推論] |
| §1.2 の 8・§4.2 | Chrome ではエクスプローラの最初の右クリックが、クリップボードの読み取りの許可の確認に答えるまでメニューを出さない。Download... はあり Upload... は無い。保存されたファイルは未確認（B12 はオーナー） | code-server はメニューの前に `navigator.clipboard.read()` を呼ぶ [ソース、計測]。`Permissions-Policy: clipboard-read=()` で消す案は Paste に響きうるので採っていない。Firefox と Safari にはフォルダを書く API が無く、フォルダの Download は無いかもしれない [推論] |
| §1.2・§8.5 の B4 | 再読み込みはブラウザのボタンで。エディタにフォーカスがあると F5 はデバッグの開始（Ruby のデバッガの確認） | [計測]。ガイドと playground/README.md の Limitations に書いた |
| §1.2・§5.13 | プレビューを使った後のブラウザの戻るは、プレビューの中の移動を先に戻る（7 回。使わなければ 1 回）。戻った入口のボタンは `pageshow` で押せる状態に戻る | [計測]。Playwright の Chrome は back-forward cache を切るので、その道は [未検証]（P7 でオーナーが見る） |

### 16.3 制御面

| 本文 | 実装 | 理由 |
| --- | --- | --- |
| §5.2・§5.13・§6.3 | 前段の `Play::Guard`: 本文を宣言した要求（`Content-Length` が 0 より大きいか `Transfer-Encoding`）に Sinatra より先に 413（"No request body is accepted."）。アプリには空のクエリ文字列を渡す（解釈しない）。入口のヘッダ 4 つ（CSP、`Referrer-Policy`、`nosniff`、`Cache-Control: no-store`）を、Sinatra 自身の 400 / 404 / 500 とホストの検査の 403 を含むすべての応答に付ける | Sinatra はどのルートより先に本文とクエリを解釈した: 20 MiB の multipart は 20 MiB の一時ファイル、130 バイトの入れ子のクエリは 500 と 60 行のバックトレース [計測]。ブラウザの空のフォームは `Content-Length: 0` で通る |
| §5.1 | Puma は `config/puma.rb`（`port 9292`、`threads 4, 16`、`http_content_length_limit 4096`）で、`bundle exec puma -C config/puma.rb`。ベースは `ruby:4.0.7-slim` | Puma は宣言の大きな本文を読まずに断る [ソース] が、chunked の本文は先に一時ファイルへ解く（1 MiB で確認 [計測]）ので、ルーターでも絞る（16.4） |
| §5.1 | Sinatra を読む前に `APP_ENV=production`。`set :protection, false`。`dump_errors`、`show_exceptions`、`raise_errors` は off。予期しない例外は `play event=error step=request exception=<クラス>` の 1 行と決まった 500 | 開発の環境では Sinatra がデバッグのルートを足す。`Rack::Protection` の HttpOrigin はルーターの後ろの `http` と `Origin` を比べて全 POST を断り、FrameOptions は §6.3 が要らないとした `X-Frame-Options` を足す [ソース] |
| §5.2 | `Origin: null` は「無い」と同じに扱い、`Sec-Fetch-Site`（無い、`same-origin`、`none`）で決める（裁定 P9） | `no-referrer` のページからのフォームの POST にブラウザは `Origin: null` を付ける [文書: Fetch]。本文の規則では入口自身のボタンが 403 になる。U1 で 303 [計測] |
| §5.13 | CSP の `form-action` は `'self' <scheme>://*.<domain><port>`。ボタンのスクリプトは `pageshow` でボタンを戻す | POST の 303 はエディタのホストへ行き、Chrome はフォームの送信のリダイレクトも `form-action` で調べる [文書]。back-forward cache から戻った入口で "Starting…" のまま固まらないように [推論] |
| §5.2 | `/internal/sessions` は `::1` も通す（裁定 P8） | 127.0.0.1 と同じループバック [推論] |
| §5.12 | 起動時に Docker に届かないと、届くまで（10 秒ごとに確かめる）停止中と同じページ（"The playground is paused. It cannot reach Docker."）で 503、`Retry-After: 300`（裁定 P8）。起動の後に届かなくなったときは一覧が失敗し、503「失敗」 | 本文は 503「失敗」（`Retry-After: 60`）。直るまで数分かかる状態として扱う [推論] |
| §5.8 の 3 | 自分の記録があるセッションのコンテナが無くなったネットワークは、60 秒を待たずに `idle` で消す。記録の無いものは 60 秒の後に `orphan`（裁定 P8） | 猶予は別のプロセスの作成の途中を守るためで、自分の記録はそれに当たらない [推論] |
| §5.8 の 2 | 記録の無い `created` のままのコンテナは、60 秒の猶予の後に `exited` で消す（`exited`、`dead`、`removing` はすぐ） | deploy で重なったもう一方の制御面の `docker run` の途中を消さない。項目 3 の趣旨に従い、項目 2 の文面には反する [推論] |
| §5.8 | 刈り取りは一覧の前に記録の状態を写し、そのとき `:creating` だったか後から現れたハンドルは、その回の間ずっと作成中として扱う（`exited` や `idle` で終えず、忘れも引き取りもしない）。`:ready` には `:creating` からしか移らない | 遅い回の間に準備のできたセッションを `idle` で消す、または忘れて `client: nil` で引き取り直す（アドレスごとの上限が破れる）ことを偽物の Docker で再現した [計測] |
| §5.12 | 失敗した片付けは記録を `:ending` のまま残し、後の回が記録した理由でやり直す（ネットワークだけが残った場合も）。進行中の片付けには触れない | 作成の失敗で `docker rm` も失敗すると、コンテナが TTL まで残った [計測] |
| §5.8（排他） | 停止の確認をロックの中の最初にもう一度。メモリで決まる拒否（停止、unavailable、アドレスごと、回数、記録が上限）はロックの前。ロックは `LOCK_NB` を 0.05 s ごとに最長 10 s 試し、取れなければ `play event=lock_timeout waited_s=10` と 503「失敗」（`Retry-After: 60`、Docker は呼ばない）。ロックの中では Docker の数（running と created）が正。`playctl` は待ち続ける | 本文の `flock` には期限が無く、満員での拒否もロックの中で `docker ps` を走らせたので、拒否の殺到か遅いデーモン（deploy の pull の間）で Puma の 16 スレッドがすべて待ち、`GET /` と HEALTHCHECK も止まる [計測: 偽物の Docker、推論] |
| 同上の帰結 | 別のプロセスがセッションを終えると（`playctl end`、`kill-all`、自分で止まったコンテナ）、次の刈り取りまで（最長約 5 秒）記録が数えられ、上限ちょうどなら Docker に空きがあっても満員の 503 | 受け入れた（入口と `/status.json` も記録から数える）。E11 は作成の前に生きている数が戻るのを待つ [計測] |
| §5.9 | `playctl` の本体は `lib/play/ctl.rb`。`end` は `[0-9a-f]{16}` だけを受け、先に Docker で探す（無ければ `playctl: no session <handle>`、終了 1）。引数を取らないコマンドに余計な引数を付けると使い方を出して終了 2。`pause` は `-` で始まるメッセージを断る。kill-all の要求が残る間は `status` と `resume` が標準エラーで警告する。`kill-all` は停止と要求のファイルを書き、ロックの中で全部を片付け、Docker の一覧が空になるのを最長 20 秒（0.5 秒ごと）待って報告する（空にならなければ残りの名前と終了 1） | 大文字のハンドルに「ended」と言ってセッションが動き続けた [計測]。`kill-all --help` でも全部を消す作りだった。kill-all が刈り取りと同じ片付けを競って終了 1 になり、E16 が約 10 回に 1 回落ちた [計測] |
| §5.9・§5.11 | `playctl` の出来事の行は実行した端末に出て、サーバーのログには出ない（`playctl end` したセッションは、ログでは `created` だけ） | 別のプロセスだから [計測]。運用ガイドの 7-1 に書いた |
| §5.11 | 新しい出来事: `dropped`（Docker の出力のうち id の形に合わず捨てた数）、`error`（`step=request` は例外のクラスだけ、`step=create` は伏せ字にした文）、`lock_timeout`、`unavailable` / `available`。値に制御文字があれば JSON の形で逃がし、1 つの出来事は必ず 1 行 | 値に改行を入れて偽の 2 行目を作れることを再現した [計測] |
| §5.4 | Docker の出力から argv に入るのは `\A[A-Za-z0-9][A-Za-z0-9_.-]*\z` に合う id だけ。`docker stats` の名前は確かめたハンドルから作る | `-` で始まる id はフラグとして読まれる [推論] |
| §5.4・§5.11 | Docker の標準出力と標準エラー、停止のメッセージは UTF-8 として読み、不正なバイトを洗う。`redact` も先に洗う | `LANG` が無いと Ruby は US-ASCII と見なし、1 バイトで刈り取りのスレッドが例外で落ちた（プロセスが起こし直され続ける）[計測] |
| §5.4 | `docker network create` に `--ipv6=false`（1 つの要素。`--ipv6 false` だと `false` がネットワークの名前になる） | デーモンの `default-network-opts` が IPv6 を有効にすると、IPv4 で断るルーターを越えて偽の `CF-Connecting-IP` で入口に届きうる。明示のフラグは `com.docker.network.enable_ipv6=true` に勝つ [計測: CLI 28.5.2、デーモン 29.7.2] |
| §5.10 | 検査を足した: `PLAY_SESSION_IMAGE` は `\A[A-Za-z0-9][A-Za-z0-9._/:@-]*\z`（`-` で始まらない）、`PLAY_ROUTER_URL` はホストのある素の `http` だけ（文言は "PLAY_ROUTER_URL must be a plain http URL such as http://ctplay-router (got …)"）、ホストの無い URL と origin を断る、`PLAY_PUBLIC_URL` のホストは英数字と `.`、`-` だけ。大きさ、実行環境の名前、ルーターのフィルタ、ヘッダの名前にも形 | argv と CSP のヘッダに入る値の形を決めておく。`https` も許すと言っていた前の文言は嘘になったので替えた [推論] |
| §5.1・§5.3・§5.7・§8.2 | 刈り取りのスレッドは自分にだけ `abort_on_exception`。記録に `cpu`、`memory`、`hot`、`reason`。準備確認は 1 回ずつ（`max_retries = 0`）。作成の呼び出しはルーターの一覧をネットワークの作成より前に | Puma のスレッドは自分の例外の扱いを保つ。Net::HTTP は読み取りの期限の後で GET を繰り返す [ソース]。ルーターが 0 台なら何も作らない（§5.4）には先に一覧が要る |

### 16.4 ルーター

| 本文 | 実装 | 理由 |
| --- | --- | --- |
| §6.1 | ベースは `caddy:2.11.4-alpine` | 2026-10-02 の 2.x の最新 [文書] |
| §6.1（apex） | `request_body { max_size 4KB }` と、`handle_errors` の apex の 413（決まった文 "Request body too large"） | Puma は chunked の本文をガードが答える前に一時ファイルへ解くので、匿名の相手が Cloudflare の上限（100 MB）まで、多くの接続で、ホストの Docker の記憶域に溜めさせられた [計測: 1 MiB、文書]。今は切るまでに約 4 KB だけが Puma に届く |
| §6.1・§6.2 | Caddy は既定の経路のネットワーク（本番は `kamal`、手元は compose）の自分のアドレスだけで待つ。`entrypoint.sh` が起動のたびにアドレスを探して `ROUTER_BIND` に入れ、Caddyfile は `bind "{$ROUTER_BIND}"`（引用符付き）。見つからなければ警告を 1 行出して全アドレスで待つ。Dockerfile はビルドの時に `":80"` と `"192.0.2.1:80"` に展開されることを確かめる | `remote_ip` と `abort` は要求ごとの判断で、TCP の接続は受けて要求か読み取りの期限まで持つ。1 つのセッションから約 28,000 の接続（エフェメラルの範囲）を張り直し続けられ、全エディタ、全プレビュー、入口が一緒に落ちうる [推論]。今はカーネルが拒否する [計測: R7、R11〜R13、E8]。引用符の無い空の `bind` は待ち受けを作らない [計測: `caddy adapt` 2.11.4] |
| §7.2・§8.1 | ルーターに `memory: 512m`、`memory-swap: 512m`、`pids-limit: 256`（compose も同じ） | 氾濫の代価をホストのメモリではなくルーターの再起動にする（Kamal の再起動の方針は `unless-stopped` [ソース]）。Caddy は待機で約 17 MiB、E2E の山で 24〜28 MiB と 15〜17 スレッド、持たれた接続は 1 つ約 11 KB（16,000 で 188 MiB）[計測]。512 MiB は約 45,000 の接続で止まる [推論] |
| §6.1 | `@from_session remote_ip {$PLAY_SUBNET_POOL}` と `abort` は二重の守りとして残す | Caddy が全アドレスで待つ場合（警告の道）の備え [推論] |
| §6.2・ルーターの検査 R7 | セッションの範囲からの接続は「空の応答で切る」ではなく接続の拒否（curl の終了 7）。R7 はこれを指す。R11（表のアドレスだけで待つ）、R12（`docker restart` の後もそう。表のアドレスは `.3` から `.2` に変わった）、R13（既定の経路が無い: 警告 1 行で全アドレス）を足した | 古いイメージでは 13 項目のうち 4 つが落ちる [計測] |
| §15 の訂正 3、4、6 | 書いたとおり（`keepalive off`、`--dns 127.0.0.1`、`--sysctl net.ipv4.ip_forward=0`。後の 2 つは compose と Kamal の `options`） | E11 が `keepalive off` を、E13 が DNS と `ip_forward` を確かめる [計測] |
| §6.1（先送り） | `@preview_error` に `host *.{$PLAY_DOMAIN}` の行が無く、`3000-<32 桁>.<他のドメイン>` は 404 ではなく 502 のページ | kamal-proxy は `<DOMAIN>` と `*.<DOMAIN>` しか送らず、それより深い名前は Universal SSL で先に落ちる [推論]。次のルーターの変更で直す |

### 16.5 デプロイと運用

| 本文 | 実装 | 理由 |
| --- | --- | --- |
| §7.2・§7.3 | 両方の設定に `minimum_version: 2.12.0`、`hooks_path`（ルーターにも）、`hooks_output: verbose`。ルーターの `options` に `dns: 127.0.0.1`、`sysctl: net.ipv4.ip_forward=0`（§15）、`memory`、`memory-swap`、`pids-limit`（16.4） | Kamal は既定でフックの出力を隠す [ソース]。Kamal 2.12.0 はこれらを `--dns`、`--sysctl`、`--memory` などに描画する [計測: D8]。サーバーの Docker が受け付けるかは [未検証]（5-3） |
| §7.4（フック） | 新しい `pre-build`: 追跡しているファイルの変更と、サービスのディレクトリの下で `Dockerfile.dockerignore` が外さない未追跡のファイル（git が無視するものも）があれば、ビルドと push の前に止める | Kamal は作業ツリー（`context: .`）からビルドする [ソース]。本文の `pre-deploy` の検査は push の後で、未追跡のファイルも見なかった |
| §7.4（`pre-deploy`） | ロールバックでも pull する。2 つの設定の `PLAY_SUBNET_POOL` を比べる。ルーターの deploy（`KAMAL_SERVICE` で見分ける）は、読めて空でない `PLAY_ORIGIN_CERT` と `PLAY_ORIGIN_KEY` が無ければ止める。参照を確かめる（固定なら `@sha256:` がちょうど 1 つで小文字の 16 進 64 桁。`session-image` と `post-deploy` も同じ検査） | 空の PEM がそのまま上がる。プールが食い違うとルーターとファイアウォールが別の範囲を守る。参照は遠隔のコマンドに入る [推論] |
| §7.4（`post-deploy`） | 新しい 3 つと固定中のものを残す。届かないホストや失敗は警告だけで、0 で終わる | 固定中のイメージにはタグが無く、古さで消されうる。deploy は済んでいる [推論] |
| §7.4・§7.8（ロールバック） | 本文の「古い制御面の環境変数に戻るので、セッションのイメージも戻る」と、`pre-deploy` がロールバックを飛ばす形は誤り。Kamal 2.12 は古いイメージを今描画した設定で起こすので、セッションのイメージはロールバックの時点で `latest` が指すもの。戻すには `PLAY_SESSION_IMAGE_REF=<古い参照>`（古いコンテナの環境を `docker inspect` で読む） | [ソース: Kamal 2.12]。本文のままでは pull していないダイジェストを指し、`--pull never` で全作成が失敗する [推論] |
| §7.4（`.kamal/secrets`） | `CERTIFICATE_PEM=$(test -n "$PLAY_ORIGIN_CERT" && cat "$PLAY_ORIGIN_CERT")`（鍵も同じ形） | Kamal 2.12 の dotenv は `${PLAY_ORIGIN_CERT` だけを置き換えて `:-/dev/null}` を残すので、秘密が空になり最初のルーターの deploy が落ちる [ソース]。D8 で 4 行の PEM が届き、D9 で変数なしでも空でエラーが出ない [計測] |
| §7.2（kamal-proxy） | `buffering`: `requests: true`、`responses: false`、`max_request_body: 1_000_000`、`memory: 1_000_000` | 既定では要求を 1 GB まで（1 MB を超えた分はディスク）、応答を上限なく溜めてディスクにあふれさせる [ソース]。プレビューは見知らぬ人のアプリを出すので、1 人がディスクを埋められた。1 MB を超える本文を要るホストは無い |
| §7.6 の 10・§11.1 の 6 | レジストリはルーターと制御面のイメージだけを持つデプロイ用の GitHub アカウント（`<GHCR_OWNER>`、機械アカウント）と、その classic PAT（`write:packages`）。セッションのイメージは最初のデプロイの前に saeki-mototsune の下で Public にし、オーナーの資格情報なしで pull する | Kamal は setup と deploy のたびに VPS で `docker login` し、トークンを `/home/deploy/.docker/config.json` に残す [ソース]。オーナーの PAT なら、VPS の root は全 codespace が取る `cybertrain-playground:latest` と次の deploy が固定する `cybertrain-playground-web:latest` に push できた（16.7） |
| §7.5（スクリプト） | 先に全部を確かめる（Cloudflare の一覧に 1 行以上、どの行も /8〜/32 の IPv4 の範囲、`POOL`、`EXT_IF` がこのホストのインターフェースで `-` で始まらない、`DOCKER-USER` がある）。駄目なら何も変えずに理由を出して 1。規則は 1 回の `iptables-restore -w --noflush` で入れ、`/run/cybertrain-play-firewall/lock` の `flock -w 60` の中で走る。拒まれた規則を名指しして 1。改行で終わらない最後の行も読む | 本文の形は iptables の終了状態を見ず、正しい範囲の無い一覧で 80/443 をすべて落として 0 で終わり、途中で止まると次の実行まで 80/443 が開いた [計測]。Cloudflare の一覧は改行で終わらず（2026-10-02 に 15 行）、本文のループは最後の `131.0.72.0/22` を落とした [計測]。新しい形は D5・D6 が偽物の iptables で確かめただけで、実物は VPS で [未検証] |
| §7.5（ユニット） | `Restart=on-failure`、`RestartSec=10`、開始の回数の上限なし、`RuntimeDirectory=cybertrain-play-firewall` と `RuntimeDirectoryPreserve=yes`、`WantedBy=multi-user.target docker.service` | 守りの規則はやり直し続ける（上限で止まると 80/443 が開き、メタデータの規則も無い）。`/run/lock` は誰でも書ける。Docker の start でも作り直す。一覧が空か壊れていれば最初の起動では規則が 1 つも無い（10 秒ごとにやり直し、5-3 で見る）[推論] |
| §12.2 の R2（成果物に無かった抑え） | ガイドの 2-6: unattended-upgrades を確かめ、`/var/run/reboot-required` があるときだけ 19:00 UTC（日本時間 4 時）に自動で再起動。6-9: 週に 1 度 `docker-ce`、`docker-ce-cli`、`containerd.io`（第 8 部の後は `runsc`）を手で上げ、セキュリティ情報を見る。7-3 に公表のときの行 | R2 は「カーネルの更新と定期の再起動」を前提に runc の危険を受け入れていた。自動更新は再起動せず、Docker の apt リポジトリのもの（runc は `containerd.io`）も上げない [文書] |
| §7.6 の 5 | Docker は管理者 `<ADMIN>`（sudo あり）が公式の apt リポジトリから入れる。`kamal setup` には任せられない | Kamal 2.12 は root か `sudo -nl usermod` ができるときだけ Docker を入れる（`Kamal::Commands::Docker#superuser?`）[ソース]。`deploy` には sudo が無い |
| §7.6 の 6 | Cloudflare の一覧は一時ファイルに取り、IPv4 の範囲の行だけと確かめてから置く（`curl \| tee` ではない）。行は `grep -c .` で数える | 壊れた取得をそのまま規則にしない。`wc -l` は改行の無い最後の行を数えない [文書] |
| §7.7 | P6 はコマンドの塊と期待の出力（ルーターのアドレスに `Host: <DOMAIN>` で curl の終了 7、`lo` の外の IPv6 なし、`ctplay-control` の名前は終了 2）。P7 は戻るを 1 回押してボタンが押せること。P1・P2 は CSP と `status.json` の全文 | 最終レビューの Minor 4（VPS で一番効く検査）と、手元で確かめられない back-forward cache の道 [未検証] |
| §7.8（ルーター） | 新しいルーターがセッションに届くのは刈り取りの次の回（E15 で 6〜7 s、上限 10 s） | 本文は「最長 5 秒」とした。刈り取りの間隔に、回の時間と新しいルーターの起動が足される [計測、推論] |
| §7.11 | WAF の規則は `(http.host eq "<DOMAIN>" and http.request.uri.path ne "/status.json")`。行を足した: ルーターの氾濫（「ルーターの確かめ」のコマンド）、カーネル、runc、Docker、gVisor の脆弱性の公表。侵害の疑いの行に、デプロイ用アカウントの PAT の失効、2 つの公開パッケージに CI が出していない版が無いかの確認、main での "Playground image" のやり直し | 規則が `/status.json` にも確認を挟むと外形監視が 30 分ごとに落ちる [推論]。16.7 |
| §7.12 の 2 | `/usr/bin/time -v` ではなく bash の `time` | イメージに `/usr/bin/time` が無い。手元の runc で再ビルドは `real 0m39.9s` [計測] |
| §9.3・§9.4 | 運用ガイド（867 行）は 9 部（1 用意、2 VPS と 2-6 ホストの更新、3 Cloudflare、4 Kamal、5 公開前の確認（5-3 VPS でしか確かめられない 13 行、5-4 記録）、6 日々の運用と 6-9 暦、7 緊急停止と不正利用、8 gVisor、9 公開）とトラブルシューティング。名前の表に `<ADMIN>` とプール。playground/README.md に E1〜E19 の表（SP1 の E1 とは別）と、ガイドがテキストで開く理由 | 公開の手順と、手元で確かめられなかったものの一覧が要った。設定を元に戻させないため [推論] |
| §9.1・§9.2 | 入口は当てていないパッチ `launch.patch`（`<DOMAIN>` を置き換えて当てる）。CSS は `button.btn { font-family: inherit; line-height: inherit; border: 0; background: none; cursor: pointer; }`。README の段落にサイトの 2 つの主張（満員なら数分後か codespace、"terminal included"）を足し、`site/README.md` の `playground.html` の説明も替える | `font: inherit` は `.btn` の大きさと太さまで戻す（要素とクラスの詳細度が勝つ）[推論]。当てた後のボタンの計算されたスタイルはリンクのボタンと同じ [計測]。サイトの主張は README から来るという `site/README.md` の規則 |

### 16.6 テストと CI

compose（§8.1）はルーターに `dns`、`sysctls`、メモリと pids の上限を持ち、制御面のデータは `${PLAY_DATA_HOST:-./data}`。
E2E（`playground/dev/e2e.sh`、§8.4）は `PLAY_TTL=180`（150 では E2 のセッションが遅い CI で最後まで持たない。E18 は
そのセッションの終わりを測る）、順は E1〜E7、E9、E10、E8、E11〜E15、E18、E16、E17、E19、データは `./data-e2e`
（開発のスタックの `paused` と `kill-all` を共有しない）。セッションか、同じスタックの別の制御面（コンテナの環境の
`PLAY_SESSION_IMAGE` で見分ける）が Docker にあれば、名前を出して終了 2 で始めない。

| 検査 | ラベルの外で求めること（どれも通った [計測]） |
| --- | --- |
| E8 | 「経路なし」と接続の時間切れだけを塞がれたと数え、接続も拒否もそれ以外も抜け道とする。ゲートウェイの代わりにホストの全アドレスとホストの待ち受け（18099）、`172.17.0.1` の 22/80/443/2375、`1.1.1.1`、メタデータ、別セッションの 8080/3000、`example.com` と `ctplay-control` の名前。正の対照: ルーターのセッション側のアドレスの 80 が拒否する（curl の終了 7）。ホストのどのアドレスも `10.250.0.0/16` に無い（`inhibit_ipv4` が効いている） |
| E9 | `CapBnd` も 0。`lo` の外に IPv6 のアドレスが無い |
| E11 | `playctl end` の後 5 s 以内に 404 のページ。生きているセッションからルーターを外して 3 s 以内に 404（`keepalive off` が要る唯一の検査）。`end` の後ごとに（最初の作成の前も）、生きている数が 1 に戻るのを待つ。3 つ目の 429 は回数のページ |
| E12 | 本文 3 つ: 小さい本文はガードの 413（"No request body is accepted."）、長さを宣言した 1 MiB は 413（ルーターか Puma）、chunked の 1 MiB はルーターの "Request body too large"。この origin からの `Origin: null` は検査を通る（その先のアドレスごとの 429） |
| E13 | `/internal/sessions` はルーター自身の 404 のページ。ルーターの DNS が `[127.0.0.1]`、`ip_forward` が 0 |
| E14・E15 | `docker restart` が 0 で終わり、生きている数は 1（本文の 2 ではない。その時点で残るのは 1 つ）。E15 はルーターのコンテナ id が変わる |
| E17 | ルーターを止めると外から届かないので、制御面のコンテナの中から POST。理由が "It is starting up"、その前の `resume` が 0 |
| E18 | `expires-at` と `created-at` の差が TTL に等しく、終わりは `expires-at` の −5〜+15 s（早すぎる終わりも落ちる） |
| E19 | 作成がちょうど 5 つ、探した id がその 2 倍、32 桁の 16 進が単独でログに無い、クライアントのアドレスも無い |
| §8.5 の B | B1 はテキストのガイドと右の鍵付きの Simple Browser、B4 はブラウザのボタン、B6 は Markdown のプレビューを手で開く、B7 は検索欄に語を入れる、B9 は Preview in Editor、B10 は 4 分で 1 分前の行と約 40 秒後の再接続、B11 は約 5 分半、B12 はフォルダとクリップボードの確認、B13 はファイルとフォルダの Download |

ミュータント（コミットしていない）[計測]: 検査を 1 つずつ崩した 10 か所でちょうどその 10 が落ち、エディタの上流から
`keepalive off` を外すと E11 だけが落ちた（"200, then 000 in 5 s"）。古いルーターのイメージではルーターの検査が 9/13、
メモリの満員の検査を外すと上限のテストが落ち、引用符の無い `bind` はビルドの検査で落ちる。修正のテストは先に赤を見た。

| 本文 | 実装 | 理由 |
| --- | --- | --- |
| §8.7（`web` ジョブ） | `needs: image`。タグの検査を自分でも行う。キャッシュは `playground-image` と `playground-web` を読み、`playground-web` にだけ書く | web ステージは playground ステージの上にあり、`playground-server` は全セッションで動くので、SP1 のスモークが落ちた土台をセッションのイメージにしない。2 つのジョブが同じ範囲に同時に書かない [推論] |
| §8.7（手動の実行） | タグの説明は 2 つのパッケージを名指しし、手で出した `latest` が次の deploy で固定されると書く | 手動の実行は両方に push する（CI の検査が説明の文を確かめる [計測]） |
| §8.7（制御面） | `playground/web-smoke.sh` の変更でも走る | drift のテストがそれを読む（CI の検査がパスの一覧を確かめる [計測]） |
| §8.7（外形監視） | `curl -fsS --max-time 20 --retry 2 --retry-delay 15 --retry-all-errors "${PLAYGROUND_URL%/}/status.json"`、本文に `"accepting":` が無ければ失敗。`*/30` のまま | 一時の失敗で知らせない、末尾の `/` で `//` にならない、`-f` は 3xx を通すので本文で見る [計測: 手元のサーバーで 5 通り] |

最初の実行で見ること（オーナー）: E15（6〜7 s、上限 10 s。一番余裕が小さい）、制御面のイメージの最初のコールドビルド
（手元の compose はキャッシュから来た）と setup-buildx のビルダーでの compose のビルド、Linux の E8 と E9（手元のホストは
Docker Desktop の VM）、W9・W12・W13 と E2・E11・E14・E18 の時間の窓、`web` ジョブの時間（見積もり 30〜50 分 [推論]、上限 60 分）。

### 16.7 脅威モデルへの追記（§3.6、§12.2）

| 経路 | 内容 | 抑え（実装） |
| --- | --- | --- |
| セッションからルーターの氾濫（新しい。§3.6 の M8 は要求の単位でしか満たしていなかった） | ルーターは全エディタ、全プレビュー、入口を運び、全セッションのネットワークにいる。`abort` までは TCP を受けて持つので、1 セッションから約 28,000 の接続を張り直し続けられ、数セッションで掛け算になる。ルーターのメモリ（`br_netfilter` があればホストの conntrack も）が尽きると全員が一緒に落ち、CPU で見る `suspect` は気付かない [推論] | ルーターはセッションのネットワークで待たない（カーネルが拒否）、`memory 512m` と `pids 256`（ホストではなくルーターの再起動）、7-3 の行と「ルーターの確かめ」、P6 の `router: exit 7`。残り: OOM の後の再起動が失敗しうる（16.8） |
| レジストリのトークンからの供給網（新しい。§7.6 の 10） | R2 の脱出で VPS の root を取ると、`/home/deploy/.docker/config.json` のトークンで `cybertrain-playground:latest`（全 codespace が取る）と `cybertrain-playground-web:latest`（次の deploy が固定する）に push でき、VPS を作り直しても残った [ソース: Kamal 2.12] | ルーターと制御面のイメージだけを持つデプロイ用アカウント。セッションのイメージは公開のまま資格情報なしで pull。7-3 で PAT の失効、CI が出していない版の確認、`latest` の出し直し。CI のトークン（Actions はメジャーのタグで固定）は残る経路 |
| ログの溢れ（§5.11。制御面のログは 10 MB × 3） | 本文はガード、apex の 4 KB、Puma の 4096、kamal-proxy の 1 MB で閉じた。クエリは解釈しない（前は 130 バイトで 500 と 60 行）。本文の無い multipart の `Content-Type` はまだ Rack のパーサに届き、1 要求で `event=error` が 1 行出る（匿名の相手がログを回せる。先送り） | [計測]。16.3 |

最終レビューが挙げた、オーナーが受け入れる残りの危険（14）:

1. R2 の脱出（runc でのカーネルや runc）。境界集合まで空のケーパビリティ、`no-new-privileges`、読み取り専用のルート、
   既定の seccomp と AppArmor、cgroup で抑え、gVisor と実際に入ったホストの更新で変わる。修正前の公表が最悪の場合。
2. R1 の能力 URL。制御面のログには出ないが、kamal-proxy の要求ログ（root と docker グループ、1 MB）と Cloudflare に残る。
3. R5 のソケット。Sinatra / Puma / Rack の RCE はホストの root。解釈しない表面と、Cloudflare、kamal-proxy、ルーターで抑える。
4. R3 の内容の乱用。Safe Browsing に載ると、入口を含むドメイン全体が止まりうる。
5. 1 つの登録可能ドメイン。訪問者のアプリは `.<DOMAIN>` に Cookie を置け、他人を締め出したり Cookie を入れたりできるが、
   セッションは奪えない（制御面は Cookie を使わず、code-server は `--auth none`）。SP3 は別のドメイン（§13 の 2）。
6. アドレスごとの上限は Cloudflare（だけを通す規則と新しい範囲の一覧）と、再起動で消えるメモリ頼み。全体の上限は効く。
7. Fetch Metadata の無い古いブラウザは、被害者のアドレスからセッションを作らされうる（裁定 P9）。迷惑だけ。
8. ルーターの deploy は全エディタの WebSocket を切り、新しいルーターは約 5〜10 秒でセッションに届く。
9. メモリの重ね売り（1.5 GiB × セッション数は RAM を超えうる）。計測した山からの容量と 2 GB のスワップで抑える。
10. 外向きの帯域。訪問者のアプリは 30 分、誰にでも大きな応答を流せる（kamal-proxy は溜めないのでディスクは使わない）。
11. 共有の dockerd。セッションは内蔵 DNS に問い合わせて少し負荷をかけられる。ルーターの再起動の間は全員が止まる。
12. 起動直後の数秒は Kamal のコンテナがファイアウォールより先に起き、80/443 が開き、メタデータの規則も無い（5-3 で測る）。
13. VPS 1 台で、ホストに警報なし。外形監視は任意で、60 日動きが無いと GitHub が予定のワークフローを止める。
14. アドレスごとに 1 つは NAT の向こうの人を断る（Q5）。ワークショップでは設定を上げる。

### 16.8 未解決と先送り

レビューが「待てる」として台帳に残したもの（1 項目 1 文）:

- 制御面（作成と片付け）: ロックの別案（`LOCK_NB` を 1 回だけ）は記録だけ。重なった片付けへの Docker の答え（"already in
  progress"、"marked for removal"、"unknown network"）を「別の片付けが進行中」と読む改良（今は `docker_error` が増えるだけ）。
  `ended` が 2 行出うる。`@connected` と、別のプロセスが終えた記録を黙って忘れる刈り取り（`forgot` の行が安い）。kill-all の
  `ended` に `age_s` が無い。`:in_progress` に年齢の上限が無い。kill-all のファイルを消す `rm_f` が EPERM も飲む。
- 制御面（そのほか）: `Probe#ready?` は理由を残さない（間違った `PLAY_ROUTER_URL` は 30 s 後の `ended reason=failed` に
  しか見えない）。本文の無い multipart（16.7）。Puma 自身の 413 と 400 にヘッダが無い。Puma の 16 スレッドは容量の表
  （16 セッションまで）に合わせて増えない。イメージの `build-essential`。gem の更新が暦に無い（R5）。`EventLog#event` は
  不正なバイトで例外（今の呼び出しは洗った値だけ）。`DockerCLI#run` の期限は直接の子だけ。
- 制御面のテスト: 禁止フラグの `=` の形、プールの最後の区画、`Limits` の掃除、/29 より狭いプールの文言、
  `docker_unreachable` と `read_stats` の失敗と `start_reaper`、`playctl end` の `docker network ls` の失敗を試していない。
- セッションのイメージ: 配置は code-server 4.139.1 の既定のグループの鍵に頼る（次の版上げで `workbench.editor.autoLockGroups`
  を書く）。code-server の取得に `curl --retry` が無い。W6 はサーバーが動く前の mtime だけを見る。エントリポイントの守りと
  バナーの単数と 0 の検査が無い。`web-smoke.sh` の補助関数は `smoke.sh` の写し（SP1 と SP2 のマージの後にまとめる）。
- ルーター: `@preview_error`（16.4）。Dockerfile のコメントが `--sysctl` に触れない。基のイメージをダイジェストで固定して
  いない。エントリポイントが引数を無視し、`docker run <ルーター> <コマンド>` と `--reuse` なしの `kamal app exec -c router.yml`
  が 2 つ目の Caddy を起こして返らない（1 行で直る）。OOM で止まったルーターが再起動を待つ間に片付けがネットワークを
  消すと "network … not found" で起動できず、`kamal deploy -c router.yml` まで全体が止まる（bind の後では起きにくい）。
- デプロイと VPS の確認: commit の時点の失敗ではファイアウォールが `COMMIT` を名指しする。掃除は deploy の後だけ。
  `user:` の値の引用符とコメントが残る。`pre-build` は非 ASCII の名前のファイルを誤って拒む（安全側）。最終レビューの勧め
  で 5-3 にまだ無いもの: `net.bridge.bridge-nf-call-iptables`（CTPLAY の physdev の規則が効くか）と conntrack の余裕、
  無作為の id の 404 の時間（`--dns 127.0.0.1` の効果）、TLS の後ろの code-server（`X-Forwarded-Proto: http`）を見る本番の B1。
- CI: `web` ジョブのキャッシュのコメントは再利用を言い過ぎる（`.git` のバインドで Spinel までの層だけ）。別の
  concurrency group から `latest` が順不同で出うる。Actions はメジャーのタグで固定。E15 の上限は 15 s にしても意味は弱まらない。
- 文書とテスト: 7-3 の「`docker restart` で警告が消え」は `docker logs` では見えない（前の行が残る）。6-9 の週 1 の
  `/var/run/reboot-required` の確認は更新の日に誤報になる。`usermod -aG docker "$USER"` は `sudo -i` の中では root を足す。
  root だけの手順は root の鍵が前提。`e2e.sh` の本文の検査の前のコメントは言い過ぎ（約 4 KB は Puma に届く）。PASS の行に
  計測値が無い。E8 のホストの待ち受けが実行中だけ `PLAY_ROUTER_FILTERS` に合う。2 回目の Ctrl-C は `down` を止めうる。

オーナーの決定で残るもの:

- §11.2 の Q1（ドメインと窓口のアドレス）と Q7（利用条件の文面、`playground/control/views/terms.erb`）。Q3（gVisor）は
  第 8 部の計測の後。Q2、Q4〜Q6 は本書の既定のまま（設定で変えられる）。
- 外形監視は `"accepting":false`（停止中、満員、Docker かイメージが無い）でも通る。これを知らせるか（停止も知らせる）。
- PR の形（SP1 を先に、`85bc6a3 TEMP` を除いて出すか、1 つの PR で両方か）と、公開の時期。SP3 の問いはこの spec の外で扱う。

### 16.9 V 項目の結果

| # | 結果 | 根拠 |
| --- | --- | --- |
| V1 | ok | §15 の試験と、実物のイメージでの Task 3 の H1・H2（Simple Browser が `3000-<pid>` で自分で開き、Ports ビューも同じ URL）[計測] |
| V2 | ok | §15、ルーターの検査 R1〜R6、E3・E5 [計測] |
| V3 | ok | §15、E8（ホストのどのアドレスも `10.250.0.0/16` に無い）、E9 [計測] |
| V4 | ok | §15、E8（`getent hosts example.com` が 2）[計測] |
| V5 | ok | Task 1 の W5、W8〜W10。tmpfs に `exec` を足す必要は無かった [計測] |
| V6 | ok | W4、W6。WORKDIR は `/workspace`（§15 の訂正 1）、種の判定は `spin.toml`（16.2）[計測] |
| V7 | ok | W13: クライアントが一度も来ないセッションが `PLAYGROUND_IDLE_TIMEOUT=61` で 64 s 後に終わった [計測] |
| V8 | ok | W12: 終了時刻を過ぎたセッションが 66 s で止まり、`--rm` で消えた [計測] |
| V9 | ポート ok、ガイド fallback | H1・H2。ガイドは描画して開けたが、プレビューを横に置くためにテキストにした（16.2）[計測] |
| V10 | ok | H4: ギャラリーの一覧なし、`open-vsx.org` への要求なし（Chromium）[計測] |
| V11 | ok（エディタ、プレビューとも） | H3、Task 8 の U1（Chromium）[計測]。Firefox と Safari は B13 で [未検証] |
| V12 | VPS で | P5（B1）[未検証] |
| V13 | 一部 ok、残りは VPS で | Kamal 2.12.0 自身で設定と秘密を読む D8・D9（ワイルドカードのホスト、TLS、60 s、`buffering`、`options`、4 行の PEM、`proxy: false`、フック）[計測]。`kamal setup`、P4、5-3 の `dns`・`sysctl` とフックの行は VPS で [未検証] |
| V14 | VPS で | P13 [未検証] |
| V15 | VPS で | P7 [未検証] |
| V16 | VPS で | P9、B14 [未検証] |
| V17 | VPS で | P11 と 5-4（手元の値は 16.1）[未検証] |
| V18 | VPS で | 第 8 部（手元の runc の再ビルドは `real 0m39.9s`）[未検証] |
| V19 | ok | H7: 120.1 s と 360.1 s [計測] |
| V20 | ok（形が変わった） | §15、E8。ルーターはセッションのネットワークで待たないので、接続はカーネルが拒否する（curl の終了 7）。`remote_ip` と `abort` は二重の守り（16.4）[計測] |
| V21 | ok（§15 の訂正 2） | R4〜R6、E7、E13、E18 [計測] |
| V22 | ok | §15、W5〜W11（W11 が 4 つの大きさを読み返す）[計測] |
| V23 | VPS で | 5-3 の「制御面の入れ替え」の行 [未検証] |
