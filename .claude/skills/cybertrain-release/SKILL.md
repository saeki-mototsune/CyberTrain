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
- `merged_prs` が手順 1 の対象。ほとんどの PR は、マージコミットの本文から取った `title` を持っている。
- `prs_without_title` は、マージ時に本文が空だったためタイトルの分からない PR 番号。
- `compatibility_paragraphs_since_tag` は、前回タグ以降に `docs/design.md` に追加された "Compatibility" 段落と、それが属する決定 (Dnn)。
- `upgrading_sections` は、アップグレードガイド (英語と 4 つの翻訳) にあるリリースの節の一覧。
- `pins` と `spinel` が手順 2 の材料。
- `workflows_on_main` が false のワークフローは、まだ main にないので起動できない。
- `warnings` が空でなければ、その内容をユーザーに伝える。

## 1. PR の概要とバージョン番号

### タイトルを補う

タイトルが足りないのは `prs_without_title` の分だけ。それを GitHub から 1 回で取る:

- `mcp__github__list_pull_requests` を `state: "closed"`, `base: "main"`, `sort: "updated"`, `direction: "desc"`, `perPage: 100`, `fields: ["number","title"]` で呼ぶ。`prs_without_title` の番号だけを拾い、残りは捨てる (このリストにはマージされずに閉じた PR や前回タグより前の PR も混ざる)。fields を絞ること。`body` や `user` まで取ると数万トークンになる。拾えない番号が残ったら、その番号だけ `mcp__github__pull_request_read` (`method: "get"`) で読む。
- タイトルだけでは中身が分からない PR に限って本文を読む。全部は読まない。

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

互換性の変更かどうかは、大きな PR の本文を片端から読んで判断しない。安く確実な順に見る:

1. タイトルが `compatibility:` で始まる PR
2. `compatibility_paragraphs_since_tag`。決定ごとに互換性への影響が書いてある。「none broken」のように影響なしと書かれた段落もあるので、本文を読んで判断する。決定の見出しの issue 番号や日付を手がかりに、対応する PR を探す。
3. それでも迷う PR だけ本文を読む

互換性の変更があればマイナーを提案し、アップグレードガイドを確認する:

- `upgrading_sections` の 5 ファイルすべてに、今回の節 ("From 0.x to 0.y" とその訳) があるか。ないファイルがあれば「bump PR をマージする前に書く必要がある」と明記する (CONTRIBUTING.md の Releasing 手順 1)。
- 節があれば、上で見つけた互換性の変更が英語版 `docs/guide/upgrading.md` の節の中で扱われているかを照らし合わせる (キーワードで grep すれば足りる)。漏れていそうなものは、どの決定・PR かを添えて挙げる。ガイドの漏れはここでしか見つからない。

迷う PR があれば、どの PR がなぜ迷うのかを書いて、ユーザーに決めてもらう。

バージョン番号は手順 4 でそのまま使う。**ユーザーへの確認は手順 2 の Spinel の確認とまとめて 1 回で行う** (下記)。

## 2. Spinel のバージョン確認

スクリプトの `spinel` を見る:

- `pin_is_latest: true` → 「ピン (`SPINEL_TAG`) はフォークの最新タグと同じ。Spinel は据え置き」と伝え、手順 3 は飛ばす。
- `newer_than_pin` にタグがある → 新しいタグの一覧と、検証候補として最新のもの (`latest_tag`) を示す。

新しいタグに何が入ったかも見ておくと、candidate の結果を読むときに役立つ。フォークは公開リポジトリなので、scratchpad に blob なしで clone する。上流のマージを取り込むため、差分は数千コミットになることがある。全部は読まず、PR のマージだけに絞る:

```bash
git clone --quiet --bare --filter=blob:none https://github.com/saeki-mototsune/spinel.git <scratchpad>/spinel.git
git -C <scratchpad>/spinel.git log --merges --format=%s <現在のピン>..<候補タグ> \
  | sed -n 's/^Merge PR \(#[0-9]*\): /\1 /p' > <scratchpad>/spinel-prs.txt
wc -l <scratchpad>/spinel-prs.txt
```

上流 (matz/spinel) の PR は `Merge PR #12401: タイトル` という件名で入っているので、これで上流 PR の番号とタイトルだけが 1 行ずつ残る。フォーク側の `Merge branch 'matz:master'` などは落ちる。

未解決の項目は `docs/spinel-feedback.md` の "## What is asked of Spinel now" の下、"### 2. Bugs still open" (と "### 3. Seen in the framework, not reduced yet") にある。項目ごとの上流 issue/PR 番号や症状のキーワードで、上の出力を grep する。当たりがあれば「直った可能性がある項目」として挙げる。コミットのタイトルから推測しただけなので、確かめるには各項目の再現プログラム (spikes/) を新しいタグで動かす必要がある、と添える。直っていれば spikes/NOTES.md の回避策を外せる可能性がある。その作業はリリースとは別件として提案するだけにする。

### ここでユーザーに 1 回だけ確認する

手順 1 と 2 の結果を見せたうえで、次をまとめて聞く (AskUserQuestion が使えるなら 1 回の呼び出しで):

- 次のバージョン番号 (推奨と理由を添えて)
- Spinel を新しいタグに上げる候補にするか (候補にするなら、手順 3 で candidate を回す)
- candidate で macOS も回すか (既定はいいえ)

この確認の答えが、手順 3 と 4 でワークフローを起動してよいという了承になる。起動直前に同じことを聞き直さない。ただし起動する値 (タグや番号) が確認時から変わった場合は、もう一度聞く。

## 3. Spinel candidate ワークフロー

新しい Spinel タグがあるときだけ実行する。ユーザーが明示的に頼んだ場合は、ピンと同じタグでの再確認でも実行してよい (ワークフローがその旨を notice で出す)。

### 前提: main にあること

`workflow_dispatch` のワークフローは、デフォルトブランチにファイルがないと起動できない。`workflows_on_main.spinel_candidate` が false なら、起動はできない。そのことと、追加する PR があればその URL (`mcp__github__list_pull_requests`, `state: "open"`) を伝える。その間は、手順 4 のうち Spinel を据え置く bump だけを進められる。

### 同じタグの run が既にないか

起動する前に、`mcp__github__actions_list` (`method: list_workflow_runs`, `resource_id: spinel-candidate.yml`) で最近の run を見る。run の表示名には入力が出ないので、新しいものから `list_workflow_jobs` で `resolve` ジョブを開くか、summary の見出し ("Spinel candidate <タグ>") でタグを確かめる。

- 同じタグで実行中のものがあれば、新しく起動せずにそれを待つ (concurrency の設定で、2 本目は 1 本目が終わるまで待たされるだけ)。
- 同じタグで、今の main と同じ commit (`head_sha`) で成功した run があれば、それを結果として使ってよい。commit が古ければ、main がその後に変わっているので回し直す。

### 実行

入力は 2 つ:

| 入力 | 値 |
|---|---|
| `spinel-tag` | 検証するタグ (例: `YYYY.MM.DD.NNNN`) |
| `macos` | 真偽値。macOS で全テストも回すか。既定 false。macOS ランナーは数が少なく遅いので、ユーザーが望むときだけ true |

```
mcp__github__actions_run_trigger
  method: run_workflow
  owner: saeki-mototsune, repo: CyberTrain
  workflow_id: spinel-candidate.yml
  ref: main
  inputs: { "spinel-tag": "<タグ>", "macos": false }
```

(GitHub の API は workflow_dispatch の入力を文字列として受け取る。ツールが真偽値を受け付けなければ `"false"` / `"true"` を渡す。)

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

手順 2 の終わりの確認で決まった値で起動する。candidate の結果を受けて `spinel_tag` を空に変える場合は、変えることをユーザーに伝えてから起動する:

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
- 互換性の変更: <決定・PR の一覧> / アップグレードガイド: 5 ファイルとも節あり or 不足 <ファイル> / 漏れの可能性 <項目>
- Spinel: ピン <タグ> / フォーク最新 <タグ> → 据え置き or <タグ> へ
- 新タグで直った可能性がある spinel-feedback 項目: <項目と根拠のコミット> (再現プログラムでの確認は別件)
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
