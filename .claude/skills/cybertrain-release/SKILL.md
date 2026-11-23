---
name: cybertrain-release
description: CyberTrain のリリース準備を一通り進める手順。前回リリースタグ以降にマージされた PR の概要をまとめ、Spinel フォーク (saeki-mototsune/spinel) の最新タグと現在のピン (Cybertrain::SPINEL_TAG) を比べ、新しいタグがあれば Spinel candidate ワークフローで検証し、Bump version ワークフローで VERSION (gem) と必要なら SPINEL_TAG を上げる PR を作らせる。「リリースしたい」「リリース準備」「次のバージョン出す」「バージョン上げて」「前回リリースから何が入った?」「Spinel の新しいタグ来てる?」「bump version 回して」「spinel-candidate 回して」など、CyberTrain のリリースやバージョン更新、リリースノート作成、Spinel ピン更新の話が出たら、明示的に「スキル」と言われなくても必ずこのスキルを使うこと。
---

# CyberTrain リリース準備

CONTRIBUTING.md の "Releasing" の手順 1 (バージョンを上げる PR) までを、判断材料をそろえながら進めるスキル。やることは 4 つで、この順に進める:

1. 前回リリースから積まれた PR の概要をまとめ、次のバージョン番号を提案する
2. Spinel フォークのバージョンを確認する
3. 新しい Spinel タグがあれば **Spinel candidate** ワークフローで検証する
4. **Bump version** ワークフローで VERSION (と必要なら SPINEL_TAG) を上げる PR を作らせる

タグ打ち・`gem push`・Release ワークフローの確認・spin index への公開 (手順 2〜5) はメンテナが手で行う作業なので、このスキルではやらない。最後に「残りの手順」として案内するだけにする。

リポジトリは `saeki-mototsune/CyberTrain`。GitHub 操作は GitHub MCP ツール (`mcp__github__*`) を使う。使えなければ ToolSearch で読み込む。

## 0. 現状を一括で取得する

最初にリポジトリのルートで同梱スクリプトを実行する。前回タグ、マージ済み PR 番号、現在のピン、フォークの最新タグ、ワークフローが main にあるかを JSON で返す (git だけを使い、何も書き換えない):

```bash
ruby .claude/skills/cybertrain-release/scripts/release-status.rb
```

見るところ:

- `already_released` が true なら main は前回タグから進んでいない。リリースするものがないと伝えて止める。
- `merged_prs` が手順 1 の対象。
- `pins` と `spinel` が手順 2 の材料。
- `workflows_on_main.spinel_candidate` が false なら、Spinel candidate ワークフローはまだ main にない (手順 3 参照)。
- `warnings` が空でなければ、その内容をユーザーに伝える。

## 1. PR の概要とバージョン番号

### タイトルと本文を集める

スクリプトが返すのは PR 番号だけ (マージコミットの件名にタイトルが入らないため)。タイトルは GitHub からまとめて取る:

- `mcp__github__list_pull_requests` を `state: "closed"`, `base: "main"`, `sort: "updated"`, `direction: "desc"`, `perPage: 100`, `fields: ["number","title","merged_at","labels","user"]` で呼び、`merged_prs` の番号と突き合わせる。足りなければ `page` を進める。本文は大きいので、ここでは取らない。
- タイトルだけで中身が分からない PR、互換性に関わりそうな PR だけ `mcp__github__pull_request_read` (`method: "get"`) で本文を読む。全部読む必要はない。

### 分類してまとめる

リリースノートは GitHub が PR タイトルから自動生成するので、ここで作るのは**人が読んで判断するための要約**。次の見出しで分ける (該当なしの見出しは省く):

- **互換性の変更** — アプリのコードを変えなくても挙動が変わるもの。`docs/compatibility.md` の "Changing a contract" の定義に従う (API やテンプレート構文の意味、エラーと値の入れ替わり、`spin run gen` の出力、保存形式、ワイヤ形式)。タイトルが `compatibility:` で始まる PR は必ずここ。
- **新機能・改善**
- **バグ修正**
- **Spinel** — ピン更新、Spinel の不具合回避、spinel-feedback の更新
- **CI・開発環境** — ワークフロー、スクリプト、ゲート
- **ドキュメント・設計記録**
- **依存関係** — Dependabot など

各項目は「何が変わったか」を 1 行で、PR 番号 (`#123`) を添える。同じテーマの PR が何本もある場合 (同じブランチから連続して出た PR など) は 1 項目にまとめ、番号を並べる。70 本並べるより、テーマごとに束ねたほうが読み手の役に立つ。冒頭に「前回タグ (日付) から N 本」と 3〜5 行の全体要約を置く。

ユーザーへの返答は日本語で書く (ユーザーが英語を望めば英語で)。同じ内容を scratchpad に `release-summary-vX.Y.Z.md` として保存し、パスを伝える。

### バージョン番号を提案する

`docs/compatibility.md` の規則: 1.0 前は、互換性の変更を含むならマイナー (0.x → 0.x+1)、含まないならパッチ (0.x.y → 0.x.y+1)。

- 互換性の変更があればマイナーを提案し、`docs/guide/upgrading.md` の "Notes by version" に今回の節 ("From 0.x to 0.y") があるか、4 つの翻訳にもあるかを確認する。なければ「bump PR をマージする前に書く必要がある」と明記する (CONTRIBUTING.md の Releasing 手順 1)。
- 迷う PR があれば、どの PR がなぜ迷うのかを書いたうえでユーザーに決めてもらう。

**バージョン番号はユーザーに確認してから**次に進む。番号は手順 4 でそのまま使う。

## 2. Spinel のバージョン確認

スクリプトの `spinel` を見る:

- `pin_is_latest: true` → 「ピン (`SPINEL_TAG`) はフォークの最新タグと同じ。Spinel は据え置き」と伝え、手順 3 は飛ばす。
- `newer_than_pin` にタグがある → 新しいタグの一覧と、検証候補として最新のもの (`latest_tag`) を示す。

新しいタグに何が入ったかも見ておくと、candidate の結果を読むときに役立つ。フォークは公開リポジトリなので、scratchpad に blob なしで clone して差分のコミットを見る:

```bash
git clone --quiet --bare --filter=blob:none https://github.com/saeki-mototsune/spinel.git <scratchpad>/spinel.git
git -C <scratchpad>/spinel.git log --oneline <現在のピン>..<候補タグ>
```

`docs/spinel-feedback.md` の未解決項目 (open なもの) に関係しそうな修正があれば、それも挙げる。新しいリリースで直っていれば、bump 後に spikes/NOTES.md の回避策を外せる可能性がある (この作業自体はリリースとは別件として提案するだけ)。

## 3. Spinel candidate ワークフロー

新しい Spinel タグがあるときだけ実行する。ユーザーが明示的に頼んだ場合は、ピンと同じタグでの再確認でも実行してよい (ワークフローがその旨を notice で出す)。

### 前提: main にあること

`workflow_dispatch` のワークフローは、デフォルトブランチにファイルがないと起動できない。`workflows_on_main.spinel_candidate` が false なら:

- `.github/workflows/spinel-candidate.yml` を追加する PR がまだマージされていない。`mcp__github__list_pull_requests` (`state: "open"`) でタイトルに "Spinel candidate" を含む PR を探し、URL を示して「マージ後に実行できる」と伝える。
- その間に進められるのは手順 4 のうち Spinel を動かさない bump だけ。新しい Spinel に上げたいなら、candidate の結果を待つよう勧める。

### 実行

入力は 2 つ:

| 入力 | 値 |
|---|---|
| `spinel-tag` | 検証するタグ (例: `YYYY.MM.DD.NNNN`) |
| `macos` | macOS で全テストも回すか。既定 false。macOS ランナーは数が少なく遅いので、ユーザーが望むときだけ true |

Actions の起動は外部に作用する操作なので、**タグと macos の値を示して確認を取ってから**起動する:

```
mcp__github__actions_run_trigger
  method: run_workflow
  owner: saeki-mototsune, repo: CyberTrain
  workflow_id: spinel-candidate.yml
  ref: main
  inputs: { "spinel-tag": "<タグ>", "macos": "false" }
```

起動後、`mcp__github__actions_list` (`method: list_workflow_runs`, `resource_id: spinel-candidate.yml`, `workflow_runs_filter: {event: "workflow_dispatch"}`) で今起動した run を見つけ、run の URL をユーザーに伝える。

### 待ち方

apps ジョブは最長 3 時間、macOS は最長 4 時間かかる。短い間隔でポーリングしない。

- 定期チェックの手段 (`send_later`、`ScheduleWakeup` など) があれば 30〜60 分後に確認を予約し、そう伝えてターンを終える。
- なければ run の URL を伝え、「終わったら声をかけてほしい」と言ってターンを終える。

### 結果の読み方

`summary` ジョブがジョブごとの結果表を Step Summary に出す。`mcp__github__actions_list` (`list_workflow_jobs`) で各ジョブの conclusion を見る:

- `resolve`, `framework-tests` (4 シャード), `apps` が必須。`macos` は実行したときだけ必須。
- `rechecks` は参考情報。失敗しても候補の不合格ではない。プローブの挙動が変わったという意味なので、`docs/spinel-feedback.md` に記録すべき変化として報告する。
- 必須ジョブが落ちたら、`mcp__github__get_job_logs` で失敗したステップのログを読み、どのテスト・どの段階で落ちたかを要約する。その場合は新しいタグに上げずに、手順 4 は Spinel 据え置きで進めるか、リリース自体を待つかをユーザーに選んでもらう。

## 4. Bump version ワークフロー

入力:

| 入力 | 値 |
|---|---|
| `cybertrain_version` | 手順 1 でユーザーと決めた `X.Y.Z` (先頭の `v` は付けない) |
| `spinel_tag` | candidate が通った新タグ。Spinel を据え置くなら**空文字** |

新しい Spinel タグを入れるのは、そのタグで candidate が通ったときだけ。通っていないタグでは入れない (bump PR の CI で初めて壊れていると分かると、リリースが止まる)。

これも外部に作用するので、**2 つの値を示して確認を取ってから**起動する:

```
mcp__github__actions_run_trigger
  method: run_workflow
  owner: saeki-mototsune, repo: CyberTrain
  workflow_id: bump-version.yml
  ref: main
  inputs: { "cybertrain_version": "X.Y.Z", "spinel_tag": "" }
```

このワークフローは 10 分以内に終わる。数分おいて `list_workflow_runs` (`resource_id: bump-version.yml`) で結果を確認する。成功すると `release/bump-vX.Y.Z` ブランチから main への PR ができているので、`mcp__github__list_pull_requests` (`head: "saeki-mototsune:release/bump-vX.Y.Z"`) で探して URL を伝える。同じバージョンで 2 回目に実行すると、既存のブランチと PR が更新される。

よくある失敗 (ログの `::error::` で分かる):

- **RELEASE_PR_TOKEN がない・期限切れ**: 最初のステップで止まり、何も push されていない。Settings → Secrets and variables → Actions でトークン (このリポジトリに Contents / Pull requests / Workflows の read and write) を更新してもらう。GITHUB_TOKEN への切り替えは提案しない — それで開いた PR では Gate も CI も走らない。
- **tag vX.Y.Z already exists**: その番号は既にリリース済み。番号を決め直す。
- **has no tag**: `spinel_tag` の綴り違い。
- **Gate と CI が 3 分以内に始まらない**: PR は開いているがチェックが走っていない。PR の Checks を見てもらう。

## 最後の報告

次の形でまとめる:

```
## リリース準備: vX.Y.Z

- PR 概要: N 本 (要約ファイル: <パス>)
- バージョン: 現在 → X.Y.Z (パッチ / マイナー、理由)
- Spinel: ピン <タグ> / フォーク最新 <タグ> → 据え置き or <タグ> へ
- Spinel candidate: 未実行 / 実行中 <run URL> / 合格 / 不合格 (落ちたジョブ)
- Bump version: <run URL> → PR <URL>

### 残りの手順 (手作業)
1. bump PR の Gate と CI が通ったらマージ (マイナーなら upgrading.md の節を先に)
2. git tag vX.Y.Z && git push origin vX.Y.Z
3. gem build cybertrain.gemspec && gem push cybertrain-X.Y.Z.gem
4. タグで走る Release ワークフローを確認 (イメージ 2 つ、リリース作成、promote-latest、spinel-prebuilt)
5. spin index に載せている場合は手で publish (CONTRIBUTING.md "Publishing to the spin index")
```

まだ終わっていない段階 (candidate の実行待ちなど) で報告するときは、終わっている項目だけ埋め、何を待っているかを書く。
