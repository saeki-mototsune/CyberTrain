# GitHub Actions の利用量を減らす設計

- 状態: 提案（2026-10-25）。実装はまだ。
- 対象: `.github/workflows/{ci,gate,playground-image,blog-image,pages}.yml`、`script/`、`.githooks/`、`CONTRIBUTING.md`
- 目的: PR 1 本あたりの Actions 消費分数を 1/3〜1/2 にし（§3: 155 分 → 51〜74 分）、テストの主戦場をローカル（開発機と Claude のクラウドセッション）に移す。CI が検出できる不具合の範囲は狭めない。

## 0. 一言でいうと

今は **PR への push 1 回で約 50 分、main へのマージでさらに約 50 分**の Actions 時間を使っている。内訳は CI（Ubuntu 21 分 + macOS 15 分）、Playground image（7〜13 分）、Blog image（4〜5 分）で、この 3 本が `cybertrain/**` を触る PR（直近 20 本のうち 15 本）で毎回全部走る。しかも PR で通った同じ変更をマージ後に main で丸ごともう一度走らせている。

やることは 3 つ。

1. **PR では Ubuntu 1 本の CI と Gate だけ走らせる**。macOS は OS 差分が出うる場所（CLI のツールチェーン、サーバー、プロセス周り）を触った PR だけ、2 つのイメージビルドは Dockerfile 周りを触った PR だけ。それ以外は main への push（マージ後）に回す。これだけで PR 側は push 1 回あたり約 51 分 → 約 21 分。
2. **main でも二重実行をやめる**。マージコミットが PR の head と同じツリーなら（= base が動いていなければ）CI をスキップし、イメージは必要なときだけ作る。
3. **ローカルで同じことを先に通す**。`script/ci-local`（CI の Ubuntu ジョブと同じ手順を 1 コマンドで）、`spin test` の増分ビルドを活かした pre-push フック、Claude のクラウドセッション向けの CLAUDE.md。CI は「ローカルで通したものの確認」になる。

上の 1 と 2 だけで PR 1 本（push 2 回 + マージ）あたり **約 155 分 → 約 75 分**（§3）。3 は分数ではなく「赤い CI を見てから直す」往復を減らす。

## 1. 現状の計測

リポジトリは public なので標準ランナーの課金は 0 円のはず（[GitHub Docs](https://docs.github.com/en/billing/concepts/product-billing/github-actions): public リポジトリの標準ランナーは無料）。ただし Actions の利用量メトリクスには乗り、同時実行枠（全体で Free は 20 ジョブ、Pro は 40 ジョブ。macOS はどちらも 5 ジョブ、[limits](https://docs.github.com/en/actions/reference/limits)）は消費する。private にした瞬間に macOS は 10 倍換算になる（15 分 × 10 = 150 分/回）。以下はすべて「ランナーが動いていた分数」。

### 1.1 ワークフロー 1 回あたり（直近 60 run、2026-10-23〜25）

| ワークフロー | トリガー | 1 回あたり | 主な中身 |
| --- | --- | --- | --- |
| CI / test (ubuntu-latest) | PR と main push | 21 分 | `spin test` 9 分、E2E 3 本（shop 5 分、album 4 分、gitshop 1 分）、examples/blog 1.5 分 |
| CI / test (macos-latest) | 同上 | 15 分 | 同じ手順。arm64 で速い |
| Playground image | 同上（`cybertrain/**` など） | 7〜13 分 | docker build 5.5 分（gha キャッシュあり）、smoke.sh 5.6 分 |
| Blog image | 同上 | 4〜5 分 | docker build 4 分（Spinel を毎回ビルドしている、後述） |
| Gate | 全 PR と main push | 0.2〜1 分 | `script/gate` |
| Pages | main push のみ | 0.5 分 | YARD と deploy |

Spinel ツールチェーンのキャッシュは効いている（restore 1 秒、`cybertrain setup` 1 秒）。遅いのは Spinel ではなく **フレームワークとテストのコンパイル**で、`spin test` の `build/` は毎回ゼロから作っている。

### 1.2 PR 1 本のライフサイクル

`cybertrain/**` を触る PR（直近 20 本中 15 本）で、push 1 回ごとに 5 本のワークフローが起動する。

| 場面 | 走るもの | 分 |
| --- | --- | --- |
| PR へ push（1 回） | CI ubuntu 21 + CI macos 15 + Playground 10 + Blog 5 + Gate 0.3 | 約 51 |
| main へマージ | 上と同じ + Pages 0.5 | 約 52 |
| PR で push 2 回 + マージ | | **約 155** |

直近 30 日で main へのマージは 68 本、直近 7 日で 40 本。1 日 6 本のペースだと **1 日約 930 分、月約 2.8 万分**。10/25 10:22 には 1 分の間に 6 本がマージされ、30 本の run が起動した（concurrency で 20 本はキャンセルされたが、起動と checkout の分は消費している）。

### 1.3 二重実行

`on: pull_request` と `on: push: branches: [main]` が同じ paths で同じジョブを走らせている。マージコミットは、PR の作成以降に main が動いていなければ PR の head と同じツリーで、テスト結果は PR で出ている。main 側の run はほぼ全部その再確認に使われている。

### 1.4 ローカル

`spin test` はテストごとに 1 本のバイナリをコンパイルし、`xargs -P <CPU 数>` で並列に走らせる。CI の ubuntu-latest（4 vCPU）で 82 本に 9 分、macos-latest（arm64、3 コア）で 6 分。Claude のクラウドセッション（4 vCPU、16 GB）で計った値:

| 状態 | 再コンパイル | 時間 |
| --- | --- | --- |
| 初回（`build/` なし） | 82 本 | 14 分 02 秒 |
| 2 回目、何も変えない | 0 本 | 11 秒 |
| `cybertrain/version.rb` を touch（内容は同じ） | 82 本 | 13 分 59 秒 |
| `test/router.rb` だけを touch（内容は同じ） | 82 本 | 13 分 10 秒 |
| `spin test test/cli_new.rb`（1 本を指名） | 1 本 | 下記 |

分かったこと:

- **spin の鮮度判定は粗い。** テスト 1 本のソースを touch しただけで 82 本全部が作り直される（`test/router.rb` の変更が `build/test/blob_store` を無効にする）。依存関係ではなく「パッケージ内のどれかの入力が出力より新しいか」で見ているので、`build/` が残っていて効くのは「何も変わっていないとき」だけ。したがって **CI で `build/` をキャッシュしても、PR は必ず何かを変えているので、ほぼ毎回フルビルドになる**（§2.3 で検討していたキャッシュ案はこれで見送り）。
- ローカルで速いのは `spin test test/<name>.rb` と指名したとき。1 本なら数秒〜十数秒で、`script/ci-local --quick`（§2.5）はこれを使う。
- `test/cli_new.rb` はこの環境では `spin test` 経由だと最初のテストブロックの途中で出力が止まり FAIL になる（4 回とも再現）。同じバイナリを `/tmp` から直接実行すると 23 tests, 154 assertions, 0 failures で通る。CI（Ubuntu/macOS）では通っている。環境固有（cwd か、`xargs -P` 下での stdout の扱いか）の問題として別に調べる。設計には影響しない。

## 2. 設計

### 2.1 PR と main で走らせるものを分ける

| ジョブ | PR | main push | 理由 |
| --- | --- | --- | --- |
| Gate | ○ | ○ | 1 分。必須チェック（`ci` と並べて要求する） |
| CI ubuntu | ○ | ○（§2.2 の条件つき） | 唯一の「全部走る」ジョブ |
| CI macos | △（toolchain/server/CLI まわりを触ったときと、ラベル `ci:macos`） | ○ | OS 差分はそこに集中している（§2.1 の実例） |
| Playground image | ×（playground/ か .devcontainer/ か Dockerfile を触ったときだけ） | ○（publish のため） | フレームワークの挙動は CI の E2E が見ている。イメージが壊れる変更の大半（gemspec と cli-src の不一致）は `script/gate` が既に捕まえる |
| Blog image | ×（examples/blog/ か Dockerfile を触ったときだけ） | ○ | 同上 |
| Pages | — | ○ | 変更なし |

macOS を PR から外すことには実害が 1 件ある。直近 60 run の中で CI が落ちた 1 回（10/23 18:25、PR #61）は **macOS だけ**が落ちていて、落ちたのは `test/cli_toolchain.rb` の「the build lock is a directory ... taken atomically」（ファイルシステムの挙動の差）。Ubuntu は通っていた。つまり OS 差分は出るし、出るのは CLI のツールチェーン周り（`cybertrain/cli/toolchain.rb`、プロセスやファイルロック、OpenSSL のリンク）に集中している。

なので「PR では macOS を走らせない」ではなく、**変更が OS 差分の出る場所に触れたときだけ PR でも macOS を走らせる**。判定は先頭の小さなジョブ `plan`（10 秒）が `git diff --name-only` でやり、matrix を出力する（yml は §2.2 にまとめて載せる）。見る場所:

```sh
MACOS_PATHS='^(cybertrain/cli/|cybertrain/cli\.rb|cybertrain/shell\.rb|cybertrain/server|cybertrain/dev/|cybertrain/version\.rb|exe/|test/cli_|test/server|test/dev_|\.github/workflows/ci\.yml|spin\.toml)'
```

パスの一覧は「過去に macOS だけで落ちた/落ちそうな場所」から始めて、macOS だけで落ちる事例が出るたびに足す（この文書に記録する）。`version.rb` は Spinel の release bump のため。Spinel の release bump と `cybertrain/cli/` の変更は PR の 2 割程度なので、macOS の PR 実行は 1/5 に減る。ラベル `ci:macos` は手で両 OS を回すとき用（`pull_request.types` に `labeled` を足す）。

Playground と Blog の `pull_request.paths` から `cybertrain/**`、`cybertrain.rb`、`cybertrain.gemspec`、`spin.toml`、`exe/**` を外し、`push.paths` には残す。フレームワークの変更でイメージが壊れる場合はマージ後の main で分かる。それは今より遅い検出だが、(a) イメージは PR では push されないので誰にも配られない、(b) 壊れたら main の run が赤くなって次の PR で直す、(c) 直近 60 run で PR のイメージビルドが落ちた例はない、ので受け入れる。心配なら `ci:images` ラベルで opt-in できるようにしておく（macOS と同じ仕組み）。

### 2.2 main での再実行をやめる

マージ後の main push で CI を走らせる前に、「このコミットのツリーは、既に CI が通った PR の head と同じか」を見る。判定は §2.1 の `plan` ジョブに入れる（OS の判定と同じ場所で、同じ checkout を使う）。macOS は main では常に走らせたいので（下記）、「スキップ」は job の `if:` ではなく **matrix から ubuntu を外す**形にする。job 単位の `if:` だと matrix 全体、つまり macOS も止まってしまう。

```yaml
jobs:
  plan:
    runs-on: ubuntu-latest
    outputs:
      os: ${{ steps.os.outputs.os }}
    steps:
      - uses: actions/checkout@v4
        with: { fetch-depth: 0 }
      - id: os
        env:
          PR_LABELS_JSON: ${{ toJSON(github.event.pull_request.labels.*.name) }}
          MACOS_PATHS: '^(cybertrain/cli/|...)'   # §2.1 の一覧
          DOCS_ONLY: '^(site/|.*\.md$|script/|\.githooks/)'      # ci.yml 先頭コメントの paths 規則
          TESTED_ANYWAY: '^(docs/api/|docs/template-language\.md$|script/api-docs$)' # その例外（API リファレンスの入力）
        run: |
          ubuntu=1; macos=0
          if [ "$GITHUB_EVENT_NAME" = schedule ]; then
            ubuntu=0; macos=1   # schedule 版（下記）: 1 日 1 回、main の先端で macOS だけ
          elif [ "$GITHUB_EVENT_NAME" = push ]; then
            macos=1             # schedule 版ではここを 0 にする
            # マージコミット（親 2 つ）で、第 2 親（PR の head）とツリーが同じなら
            # PR で走った ubuntu の結果がそのまま使える。
            if [ "$(git rev-list --parents -n1 HEAD | wc -w)" = 3 ] &&
               [ "$(git rev-parse 'HEAD^{tree}')" = "$(git rev-parse 'HEAD^2^{tree}')" ]; then
              ubuntu=0
            fi
          else
            changed=$(git diff --name-only "origin/$GITHUB_BASE_REF...HEAD")
            # docs だけの変更なら何も走らせない（os=[]、test はスキップ、ci は通る）。
            # ただし API リファレンスの入力（ci.yml の例外）が入っていればテストする。
            if ! printf '%s\n' "$changed" | grep -qvE "$DOCS_ONLY" &&
               ! printf '%s\n' "$changed" | grep -qE "$TESTED_ANYWAY"; then
              ubuntu=0
            fi
            # §2.1: OS 差分が出うる場所を触った PR は macOS も
            printf '%s\n' "$changed" | grep -qE "$MACOS_PATHS" && macos=1
            # ラベル ci:macos は「両 OS を回す」: docs-only 判定より優先する
            if printf '%s' "$PR_LABELS_JSON" | grep -q '"ci:macos"'; then
              ubuntu=1; macos=1
            fi
          fi
          os=""
          [ $ubuntu = 1 ] && os='"ubuntu-latest"'
          [ $macos = 1 ] && os="${os:+$os,}\"macos-latest\""
          echo "os=[$os]" >> "$GITHUB_OUTPUT"
  test:
    needs: plan
    if: needs.plan.outputs.os != '[]'
    strategy:
      fail-fast: false
      matrix:
        os: ${{ fromJSON(needs.plan.outputs.os) }}
    ...
  # branch protection に要求するのはこのジョブ。needs の失敗やスキップを
  # そのまま結果にする: plan が落ちれば test はスキップされ、スキップは
  # 「成功」として報告されるので、test 自体を必須にすると ubuntu を
  # 走らせずにマージできてしまう。
  ci:
    needs: [plan, test]
    if: always()
    runs-on: ubuntu-latest
    steps:
      # 式で判定し、needs の値をシェルに展開しない。
      - if: >-
          needs.plan.result != 'success' ||
          (needs.test.result != 'success' &&
           !(needs.test.result == 'skipped' && needs.plan.outputs.os == '[]'))
        run: exit 1
```

ツリーが同じになるのは、PR のブランチが main の先端から出ていてマージまでに main が動かなかったとき（直近の merge の大半）。main が動いていればツリーは違うので普通に走る。

この判定は「PR の head で CI が通っていた」ことを前提にするので、上の `ci` ジョブを branch protection の必須チェックにする。注意点が 1 つ: **`paths` でスキップされたワークフローは check を作らず Pending のままになり、必須チェックにすると PR がマージできなくなる**（[GitHub Docs: Handling skipped but required checks](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/defining-the-mergeability-of-pull-requests/troubleshooting-required-status-checks#handling-skipped-but-required-checks)）。一方 job の `if:` でスキップしたものは Success として報告される。なので CI の `on.pull_request.paths` を外し、`plan` ジョブが（上の OS 判定と同じ `git diff` で）「docs だけの変更か」を見て、そのときは `os=[]` を出力する（`test` はスキップ、`ci` は通る）。ci.yml の先頭コメントに書かれている paths の規則は `plan` のスクリプトに移す。

macOS は main でだけ走るので、この判定で macOS まで止めると一度も走らない変更が出る。上のとおり main では常に macOS を matrix に残す（1 回 15 分、1 日 6 回で 90 分、全体の 1/10）。それも惜しければ **schedule 版**にする: `on.schedule: cron "0 3 * * *"` を足し、`plan` の分岐で `schedule` のときは macOS だけ（`ubuntu=0; macos=1`）、`push` のときは `macos=0` にする（上の yml のコメント）。PR 側は §2.1 のパス判定のまま。別ワークフローには分けない（同じ `test` ジョブを使う）。

**merge queue は使えない**。「マージ前に main と合わせた状態で 1 回だけ走る」が GitHub の機能として手に入るが、merge queue は organization 所有のリポジトリ限定で、個人アカウント所有の本リポジトリでは有効にできない（[GitHub changelog, 2023-07](https://github.blog/changelog/2023-07-12-pull-request-merge-queue-is-now-generally-available/)）。organization に移す予定が出たら再検討する。

### 2.3 CI ubuntu ジョブ自体を短くする（21 分 → 17 分）

| 手 | 今 | 後 | 分 |
| --- | --- | --- | --- |
| E2E の 3 アプリを 1 つにする | shop（scaffold + authentication）、album（attachment）、gitshop（git 依存）をそれぞれ `cybertrain new` してフルコンパイル | shop に `post title:string cover:attachment` も載せて 1 回ビルド。gitshop は `spin run gen -- --check` と migrate だけなので今のまま | −4 |

`spin test` の `build/test/` を `actions/cache` でキャッシュする案（キー `hashFiles('cybertrain.rb','cybertrain/**','test/**','spin.toml')`、restore-keys で直近を復元、checkout 後に `git-restore-mtime` で mtime を揃える）は **見送り**。§1.4 のとおり spin はテスト 1 本の変更で 82 本全部を作り直すので、何かを変えた PR では復元した `build/` が丸ごと無効になる。逆に restore-keys で別コミットの `build/` を復元して mtime を揃えると、復元したバイナリ（過去の CI の時刻）が変更後のソース（コミット時刻）より新しく見えるケースがあり、古いバイナリで「通る」危険もある。使うなら完全一致キーだけだが、それでは何かを変えた PR には当たらない。残るのは 9 分のフルコンパイルそのもので、これを縮めるには (a) Spinel のコンパイルを速くする、(b) 82 本のテストプログラムを束ねてバイナリの数を減らす、(c) spin に依存関係ベースの鮮度判定を入れてもらう、のどれかで、どれもこの設計の外（(b) はテストの書き方の変更、(c) は matz/spinel への提案）。

### 2.4 Blog image の Dockerfile でレイヤーを分ける

`examples/blog/Dockerfile` は `COPY cybertrain/ /src/cybertrain/` の後に `cybertrain setup`（Spinel のビルド、3 分）を置いているので、フレームワークの 1 行の変更で Spinel を作り直している。`playground/Dockerfile` が既にやっているとおり、`cybertrain setup` が読むのは CLI の数ファイルだけ（`cybertrain.gemspec` が列挙する `cybertrain/cli/`、`version.rb` など）なので、順番を変える。

```dockerfile
# CLI だけ（gemspec が列挙するファイル）: Spinel のレイヤーはこれにしか依存しない
COPY cybertrain.gemspec cybertrain.rb spin.toml README.md /src/
COPY exe/ /src/exe/
COPY cybertrain/version.rb cybertrain/app_name.rb cybertrain/shell.rb cybertrain/ident.rb cybertrain/cli.rb /src/cybertrain/
COPY cybertrain/cli/ /src/cybertrain/cli/
COPY cybertrain/generator/inflector.rb /src/cybertrain/generator/
RUN ruby -I/src exe/cybertrain setup
# フレームワーク本体: ここから下だけが毎回変わる
COPY cybertrain/ /src/cybertrain/
COPY examples/blog/ /src/examples/blog/
```

`script/gate` の「playground gem stage copies spec.files」チェックをこの Dockerfile の setup 前の COPY にも広げる。spec.files は CLI のファイルだけ（gem が配るのは CLI だけなので、15 ファイル）で、`cybertrain setup` が読むのはその一部。チェックは「setup 前の COPY が spec.files を漏れなく含むか」で、フレームワーク本体のファイルは spec.files にないので対象外。gem に CLI のファイルを足したときに両 Dockerfile の COPY にも足し忘れない、を機械で見る。これで Blog image は 4 分 → 1.5 分。main でしか走らなくなるので分数への効きは小さいが、ローカルで `docker build` する人の待ち時間が減る。

### 2.5 ローカルでテストを通す

CI を減らした分、「push する前に通っている」ことを人（と Claude）の側で担保する。

**`script/ci-local`**（新規）: CI の Ubuntu ジョブの手順を順に実行する 1 コマンド。

```
script/ci-local            # gate → spin test → examples/blog の gen 鮮度と spin test → api-docs
script/ci-local --e2e      # 上に加えて、CI と同じ E2E（cybertrain new → scaffold → build → curl）を /tmp で
script/ci-local --quick    # gate と、変更に関係するテストだけ（下記）
```

CI の yml に書かれている shell をこのスクリプトに移し、CI からは `script/ci-local --e2e` を呼ぶ。**CI とローカルの手順が 1 か所になる**のが本題で、分数の話ではない。E2E の curl 列は今 yml の中にしかなく、ローカルで再現できない。

**`--quick` の「関係するテスト」**: `git diff --name-only main...HEAD` で `test/*.rb` が変わっていればそれ、`cybertrain/foo.rb` が変わっていれば `test/foo*.rb` と、`grep -l "cybertrain/foo"` で引けるテスト。外れたら全件。指名した 1 本は数秒〜十数秒でコンパイルされる（§1.4）。全件は touch 1 つで 14 分のフルビルドになるので、`--quick` は必ずファイルを指名する。

**pre-push フック**（`.githooks/pre-push`、`script/install-hooks` が入れる）: `script/ci-local --quick` を走らせる。pre-commit の gate が 1 秒なのに対しこちらは分単位なので、`git push --no-verify` で飛ばせること、`CYBERTRAIN_SKIP_PREPUSH=1` でも飛ばせることを CONTRIBUTING.md に書く。

**Claude のクラウドセッション**: この repo の PR の大半は Claude が作っている。`script/claude-cloud-setup` で Spinel は既に入っているので、ルートに `CLAUDE.md` を置き、

- push する前に `script/ci-local` を通す（E2E は変更が CLI・generator・templates に及ぶときだけ `--e2e`）、
- 落ちたまま push しない、どうしても push するなら PR 本文に落ちているテストと理由を書く、
- `test/*.rb.expected` を再生成したら diff を PR 本文に貼る、

を書く。Codespaces（`.devcontainer`）は playground イメージなので対象外。

**PR テンプレート**: 「`spin test` passes」のチェック項目を「`script/ci-local` passes（出力の最後の行を貼る）」に変える。CI が Ubuntu 1 本になるので、レビュアーが見るのはこの行と Gate。

### 2.6 細かいところ

- `concurrency` の `cancel-in-progress` は PR で既に効いている。main 側は `cancel-in-progress: false` で pending が 1 本に畳まれているので、連続マージの無駄は 1 run あたり 0.2 分で済んでいる。変更なし。
- `Pages` は 0.5 分で、`cybertrain/**` の変更ごとに API リファレンスを再デプロイしている。変更なし。
- `Gate` は 0.2 分。変更なし。branch protection の必須チェックは `Gate` と、§2.2 の最終ジョブ `ci` の 2 つにする（`test` や `CI ubuntu` ではなく `ci`。`test` はスキップされうるので必須にしない）。
- `timeout-minutes` を CI に入れる（今は Playground 45、Blog 30 だけ）。ハングした `spin test` が 6 時間回るのを防ぐ。30 分。

## 3. 効果の見積もり

PR で push 2 回 + マージ 1 回、`cybertrain/**` を触る変更、main は動いていない前提。

| 段階 | PR push ×2 | main push | 合計 | 今比 |
| --- | --- | --- | --- | --- |
| 今 | 51 × 2 = 102 | 52 | 155 | 100% |
| §2.1（PR は ubuntu + gate） | 21.3 × 2 = 43 | 52 | 95 | 61% |
| + §2.2（main の CI ubuntu をスキップ、macOS は残す） | 43 | 15 + 10 + 5 + 0.3 + 0.5 = 31 | 74 | 48% |
| + §2.3（ubuntu 21 → 17 分、macOS 15 → 12 分） | 17.3 × 2 = 35 | 12 + 10 + 5 + 0.3 + 0.5 = 28 | 63 | 41% |
| + macOS を 1 日 1 回の schedule に | 35 | 10 + 5 + 0.3 + 0.5 = 16 | 51 | 33% |

§2.3 の E2E 統合は macOS にも効く: macOS の E2E は shop 3.7 分 + album 2.7 分（run 40064478805）で、album の分が消えるので 15 → 12 分。最後の行は PR 1 本の表からは macOS が消えるが、別枚で 1 日 1 回 12 分かかる。月で見ると（1 日 6 マージ × 30 日 = 180 PR）: 今 155 × 180 = 約 2.8 万分 → §2.1〜2.2 で 74 × 180 = 約 1.3 万分 → §2.3 で 63 × 180 = 約 1.1 万分 → schedule 化で 51 × 180 + 12 × 30 = 約 0.95 万分。§2.1 と §2.2 だけでも 48%。

## 4. 実装の順番

小さい PR に分ける。ci.yml を触る PR は CI が 1 回走る（`**` にマッチする）が、それ以外は Gate だけ。

1. **ci.yml**: `plan` ジョブ（OS 判定と docs-only 判定、§2.1〜2.2）、`timeout-minutes`、already-tested ジョブ（§2.2）。branch protection の必須チェックに `ci` を足す。Playground/Blog の `pull_request.paths` からフレームワークを外す。→ この 1 本で 48%。
2. **script/ci-local** と CONTRIBUTING.md、PR テンプレート、CLAUDE.md、pre-push フック（§2.5）。CI の E2E shell をスクリプトに移す。この PR はスクリプトの移動なので CI ubuntu が 1 回走る。
3. **E2E の統合**（§2.3 前半）と **Blog Dockerfile のレイヤー分け**（§2.4）、gate のチェック拡張。
4. **コンパイル時間そのもの**（§2.3 の末尾）: spin の鮮度判定について matz/spinel に依存関係ベースの判定（またはコンテンツハッシュ）を提案する。入れば `build/` キャッシュが生きて ubuntu の 9 分が消える。
5. 1 か月後に §1.1 の表を取り直す。macOS だけで落ちた run があれば §2.1 のパス一覧に足す。

## 5. やらないこと

- **self-hosted runner**: 管理の手間が増えるだけで、public リポジトリでは分数が無料なのでメリットがない。
- **テストを間引く・`spin test` を PR で走らせない**: CI が Ubuntu 1 本になっても、PR では全テストを走らせる。「落ちていることを知らずにマージ」は分数より高い。
- **macOS を完全にやめる**: cybertrain のユーザーの開発機は macOS が多い（CONTRIBUTING の OpenSSL の注記、spikes の計測は macOS）。main での 1 日 1 回は残す。
- **Playground イメージの publish をタグのときだけにする**: `.devcontainer` が `:latest` を見ているので、main のたびに最新を配る今の運用を変えない。
