---
source_sha256: 0baa2cbe2f6ba4660c7c7cc119800b524b5117dcc1e3d25d565af42ef866d793
---
# バックグラウンド処理と運用

## バックグラウンド処理

リクエストの外で何かをしなければならないアプリケーション（レスポンスを返した後に通知を送る、1 時間ごとに古い行を掃除する、失敗した呼び出しを再試行する）は、それをフレームワークに登録します。フレームワークは、配信を行うプロセス、または別のワーカープロセスのバックグラウンドスレッドでそれを実行します：

```ruby
# config/app.rb（または bin/<app>.rb が Cybertrain::Main.run の前に require するファイル）
Cybertrain::Scheduler.every(3600, "prune sessions") do
  Cybertrain::DB.with { |c| c.execute("DELETE FROM sessions WHERE updated_at < datetime('now', '-30 days')") }
end

Cybertrain::Job.handle("welcome_mail") do |payload|
  data = Cybertrain::Cast.hash(JSON.parse(payload))
  WelcomeMail.deliver(data["email"].to_s)   # 例外を出すと再試行される
end
```

```ruby
# アクションの中で、ユーザーを保存した後に
Cybertrain::Job.enqueue("welcome_mail", JSON.generate({ "email" => @user.email }))
Cybertrain::Job.enqueue("reminder", @order.id.to_s, run_at: Time.now + 600)
```

- **どこで実行されるか。** 定期タスクは 1 本のスケジューラーのスレッドで、ジョブはそれ専用の `job_threads` 本のジョブスレッド（3、`CYBERTRAIN_JOB_THREADS`）で実行されるので、長いジョブがタスクを遅らせることはありません。どちらも、バイナリが配信を行うとき（`./<app>`、`./<app> server`）か、ワーカーとして動くとき（`./<app> worker`。[プロセスの役割](#process-roles)を参照）に、起動処理がデータベースに接続し `SPINEL_WORKERS` を設定した後で始まります。`migrate`、`db ...`、`console`、`Main.command` のコマンドでは決して始まらず、`Cybertrain::Test::Client` でも始まりません。タスクは開始から `seconds` 秒後に初めて実行され、その後は各実行の開始から `seconds` 秒後に実行されます。各実行は rescue で包まれており、`[ERROR] Scheduled task "name" failed: ...` をログに出してループは続きます。ブロックは引数を取りません（Spinel には `instance_eval` がありません）。`Cybertrain::Scheduler.last_tick` は最後のティックのエポック秒で、自前のヘルスチェックに使えます。
- **ジョブ。** `Job.enqueue` は `cybertrain_jobs` テーブルに行を追加します。このテーブルはフレームワークが自分で作り（最初の使用時に `CREATE TABLE IF NOT EXISTS`）、`db/schema.rb` には含めません。ペイロードは String です：構造化されたデータは JSON でエンコードしてください。`DB.transaction` の中では、行は他のものと一緒にコミットまたはロールバックされます。各ジョブスレッドは、期限の来た最も古いジョブを短い `BEGIN IMMEDIATE` トランザクションで確保し、そのハンドラーをトランザクションの外で実行して `done` にし、次を探します。期限の来たものがなければ `job_poll_interval` 秒（1）待つので、リクエストがキューに入れたジョブは 1 秒ほどで始まります。例外を出したハンドラーは 1 分、5 分、15 分、その後は 60 分後に再試行され、`last_error` には `Class: message`（最大 1000 文字）が入ります。これは `job_max_attempts`（5）回の試行が失敗するまで続き、その後、行は `failed` になって、調べられるように残ります。種類にハンドラーのないジョブはすぐに `failed` になります。`Job.enqueue` は登録されていない種類を拒否します。`Job.state_count("failed")` と `Job.prune_done(before_epoch)` は、ヘルスページや後片付けに役立ちます。
- **少なくとも 1 回。** ジョブは 2 回実行されることがあります：強制終了されたプロセスや、`job_heartbeat_stale`（300 秒）より長く止まったプロセスは、別のプロセスが行を取り戻したとき（下記）にまだジョブを実行しているかもしれません。数えられるのは、その行を保持しているクレームの結果だけです（先のクレームが遅れて書いた結果は捨てられます）が、ハンドラーの副作用は 2 回起きています。どのジョブキューでもそうであるように、もう一度実行しても安全なハンドラーを書いてください（メールがもう送られたかを確かめる、insert ではなく upsert する）。
- **種類ごとの同時実行数。** `Job.handle("sync_account", concurrency: 1) { ... }` は、データベースを共有するすべてのプロセスを通じて、その種類のジョブが同時にその数までしか実行されないようにします（レート制限のある API や、重なってはいけない作業のため）。デフォルトの 0 は無制限です。その間もほかの種類は実行され続けます。この上限は `running` の行を数えるので、ハートビートが続いているあいだだけ成り立ちます。ハートビートが古くなった後もまだ動いているハンドラーは、取り戻された行の次の実行と重なります（下記）。決して重なってはいけない作業には、独自のガードが必要です。
- **データベースごとに複数のワーカー。** ジョブを実行するプロセスはどれも、`job_heartbeat_interval`（30 秒）ごとに実行中のジョブのハートビートを書きます。ハートビートが `job_heartbeat_stale` より古い `running` の行（クラッシュしたプロセスや、ジョブの途中で止められたプロセスのもの）は、次に見たプロセスが、その開始時とその後 1 分に 1 回、キューに戻します。定期タスクは一度に 1 つのプロセスでしか実行されません：プロセスはデータベースのリース（`cybertrain_leases`。ティックごとに更新、`scheduler_lease_ttl` は 30 秒）を共有し、その保持者だけが期限の来たタスクを実行します。保持者が更新をやめると、別のプロセスが引き継ぎます。リースは各タスクの前に更新され、タスクの実行中には更新されないので、ttl より長いタスクは次の保持者のタスクと重なることがあります。タスクは短く（本当の作業は `Job.enqueue` で）、繰り返しても安全に書いてください。こうして、2 つの `worker` プロセスや、サーバーとワーカーが 1 つの SQLite ファイルを共有できます。`CYBERTRAIN_WORKER=0` は、HTTP だけを提供すべき `server` プロセスでジョブ、タスク、フィードを止めます。
- **停止。** `SIGTERM` を受けると、ジョブスレッドは新しいジョブの確保をやめ、プロセスは実行中のジョブを最大 `job_drain_timeout`（10 秒）待ちます。それでも実行中のジョブの行は `running` のまま残ります。ハートビートは止まっているので、古くなった時点で別のプロセスがもう一度実行します。
- **タスクは短く保つ。** タスクはスケジューラーのスレッドで一度に 1 つずつ実行され、SQLite の呼び出しは戻るまで OS のワーカーを占有します：`SPINEL_WORKERS=1`（デフォルト）では、長いクエリはその間すべてのリクエストとほかのすべてのスレッドを止めてしまいます。本格的な作業のあるタスクはジョブに任せ（タスクから `Job.enqueue`）、大きな作業は一度に済ませずに分割してください（1 回の実行で 1000 行ずつ削除する、項目ごとにジョブを 1 つキューに入れる）。
- **テスト。** `Cybertrain::Scheduler.run_due(now)` はティックを 1 回、`Cybertrain::Job.work_one(now)` はジョブを 1 つ、自分で選んだエポック時刻で実行するので、テストがスリープすることはありません。

cron の構文も、ジョブの優先度や一意性も、`deliver_later` もありません：メールを送るジョブは自分で `Cybertrain::Mailer` を呼びます（[メールを送る](external-services.md#sending-e-mail)）。これが扱うのは「後で送る」と「N 秒ごとに実行する」です（`docs/design.md` D28）。

## プロセスの役割

1 つのバイナリが 3 つの役割で動きます。デフォルトでは、Puma の中で Solid Queue を動かす `rails server` と同じく、`./<app> server` がすべてを行います。残りの 2 つを使うと、デプロイは同じイメージと同じデータベースのまま、作業をプロセスやコンテナーに分けられます：

| コマンド | 実行するもの | 待ち受け |
| --- | --- | --- |
| `./<app> server [PORT]` | HTTP、[ストリームのエンドポイント](realtime.md#which-process-does-what)、そして `CYBERTRAIN_WORKER=0` でなければ定期タスク、ジョブスレッド、WebSocket のフィード | する |
| `./<app> worker` | 定期タスク（リースにより一度に 1 プロセス）、ジョブスレッド、ハートビートと回収 | しない |
| `./<app> feeds [NAME...]` | [WebSocket のフィード](external-services.md#consuming-websocket-feeds)のすべて、または名前を挙げたもの | しない |

- `worker` と `feeds` はバナー（`=> worker: 3 job threads, 2 scheduled tasks`）を出し、`SIGTERM` まで動き、それからサーバーと同じように止まります。これらは常に自分の作業を行います：Web の役割のために設定した `CYBERTRAIN_WORKER=0` では止まりません。
- 名前を付けた `feeds` はその購読だけを動かし（フィードごとに 1 つのコンテナー）、未知の名前は、登録された名前の一覧を出して起動を止めます。フィードを専用のプロセスで動かすときは、サーバーに `CYBERTRAIN_WORKER=0` を設定してください。そうしないと、どのプロセスもすべてのフィードを受信します。
- よくある分け方：プロキシの後ろに `CYBERTRAIN_WORKER=0` の `server`、1 つ以上の `worker`、購読があれば `feeds`。`cybertrain new` は `config/deploy.yml` に `web` と `worker` の役割（とコメントにした `feeds`）を書きます。systemd のユニットは [docs/deploy.en.md](../deploy.en.md) のパート 7「Splitting the roles」にあります。
- **ハートビートのないリリースから上げるとき**：最初の新しいプロセスを起動する前に、古いプロセスをすべて止めてください。古いプロセスはハートビートを書かないので、新しいワーカーは、古いワーカーがまだ実行しているジョブを放棄されたものとして取ってしまいます。
- `Cybertrain::Main.worker?(ARGV)` と `Main.feeds?(ARGV)` は、`Main.server?(ARGV)` と同じく、`bin/<app>.rb` にどの役割を起動しているかを教えます。

## コンソール

`./<app> console` は、アプリケーションのモデルを扱うプロンプトです。Spinel には `eval` がないので、Ruby は実行しません：テンプレートの `<%= %>` が評価する式（[テンプレート言語](template-language.md#expressions)。ブロックは除く）に、モデル名を加えたものを評価します。開発中は `cybertrain spin run <app> -- console` で起動します。

```console
$ ./blog console
Cybertrain console (production). Type help for commands, exit to quit.
>> Article.where(title: "Hello").count
1
>> a = Article.find(1)
#<Article id: 1, title: "Hello", body: "First post", created_at: 2026-11-05 10:00:00 UTC, updated_at: 2026-11-05 10:00:00 UTC>
>> a.update(title: "Hello again")
true
```

- モデル名はそのリレーション（`Article`）で、`where`、`where_like`、`order`、`limit`、`offset`、`page`、`first`、`last`、`find`、`find_by`、`to_a`、`count`、`exists?`、`pluck_str` / `pluck_int` / `pluck_float`、`sum_int`、`count_by`、`delete_all`、`to_sql`、`create` が使えます。レコードには属性とメソッド、`update`、`save`、`destroy`、`reload`、`valid?`、`errors`、`attributes` があります。`help` がすべてを一覧にします。
- `x = expr` は値を後の行のために取っておき、`_` は直前の値です。`sql "..."` は SQL を実行して行を表として出力し、`tables` はテーブルを一覧にし、`exit`、`quit`、Ctrl-D で終わります。
- パースできない行はそのエラーを、例外を出した行は `Class: message` を出力し、プロンプトに戻ります。バイナリの値は `<N bytes>` と表示されます。
- 書き込みは本物です。本番では、コンソールは最初にバナーでそう告げます。

`./<app> dbconsole` は、Rails の `dbconsole` と同じく、設定されたデータベース（`CYBERTRAIN_DATABASE`）で `sqlite3` のシェルを開きます。`sqlite3` コマンドがインストールされている必要があり、その終了ステータスをそのまま返します。どちらのコマンドも、スケジューラー、ジョブ、フィードは始めません。

## 運用：バックアップ、VACUUM、ヘルスチェック

デプロイしたアプリケーションのデータは 1 つの SQLite ファイルなので、バイナリはそうしたアプリケーションに必要な 3 つの運用ツールを備えています。ファイルアップロードのあるアプリケーションは、そのバイト列もアップロードのルート（`upload_root`。デフォルトは `storage/uploads/`）の下に置きます：このディレクトリもデータベースと一緒にバックアップ・復元してください。そうしないと、復元したレコードが存在しないファイルを指すことになります（[ファイルアップロードを追加する](tutorial.md#attachments)）。

**バックアップ。** `./<app> db backup PATH` は、サーバーを動かしたまま、設定されたデータベース（`CYBERTRAIN_DATABASE`）の一貫したコピーを書き出します：SQLite の `VACUUM INTO`（3.27 以降。バイナリが確認します）が 1 つのスナップショットを読み、WAL のもとでは、その間もサーバーの書き込みは続きます。コピーは `PATH` の隣の一時ファイルに書き込まれ、そのファイルはモード 0600 で排他的に作成され（ファイルにはパスワードのダイジェストとセッションのトークンが含まれます）、fsync された後にはじめて `PATH` にリネームされます。そのため、失敗したり中断したりしたコピーが本来の名前で不完全なファイルを残すことはありません（一時ファイルは削除されます）。既存の `PATH` は、`--force` を渡さない限り拒否されます。データベース自体が書き込み先になることは決してなく、`:memory:` のデータベースがコピー元になることもありません。

```sh
./blog db backup /srv/blog/backups/before-upgrade.sqlite3
./blog db backup /srv/blog/backups/ --keep 14    # blog-20261025T031500Z.sqlite3、新しい 14 個を残す
```

`/` で終わる書き込み先（または既存のディレクトリ）には、UTC で日付の入った名前 `<app>-<YYYYmmddTHHMMSSZ>.sqlite3` が付けられ、ディレクトリが存在しなければモード 0700 で作成されます。`--keep N` は、そのうえで、ちょうどその形の名前を持つファイルのうち N 個を超える古いものを削除し、そこにあるそれ以外のものには触れません。復元は、サーバーを止めた状態でバックアップをデータベースファイルの上にコピーすることです（そして、その隣にあるファイルの `-wal` と `-shm` を削除します）。

**VACUUM。** 行を削除すると、ファイルに空きページが残ります。`./<app> db vacuum` は `VACUUM` を実行してから `PRAGMA wal_checkpoint(TRUNCATE)` を実行するので、作り直されたページがデータベースファイルに届き、ファイルは新しいサイズに切り詰められ、WAL は空になります。前後のディスク上のサイズ（データベースと WAL の合計）を表示します。`VACUUM` はファイル全体を書き直し、その間は書き込みロックを保持するので、アプリケーションが静かなときに実行してください。読み手がいてチェックポイントが完了しない場合はその旨を伝え、WAL は後のチェックポイントで縮みます。

**バックアップはサーバーの外で実行する。** SQLite の呼び出しは戻るまで OS のワーカーを占有するので、`Scheduler` のタスクで大きな `VACUUM INTO` を行うと、コピーにかかる間ずっとリクエスト（`SPINEL_WORKERS=1` ではそのすべて）が止まります。代わりに cron や systemd のタイマーから、別のプロセスとしてコマンドを実行してください：

```sh
# アプリのユーザーの crontab：毎晩 03:15 に実行し、2 週間分を残す
15 3 * * * cd /srv/blog/current && ./blog db backup /srv/blog/backups/ --keep 14
```

自分でバックアップを取りたいアプリケーションは、SQL を自分のスレッドで実行するのではなく、定期タスクから自分自身のバイナリを子プロセスとして実行できます：`system` が子プロセスを待つのはスケジューラーのスレッドだけで、その間もリクエストは配信され続けます（`system` は引数のリストで使い、リクエストのデータを含む文字列では決して使わないでください）。`health_worker_stale` より長くかかるコピーの間は、終わるまでヘルスチェックが `worker stale` を返します。

```ruby
# config/app.rb。自身のディレクトリ（dist/）から起動された、配信を行うバイナリで
Cybertrain::Scheduler.every(86_400, "nightly backup") do
  system("./blog", "db", "backup", "storage/backups/", "--keep", "14")
end
```

**ヘルスチェック。** ヘルスチェックが有効な間（デフォルトで有効です。空の `config.health_path` で無効になります）、配信を行うアプリケーションは、静的ファイル、セッション、CSRF、ルーターより前に `GET /up`（と `HEAD`）に応答します：コントローラーは関与せず、ログインの `before_action` がリダイレクトすることもなく、cookie も設定しません。`SELECT count(*) FROM sqlite_master` を実行し（これはファイルからスキーマのページを読む必要があります。素の `SELECT 1` はファイルに触れません）、`Cache-Control: no-store` 付きの `text/plain` で応答します：

| ステータス | ボディ | いつ |
| --- | --- | --- |
| 200 | `ok` | クエリが成功した |
| 503 | `database unavailable` | `Cybertrain::DB::Error` が出た（ファイルがない、または読めない、プールが閉じている） |
| 503 | `worker stale` | バックグラウンドの `Scheduler` が動いていて、その最後のティックが `health_worker_stale` 秒（300）より古い：タスクが詰まっているか、あまりにも長く動いている |

ポーリングは他のリクエストと同じようにログに記録されます（2 行）。パスは `config.health_path`（`CYBERTRAIN_HEALTH_PATH`。デフォルトは `/up`。空の値でチェックが無効になり、そのパスは以前と同じく `public/` とルーターに進みます）です。ロードバランサー、kamal-proxy、デプロイスクリプトがこれをポーリングできます。`cybertrain new` が書き出し、その Kamal の設定が今もポーリングしている `public/up.html` は、プロセスが HTTP に応答することを示すだけです。
