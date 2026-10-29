---
source_sha256: 438fc2c71e978981341d9c6453c440e4ddf31336c561b3788126cfef4875f9ec
---
# バックグラウンド処理と運用

## バックグラウンド処理

リクエストの外で何かをしなければならないアプリケーション（レスポンスを返した後に通知を送る、1 時間ごとに古い行を掃除する、失敗した呼び出しを再試行する）は、それをフレームワークに登録します。フレームワークは、配信を行うプロセスの 1 本のバックグラウンドスレッドでそれを実行します：

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

- **いつ実行されるか。** スレッドは、バイナリが配信を行うとき（`./<app>`、`./<app> server`）、起動処理がデータベースに接続し、ポートをバインドし、`SPINEL_WORKERS` を設定した後に始まります。`migrate`、`db ...`、`Main.command` のコマンドでは決して始まらず、`Cybertrain::Test::Client` でも始まりません。タスクは開始から `seconds` 秒後に初めて実行され、その後は各実行の開始から `seconds` 秒後に実行されます。各実行は rescue で包まれており、`[ERROR] Scheduled task
  "name" failed: ...` をログに出してループは続きます。ブロックは引数を取りません（Spinel には `instance_eval` がありません）。`Cybertrain::Scheduler.last_tick` は最後のティックのエポック秒で、自前のヘルスチェックに使えます。
- **ジョブ。** `Job.enqueue` は `cybertrain_jobs` テーブルに行を追加します。このテーブルはフレームワークが自分で作り（最初の使用時に `CREATE TABLE IF NOT EXISTS`）、`db/schema.rb` には含めません。ペイロードは String です：構造化されたデータは JSON でエンコードしてください。`DB.transaction` の中では、行は他のものと一緒にコミットまたはロールバックされます。ワーカーは `job_poll_interval` 秒（5）ごとにポーリングするスケジューラーのタスクで、期限の来た最も古いジョブを短い `BEGIN IMMEDIATE` トランザクションで確保し、そのハンドラーをトランザクションの外で実行して、`done` にします。例外を出したハンドラーは 1 分、5 分、15 分、その後は 60 分後に再試行され、`last_error` には `Class: message`（最大 1000 文字）が入ります。これは `job_max_attempts`（5）回の試行が失敗するまで続き、その後、行は `failed` になって、調べられるように残ります。種類にハンドラーのないジョブはすぐに `failed` になります。`Job.enqueue` は登録されていない種類を拒否します。クラッシュしたプロセスが `running` のまま残した行は、ワーカーの開始時にキューに戻されます。`Job.state_count("failed")` と `Job.prune_done(before_epoch)` は、ヘルスページや後片付けに役立ちます。
- **データベースごとにワーカーは 1 つ。** 配信を行うすべてのプロセスは、`CYBERTRAIN_WORKER=0`（`config.worker = false`）でない限りスレッドを実行します：複数のプロセスが 1 つの SQLite ファイルを共有する場合は、1 つを除いてすべてで無効にしてください。そうしないと、各定期タスクがプロセスごとに 1 回実行されます。
- **タスクは短く保つ。** タスクとハンドラーはその 1 本のスレッドで一度に 1 つずつ実行され、SQLite の呼び出しは戻るまで OS のワーカーを占有します：`SPINEL_WORKERS=1`（デフォルト）では、長いクエリはその間すべてのリクエストを止めてしまいます。大きな作業は一度に済ませず、分割してください（1 回の実行で 1000 行ずつ削除する、項目ごとにジョブを 1 つキューに入れる）。
- **テスト。** `Cybertrain::Scheduler.run_due(now)` はティックを 1 回、`Cybertrain::Job.work_one(now)` はジョブを 1 つ、自分で選んだエポック時刻で実行するので、テストがスリープすることはありません。

cron の構文も、ジョブの優先度や一意性も、`deliver_later` もありません：メールを送るジョブは自分で `Cybertrain::Mailer` を呼びます（[メールを送る](external-services.md#sending-e-mail)）。これが扱うのは「後で送る」と「N 秒ごとに実行する」です（`docs/design.md` D28）。

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

自分でバックアップを取りたいアプリケーションは、SQL を自分のスレッドで実行するのではなく、定期タスクから自分自身のバイナリを子プロセスとして実行できます：`system` が子プロセスを待つのはスケジューラーのスレッドだけで、その間もリクエストは配信され続けます（Spinel には `Process.wait` がなく、それなしの `Process.spawn` はゾンビを残すので、`system` を引数のリストで使い、リクエストのデータを含む文字列では決して使わないでください）。`health_worker_stale` より長くかかるコピーの間は、終わるまでヘルスチェックが `worker stale` を返します。

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
