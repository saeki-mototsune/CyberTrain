---
source_sha256: cfa6f0569935ef285a8ec498ef98568a41931115dffe39d74948822f1ac5c8d3
---
# バックグラウンド処理と運用

## バックグラウンド処理

リクエストの外で何かをしなければならないアプリケーション（レスポンスを返した後に通知を送る、毎晩古い行を掃除する、失敗した呼び出しを再試行する）は、それをフレームワークに任せます。フレームワークは、配信を行うプロセス、または別のワーカープロセスのバックグラウンドスレッドでそれを実行します。ジョブは Rails と同じく `app/jobs/` のクラスです。ジョブと定期タスクには、`bin/<app>.rb` と `bin/db.rb` に `require "cybertrain/jobs"` が必要で、`cybertrain generate job` が追加します（[サブシステム](how-it-works.md#subsystems)）：

```ruby
# app/jobs/welcome_job.rb
class WelcomeJob < Cybertrain::Job::Base
  retry_on Cybertrain::Mailer::TimeoutError, wait: 60, attempts: 5
  discard_on ArgumentError

  def perform(args)
    user = User.find(Cybertrain::Cast.int(args["user_id"]))
    Cybertrain::Mailer.deliver(to: user.email, subject: "Welcome", body: "Hello!\n")
  end
end
```

```ruby
# アクションの中で、ユーザーを保存した後に
WelcomeJob.perform_later("user_id" => @user.id)
WelcomeJob.perform_in(600, "user_id" => @user.id)   # または perform_at(time, args)
```

```ruby
# config/app.rb（または bin/<app>.rb が Cybertrain::Main.run の前に require するファイル）
Cybertrain::Scheduler.cron("0 4 * * *", "nightly digest", job: "DigestJob")
Cybertrain::Scheduler.every(300, "refresh rates") { Rates.refresh }
```

- **どこで実行されるか。** ジョブは `job_threads` 本のジョブスレッド（3、`CYBERTRAIN_JOB_THREADS`）で、定期タスクはそれ専用の 1 本のスケジューラーのスレッドで実行されるので、長いジョブがタスクを遅らせることはありません。どちらも、バイナリが配信を行うとき（`./<app>`、`./<app> server`）か、ワーカーとして動くとき（`./<app> worker`。[プロセスの役割](#process-roles)を参照）に、起動処理がデータベースに接続し `SPINEL_WORKERS` を設定した後で始まります。`migrate`、`db ...`、`jobs ...`、`console`、`Main.command` のコマンドでは決して始まらず、`Cybertrain::Test::Client` でも始まりません。ジョブを require していれば、ジョブスレッドは、ジョブクラスのないアプリケーションでも、こうしたプロセスのすべてで始まります。フレームワークが自分のメールのジョブ（`Mailer.deliver_later`、[メールを送る](external-services.md#sending-e-mail)）を登録するからです。
- **テーブル。** ジョブは `cybertrain_jobs` の行です。このテーブルはフレームワークが自分で作り（最初の使用時に `CREATE TABLE IF NOT EXISTS`）、`db/schema.rb` には含めません。`DB.transaction` の中では、行は他のものと一緒にコミットまたはロールバックされます。各ジョブスレッドは、期限の来た最も古い行を短い `BEGIN IMMEDIATE` トランザクションで確保し、トランザクションの外で実行して、次を探します。期限の来たものがなければ `job_poll_interval` 秒（1）待つので、リクエストがキューに入れたジョブは 1 秒ほどで始まります。行の状態は `queued`、`running`、`done`、`failed`（再試行を使い切ったもの。調べられるように残ります）、`discarded`（`discard_on` が止めたもの）のどれかです。

### ジョブクラス

`spin run gen` は `app/jobs/` の下のすべてのファイルを読み（入れ子のディレクトリも。`Admin::ReportJob` は `app/jobs/admin/report_job.rb`）、`Cybertrain::Job::Base` を祖先に持つ各クラスのもう半分、つまり `perform_later`、`perform_at`、`perform_in`、`perform_now`、`job_kind` とそれを実行するコードを `gen/jobs.rb` に書き、クラスを登録します。`cybertrain generate job send_digest --retry Cybertrain::Mailer::TimeoutError:60:5` は、クラスのファイルとそのテストを書きます。

- **`args`** は `perform_later` に渡した Hash で、JSON として保存され、`Hash<String, Object>` として読み戻されます。値は `Cybertrain::Cast.int(args["user_id"])`、`Cast.str`、`Cast.hash`、`Cast.array` で絞り込んでください。ジョブが受け取るのはこの Hash 1 つです。レコードではなく id を渡してください（Rails の勧めでもあります）。`perform_later` は Hash でないものには `ArgumentError` を出し、引数なしなら `{}` を送ります。
- **キューに入れる。** `perform_later(args)`、`perform_at(time, args)`、`perform_in(seconds, args)` は行の id を返します。行の種類はクラス名です（`"WelcomeJob"`、`"Admin::ReportJob"`）。`perform_now(args)` は、キューも再試行ポリシーも rescue もなしに、呼び出したスレッドで `perform` を実行し、`nil` を返します。テストに向いた形です。
- **クラスの本体。** ジョブクラスはどれも `perform(args)` を定義します（定義も継承もしていないクラスはジェネレーターが拒否します）。`retry_on`、`discard_on`、`limits_concurrency` はテキストとして読まれ、1 行に 1 つ、リテラルの値で書きます（`wait:` には Integer か `:polynomially_longer`、`attempts:` と `to:` には Integer、`key:` には引用符で囲んだ String）。ブロック、ラムダ、`5.minutes`、ハッシュロケット、行末のコメントがあると、`spin run gen` はファイル、行、代わりに書くべきものを示して止まります。
- **どの例外クラスか。** `retry_on` や `discard_on` が挙げるのは、プログラムがそのジョブより前に定義するクラスです。組み込みのクラス（`ArgumentError`、`KeyError` など）、フレームワークの `...Error` クラスのどれか（必要な require はジェネレーターが足します）、または `app/models/`、`app/jobs/application_job.rb`、ジョブ自身のファイルのその行より上で定義されたアプリケーションのクラスです。それ以外だと `spin run gen` は止まります。Spinel では、プログラムが定義しないクラスを挙げる `rescue` が、すべての例外を飲み込むことがあるからです（spikes/NOTES.md のルール 89）。`Cybertrain::RecordNotFound` は受け付けるフレームワークのクラスに入っていないので、レコードがなくなっているかもしれないジョブは、`find_by` で探し、行より上に定義した自分のクラスを投げます（examples/blog の `NotifyCommentJob`）：

  ```ruby
  class NotifyCommentJob < Cybertrain::Job::Base
    class CommentGone < StandardError
    end

    discard_on CommentGone

    def perform(args)
      comment = Comment.find_by(id: Cybertrain::Cast.int(args["comment_id"]))
      raise CommentGone, "comment was deleted; nothing to notify" if comment.nil?
      # ...
    end
  end
  ```

  報告とログに出る名前は入れ子の `NotifyCommentJob::CommentGone` です。
- **`ApplicationJob`。** `app/jobs/application_job.rb` の `ApplicationJob < Cybertrain::Job::Base` は、それ自体はジョブではありません。その `retry_on` と `discard_on` の行は、それを継承するすべてのジョブに、ジョブ自身の行の後で適用され、その `limits_concurrency` は何も宣言しないジョブに適用されます。ほかのジョブクラスは親になれます。その場合、それ自体も 1 つのジョブです。
- **短い形の `Job.handle`。** String の種類で登録したブロックには、クラスもジェネレーターも要りません。ブロックはペイロードの String を受け取り、下のデフォルトのポリシーに従います：

  ```ruby
  # config/app.rb
  Cybertrain::Job.handle("notify", concurrency: 1) { |payload| Notifier.post(payload) }

  # どこからでも、後で
  Cybertrain::Job.enqueue("notify", JSON.generate({ "text" => "Deployed" }), run_at: Time.now + 60)
  ```

  ジョブクラスと `Job.handle` の種類は 1 つの名前空間を共有するので、`Job.enqueue("WelcomeJob", json)` は `perform_later` と同じ行を追加します。`Job.enqueue` は登録されていない種類を拒否します。

### 再試行と破棄

- **デフォルトのポリシー。** クラスのどの行にも当てはまらない例外（と `Job.handle` のブロックのあらゆる例外）は、1 分、5 分、15 分、その後は 60 分後に再試行され、`last_error` には `Class: message`（最大 1000 文字）が入ります。これは `job_max_attempts`（5）回の試行が失敗するまで続き、その後、行は `failed` になります。ジョブのコードが出す `NotImplementedError`（まだ書いていないヘルパー）、`SystemStackError`、その他の `ScriptError` も、どれも `StandardError` ではありませんが、このポリシーに従います。`StandardError` の外のそれ以外の例外はログに出され（`ERROR Job thread N: ...`）、[報告](#error-reporting)され、ジョブのスレッドは動き続け、行は回復（後述）が拾うまで `running` のままです。
- **`retry_on Klass, wait: 60, attempts: 5`。** `wait:` は秒数（省略すると Rails のデフォルトの 3）か `:polynomially_longer`（`attempts ** 4 + 2` 秒：3、18、83、258、...）です。`attempts:`（省略すると 5）は、最初の 1 回を含むすべての試行を数えます。複数の行を書けます。例外に当てはまる（サブクラスも当てはまる）最初の行が勝つので、狭いクラスを先に書いてください。`discard_on ArgumentError` より前に `retry_on StandardError` を書くと、`ArgumentError` は再試行されます。
- **`discard_on Klass`** はすぐに止めます。行は `discarded` になり、`last_error` にエラーが入り、二度と再試行されません。ログには `ERROR [<Kind> <id>] [<request id>] job <id> (<Kind>) discarded: <Class>: <message>` と出て（リクエストがキューに入れたジョブならリクエスト ID 付き）、破棄は 1 回[報告](#error-reporting)されます。`job.max_attempts` は `job.attempt` と同じです。
- **`def retries_exhausted(error)`** は、`retry_on` の行の試行回数を使い切ったとき、行が本当に `failed` になった後で実行されます（別のワーカーが引き継いだ試行では決して実行されません。その試行はまだ成功するかもしれないからです）。Rails の `retry_on ... do |job, error|` のブロックにあたります。これが出した例外はログに出ます。
- **回収**（下記）もクラスに従います。`attempts: 20` のクラスの行で、5 回目の試行中にプロセスが死んだものは、`failed` ではなくキューに戻されます。

### 種類ごと、キーごとの同時実行数

`limits_concurrency to: 1, key: "account_id"` は、データベースを共有するすべてのプロセスを通じて、そのクラスのジョブが同時に `to:` 個までしか実行されないようにします。数えるのは `args["account_id"]` の値ごとです（`to:` だけならクラス全体で数えます。ブロックなら `Job.handle(kind, concurrency: n)` が同じことをします）。その間もほかの種類、ほかのキーは実行され続けます。キーのあるジョブを、そのキーを持たない `args` でキューに入れると `ArgumentError` になります。この上限は `running` の行を数えるので、ハートビートが続いているあいだだけ成り立ちます。ハートビートが古くなった後もまだ動いているジョブは、回収された行の次の実行と重なります（下記）。決して重なってはいけない作業には、独自のガードが必要です。

### 定期タスク

`Scheduler.every(seconds, name) { ... }` は `seconds` ごとにブロックを実行し、`Scheduler.cron(expr, name, ...)` は 5 つのフィールドの cron 式が当てはまる分に実行します：

```ruby
Cybertrain::Scheduler.cron("12 * * * *", "collect prices") { Prices.collect }
Cybertrain::Scheduler.cron("0 9 * * 1-5", "morning report", tz: "Asia/Tokyo",
                           job: "MorningReportJob", args: { "scope" => "all" })
Cybertrain::Scheduler.cron("*/5 * * * *", "poll feeds", catch_up: true) { Feeds.poll }
```

- **式。** 分、時、日、月、曜日で、`*`、`*/n`、`a-b`、`a,b`、`a-b/n` と、名前 `jan`〜`dec` と `sun`〜`sat` が使えます（曜日の `0` と `7` は日曜日）。`@hourly` のたぐいは受け付けません。解釈できない式や決して当てはまらない式は、`config/app.rb` を読み込むときにタスク名を挙げて `ArgumentError` を出すので、起動が止まります。
- **タイムゾーン。** `tz:` は IANA のゾーンを指定します（[タイムゾーン](configuration.md#time-zones)）。指定がなければ、タスクは `scheduler_tz`（`CYBERTRAIN_SCHEDULER_TZ`。設定しなければアプリケーションの `time_zone` に従います）で読まれます。夏時間で飛ばされる時刻は、その日は実行されません。秋の切り替えで繰り返される 1 時間では、時のフィールドが `*` で始まる式は両方の回に実行され、時が固定された式は 1 回だけ実行されます。Vixie cron と同じです。
- **`job:`** はジョブの種類（String のクラス名か、`Job.handle` の種類）を、`args:` はその引数を指定します。このときタスクはジョブをキューに入れるだけです。本格的な作業のあるタスクはこうすべきです。未知の種類は、登録された種類の一覧を出して起動を止めます。
- **時刻表** はデータベースに保存されます（`cybertrain_schedules`。`db/schema.rb` には含めません）。各タスクが最後に実行された時刻と、次に実行される時刻です。再起動しても、別のプロセスが主導権を取っても、そこから続きます。何も動いていない間に時刻が過ぎた `every` のタスクは、起動時に 1 回実行されます。何も動いていない間に過ぎた `cron` の枠は飛ばされます（cron の決まり）。ただしタスクが `catch_up: true` なら、起動時に 1 回実行されます。プロセスは動いていたのに、どのリーダーも実行しなかった枠（リースが持ち主を変えたとき）は、引き継いだときに 1 回実行されます。名前を変えたり消したりしたタスクの行は、次の起動まで残ります。まだ一度も実行されていないタスクは、前のリリースが保存した次の実行時刻より今のスケジュールのほうが早ければ、今のスケジュールに従います（初回の前に毎週から毎時に変えたタスクは、1 時間以内に実行されます）。
- **タスクの実行のされ方。** ブロックはスケジューラーのスレッドで、一度に 1 つずつ実行されます。各実行は rescue で包まれており、`ERROR [schedule:name] Scheduled task "name" failed: ...` をログに出して報告し、ループは続きます。ブロックは引数を取りません（Spinel には `instance_eval` がありません）。SQLite の呼び出しは戻るまで OS のワーカーを占有します。`SPINEL_WORKERS=1`（デフォルト）では、長いクエリはその間すべてのリクエストとほかのすべてのスレッドを止めてしまいます。本格的な作業のあるタスクはジョブに任せ（`job:`、またはブロックから `Job.enqueue`）、大きな作業は分割してください（1 回の実行で 1000 行、項目ごとにジョブを 1 つ）。`Cybertrain::Scheduler.last_tick` は最後のティックのエポック秒で、自前のヘルスチェックに使えます。

### ジョブページと `jobs` コマンド

```ruby
# config/routes.rb
Cybertrain::Routes.draw do
  jobs_page "/admin/jobs", before_action: :require_admin, skip_before_action: :require_authentication
end
```

`jobs_page` が載せるページには、状態ごとの行数、キューにある数と次の期限、`failed` と `discarded` の行（種類、引数、エラー、試行回数、時刻）、`running` の行（誰が確保したか、ハートビートがどれだけ古いか）が、リストごとに `jobs_page_per_page`（50、`CYBERTRAIN_JOBS_PAGE_PER_PAGE`）行ずつ並びます。失敗した行は再試行（すぐにキューに戻し、試行回数を 0 に）、破棄、削除でき、破棄された行は再試行と削除ができ、失敗した行すべてを一度に再試行または破棄することもできます。どの操作も `failed` と `discarded` の行にしか触れないので、ワーカーが確保したばかりの行はそのままです。

- 生成されるコントローラーは `ApplicationController` を継承するので、アプリケーションのレイアウト、ヘルパー、CSRF 保護が効きます。`before_action:` はそのメソッドの 1 つを指定します。拒否するには、そのメソッドがレンダーかリダイレクトをしなければなりません。`cybertrain generate authentication` は、そのコンサーンの `require_admin`（管理者がサインインしていなければ 404。[管理者ユーザー](authentication.md#admin-users-and-the-jobs-page)）を使って上の行を描きます。`before_action:` がなければページは誰にでも開かれ、`spin run gen` はそのことを警告する行を出します。
- `skip_before_action:` は、ページで実行しない継承された before コールバックを 1 つ指定します。`:require_authentication` を指定すると、訪問者には `require_admin` だけが答え、サインインへのリダイレクトではなく 404 を返します。gen は、`before_action:` のない場合と、`before_action:` そのものを指す場合を拒否します。
- ページのボタンは CSRF トークン付きのフォームです。ページのパスを `csrf_exempt_prefixes` に含めないでください。除外されたプレフィックスの下では、それらのフォームはどのサイトからでも受け付けられてしまいます。

シェルからは、`./<app> jobs` が設定されたデータベースに対して同じことをします（スレッドは起動しません）：

```sh
./blog jobs list               # 失敗した行を新しい順に（新しい 1000 行まで）。ほかに list queued|running|done|discarded
./blog jobs retry 42           # または retry --all（失敗した行すべて）
./blog jobs discard 42
./blog jobs delete 42
./blog jobs prune --before 30  # 30 日より古い failed と discarded の行を消す（デフォルトは 7 日）
```

`done` の行は、何かが消すまで残ります。タスクから `Job.prune_done(before_epoch)` を呼んでください（`Cybertrain::Scheduler.cron("0 3 * * *", "prune done jobs") { Cybertrain::Job.prune_done(Time.now.to_i - 7 * 86_400) }`）。`Job.state_count("failed")` は自前のヘルスページに使えます。

### 複数のワーカー、少なくとも 1 回、停止

- **データベースごとに複数のワーカー。** ジョブを実行するプロセスはどれも、`job_heartbeat_interval`（30 秒）ごとに実行中のジョブのハートビートを書きます。ハートビートが `job_heartbeat_stale` より古い `running` の行（クラッシュしたプロセスや、ジョブの途中で止められたプロセスのもの）は、次に見たプロセスが、その開始時とその後 1 分に 1 回、キューに戻します。ただしその試行が最後の試行だったとき（`job_max_attempts` と、クラスの最大の `attempts:` の大きいほう）は、行は `failed` のままになり、`last_error` には `process stopped (heartbeat stale)` が入ります。プロセスを落とすジョブが永遠に再試行されることはありません。定期タスクは一度に 1 つのプロセスでしか実行されません。プロセスはデータベースのリース（`cybertrain_leases`。ティックごとに更新、`scheduler_lease_ttl` は 30 秒）を共有し、その保持者だけが期限の来たタスクを実行します。保持者が更新をやめると、別のプロセスが引き継ぎます。リースは各タスクの前に更新され、タスクの実行中には更新されないので、ttl より長いタスクは次の保持者のタスクと重なることがあります。タスクは短く、繰り返しても安全に書いてください。こうして、2 つの `worker` プロセスや、サーバーとワーカーが 1 つの SQLite ファイルを共有できます。`CYBERTRAIN_WORKER=0` は、HTTP だけを提供すべき `server` プロセスでジョブ、タスク、フィードを止めます。
- **少なくとも 1 回。** ジョブは 2 回実行されることがあります。強制終了されたプロセスや、`job_heartbeat_stale`（300 秒）より長く止まったプロセスは、別のプロセスが行を取り戻したときにまだジョブを実行しているかもしれません。数えられるのは、その行を保持しているクレームの結果だけです（先のクレームが遅れて書いた結果は捨てられます）が、ジョブの副作用は 2 回起きています。どのジョブキューでもそうであるように、もう一度実行しても安全なジョブを書いてください（メールがもう送られたかを確かめる、insert ではなく upsert する）。定期タスクも、同じ理由で、リーダーが替わるときに 2 回実行されることがあります。
- **停止。** `SIGTERM` を受けると、ジョブスレッドは新しいジョブの確保をやめ、プロセスは実行中のジョブを最大 `job_drain_timeout`（10 秒）待ちます。それでも実行中のジョブの行は `running` のまま残ります。ハートビートは止まっているので、古くなった時点で別のプロセスがもう一度実行します。
- **テスト。** `WelcomeJob.perform_now(args)` はジョブを 1 つ、`Cybertrain::Scheduler.run_due(now)` はティックを 1 回、`Cybertrain::Job.work_one(now)` はキューのジョブを 1 つ、自分で選んだエポック時刻で実行するので、テストがスリープすることはありません。アサーションは[ジョブのテスト](testing.md#testing-jobs)にあります。

### 0.4 からの更新

- `cybertrain_jobs` に `concurrency_key` の列と `discarded` の状態が加わります。テーブルに最初に触れたプロセスが列を足します。状態を列挙するコード（`Job.state_count` を使うダッシュボード）は `discarded` を足してください。`Job.prune_done` が消すのは、これまでどおり `done` の行だけです。
- `every` のタスクは、再起動の後に最初からやり直すのではなく、時刻表から続きます。プロセスが止まっている間に過ぎた間隔は、起動時に 1 回実行されます。
- 既存の種類にキーを与えるとき（`limits_concurrency ... key:`）：ほかの更新と同じく、最初の新しいプロセスが起動する前に古いプロセスをすべて止めてください（[プロセスの役割](#process-roles)）。最初の新しいプロセスが、それ以前にキューに入った `queued` の行にキーを付けます（ペイロードにそのフィールドがない行の id はログに出します）。古いプロセスが残した `running` の行は、回収されるときにキーが付きます。
- `jobs` は組み込みのコマンドになりました。`jobs` という名前のアプリケーションのコマンドは、名前を変えてください。

まだないもの：ジョブの優先度、キューの名前と一意性、テスト用のインラインのジョブモード（テストは `perform_now` と `perform_enqueued_jobs` でまかなえます）。設計：`docs/design.md` D28 と D51〜D53。

## プロセスの役割

1 つのバイナリが 3 つの役割で動きます。デフォルトでは、Puma の中で Solid Queue を動かす `rails server` と同じく、`./<app> server` がすべてを行います。残りの 2 つを使うと、デプロイは同じイメージと同じデータベースのまま、作業をプロセスやコンテナーに分けられます：

| コマンド | 実行するもの | 待ち受け |
| --- | --- | --- |
| `./<app> server [PORT]` | HTTP、[ストリームのエンドポイント](realtime.md#which-process-does-what)、そして `CYBERTRAIN_WORKER=0` でなければ定期タスク、ジョブスレッド、WebSocket のフィード | する |
| `./<app> worker` | 定期タスク（リースにより一度に 1 プロセス）、ジョブスレッド、ハートビートと回収 | しない |
| `./<app> feeds [NAME...]` | [WebSocket のフィード](external-services.md#consuming-websocket-feeds)のすべて、または名前を挙げたもの | しない |

- `worker` と `feeds` はバナー（`=> worker: 3 job threads, 2 scheduled tasks`）を出し、`SIGTERM` か `SIGINT`（Ctrl-C）まで動き、それからサーバーと同じように止まります。これらは常に自分の作業を行います：Web の役割のために設定した `CYBERTRAIN_WORKER=0` では止まりません。
- 名前を付けた `feeds` はその購読だけを動かし（フィードごとに 1 つのコンテナー）、未知の名前は、登録された名前の一覧を出して起動を止めます。フィードを専用のプロセスで動かすときは、サーバーに `CYBERTRAIN_WORKER=0` を設定してください。そうしないと、どのプロセスもすべてのフィードを受信します。
- `feeds` のプロセスはスレッドが死んだフィードを再起動し、同じフィードが死に続けると（`feed_restart_window` のうちに `feed_restart_limit` 回の再起動）終了ステータス 1 で終わります。なので再起動ポリシーの下で動かしてください（Docker の `restart: unless-stopped`、systemd の `Restart=always`）。詳しくは[WebSocket フィードを購読する](external-services.md#consuming-websocket-feeds)にあります。`./<app> feeds status` は、各フィードが最後に報告した状態を表示します。
- よくある分け方：プロキシの後ろに `CYBERTRAIN_WORKER=0` の `server`、1 つ以上の `worker`、購読があれば `feeds`。`cybertrain new` は `config/deploy.yml` に `web` と `worker` の役割（とコメントにした `feeds`）を書きます。systemd のユニットは [docs/deploy.en.md](../deploy.en.md) のパート 7「Splitting the roles」にあります。
- **ハートビートのないリリースから上げるとき**：最初の新しいプロセスを起動する前に、古いプロセスをすべて止めてください。古いプロセスはハートビートを書かないので、新しいワーカーは、古いワーカーがまだ実行しているジョブを放棄されたものとして取ってしまいます。
- `Cybertrain::Main.worker?(ARGV)` と `Main.feeds?(ARGV)` は、`Main.server?(ARGV)` と同じく、`bin/<app>.rb` にどの役割を起動しているかを教えます。
- `worker` には `bin/<app>.rb` に `require "cybertrain/jobs"` が、`feeds` には `require "cybertrain/feeds"`（`cybertrain/websocket` が読み込みます）が必要です。ないと、バイナリはどの行が足りないかを表示して 1 で終了します。

## キャッシュストア

`Cybertrain::Cache` は、答えをアプリケーション自身のデータベースにしばらく残し、次のリクエストが遅い API にもう一度尋ねなくて済むようにします。`require "cybertrain"` はこれを読み込みます。`cybertrain/core` のアプリケーションは `bin/<app>.rb` と `bin/db.rb`、または使う場所に `require "cybertrain/cache"` を追加します：

```ruby
require "cybertrain/cache"

text = Cybertrain::Cache.fetch("defillama/tvl", expires_in: 21_600, race_condition_ttl: 30) do
  client.get("https://api.llama.fi/tvl").body
end
data = Cybertrain::Cache.fetch_hash("prices/#{sym}", expires_in: 60) { { "usd" => price } }
count = Cybertrain::Cache.fetch_int("articles/count", expires_in: 60) { Article.count }
Cybertrain::Cache.write("import-lock", "1", expires_in: 300, unless_exist: true)   # 書いたときに true
```

- **値は String。** `fetch(key, expires_in:, race_condition_ttl:) { String }` は有効な値を返すか、ブロックを実行してその戻り値を保存します。`fetch_hash`、`fetch_array`、`fetch_int` は JSON か Integer のテキストを保存し、取り出すときに解釈するので、壊れたセルは期限が切れてブロックがもう一度実行されるまで `{}`、`[]`、`0` として読まれます（Spinel には `Marshal` がなく、1 つのメソッドは 1 つの型しか返せません）。残りは `read(key)`（String か nil）、`write(key, value, expires_in:, unless_exist:)`、`delete`、`exist?`、`increment(key, by: 1, expires_in:)`（1 つの文。期限の切れたカウンターは `by` からやり直します。`expires_in:` はカウンターの開始時にだけ期限を決めるので、1 分間のカウンターはその 1 分を数えます）、`clear` です。
- **期限。** `expires_in:` は秒数です。デフォルトの `0` は期限切れになりません（負の値も同じです）。`race_condition_ttl: n`：行の期限が切れていると、最初の呼び出し元がそれを `n` 秒延ばして新しい値を計算し、その間ほかの呼び出し元は古い値を読み続けます。Rails と同じです。これがなければ、期限の切れたキーの呼び出し元が全員計算します。例外を出したブロックは何も書きません。
- **保存先。** 行は `cybertrain_cache` にあります。このテーブルはフレームワークが最初の使用時に作り、`db/schema.rb` には含めません。メモリには何も保持しません。読み出しはどれも SELECT で、SQLite はそのページキャッシュから答えます。書き込みはどれもデータベースの書き込みロックを取り、自分の行を書くリクエストはそれを待ちます。忙しいリクエストの経路で書くのではなく、ジョブが作るものや、変わるよりはるかに頻繁に読まれる値をキャッシュしてください。
- **掃除。** ジョブが読み込まれていれば、このファイルを require すると、定期タスク `"cybertrain cache prune"` が登録されます。これは `cache_prune_interval` 秒（300、`CYBERTRAIN_CACHE_PRUNE_INTERVAL`）ごとに、期限の切れた行を 1 文あたり 1000 行ずつ消します。ジョブがなければキャッシュが自分で掃除します：プロセスの最初の書き込みと、`cache_prune_interval` ごとの最初の書き込みが、期限の切れた行を最大 1000 行消します。間隔はファイルを require したときに読まれます。環境変数を設定するか、require より前に実行される `Cybertrain.configure` のブロックで `c.cache_prune_interval` を設定してください。`Cache.prune(now)` はテスト用の入り口です。

まだないもの：キャッシュ専用のデータベースファイル、サイズの上限、メモリ上のストア。設計：`docs/design.md` D54。

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
- `x = expr` は値を後の行のために取っておき、`_` は直前の値です。`sql "..."` は SQL を実行して行を表として出力し（セルの制御文字は `\e` や `\n` とエスケープするので、データが端末にエスケープシーケンスを送ることも表を崩すこともありません。NUL バイトを含む TEXT の値は、生の SQL で読むときと同じく、読み出しの時点で NUL のところで切れます。BLOB はすべてのバイトを保ちます）、`tables` はテーブルを一覧にし、`exit`、`quit`、Ctrl-D で終わります。
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
| 503 | `feed stale` | このプロセスかほかのプロセスの [WebSocket フィード](external-services.md#consuming-websocket-feeds)が、`health_feed_stale` 秒（180）のあいだ状態を報告していない、または何も（pong さえ）受け取っていない。[フィードのヘルス](realtime.md#feed-health)を参照 |

ポーリングは他のリクエストと同じようにログに記録されます（2 行）。パスは `config.health_path`（`CYBERTRAIN_HEALTH_PATH`。デフォルトは `/up`。空の値でチェックが無効になり、そのパスは以前と同じく `public/` とルーターに進みます）です。ロードバランサー、kamal-proxy、デプロイスクリプトがこれをポーリングできます。`cybertrain new` が書き出し、その Kamal の設定が今もポーリングしている `public/up.html` は、プロセスが HTTP に応答することを示すだけです。

## ログ

フレームワークとアプリケーションは `Cybertrain.logger` を通してログを出します。1 つのメッセージが標準出力の 1 行になり、行ごとにフラッシュされます。Twelve-Factor のアプリケーションと同じで、systemd の journal、Kamal、Docker がそれを集めます：

```text 出力 — ./blog server
2026-11-14T09:30:00.120Z INFO [3f2a9c1e-6c1d-4f0b-9a52-0d1e2f3a4b5c] Started GET "/articles" for 127.0.0.1
2026-11-14T09:30:00.132Z INFO [3f2a9c1e-6c1d-4f0b-9a52-0d1e2f3a4b5c] Completed 200 in 12ms
2026-11-14T09:30:01.002Z ERROR [WelcomeJob 42] [3f2a9c1e-6c1d-4f0b-9a52-0d1e2f3a4b5c] job 42 (WelcomeJob) attempt 1 of 5 failed: RuntimeError: smtp down; retrying in 60 s
2026-11-14T09:30:02.410Z WARN [feed:prices] WebSocket "prices" silent for 60s; reconnecting
```

1 行は、ミリ秒までの UTC の時刻（テストでは `travel_to` に従います）、大文字のレベル、角括弧に入ったタグ、メッセージです。`Cybertrain.logger` には `debug`、`info`、`warn`、`error`、`fatal` があり、どれも String を 1 つ取ります。複数のスレッドの行が混ざることはありません。各行は丸ごと組み立ててから、その書き込みの間だけ持つロックの下で 1 回の write で書きます。失敗した書き込み（閉じたパイプ）はその行を捨てます。ログ出力が呼び出し元に例外を投げることはありません。標準出力を読む側が読むのをやめると（パイプが満杯になると）、また読むまでログを出すスレッドがすべて止まるので、ログ収集を止めないでください。

**レベル。** `config/app.rb` の `c.log_level`、または `CYBERTRAIN_LOG_LEVEL`（`debug`、`info`、`warn`、`error`、`fatal`、`none`。大文字小文字は問いません）が、書き出す最も低いレベルです。デフォルトは `:info` です。`:none` はリクエストログも止めますが、エラーの行は書きます。`config/app.rb` での代入が変数より優先されます。それ以外の値では起動が止まります：`error: log_level must be :debug, :info, :warn, :error, :fatal or :none (got :verbose)`。

**JSON の行。** `c.log_format = :json`（または `CYBERTRAIN_LOG_FORMAT=json`）にすると、ログ収集ツール向けに 1 行に 1 つの JSON オブジェクトを書きます：

```json
{"time":"2026-11-14T09:30:00.132Z","level":"INFO","request_id":"3f2a9c1e-6c1d-4f0b-9a52-0d1e2f3a4b5c","tags":[],"message":"Completed 200 in 12ms"}
```

`request_id` は、その行が ID を持ち（リクエストの中、またはリクエストがキューに入れたジョブの中）、`log_tags` がそれを表示するときだけ入ります。`tags` にはほかのタグが順に入ります。メッセージ（またはタグ）が UTF-8 として正しくないときは、その 0x80 以上のバイトがすべて、正しい文字のバイトも含めて、JSON ではエスケープ `\ufffd` として書かれます。正しくないバイトが 1 つあると、そのメッセージの ASCII 以外の文字がすべて置換文字になります。正しいメッセージはそのまま書かれ、テキストの行ではログに渡されたバイトのまま残ります。`:text` と `:json` 以外の形式では起動が止まります：`error: log_format must be :text or :json (got :xml)`。起動時の最初の行（テスト以外での `mail_delivery_method :test` の警告）は形式に従います。値が正しくないアプリケーション設定（`setting_int`、`setting_bool` がデフォルトに戻るとき）についての警告は、形式が決まる前の `config/app.rb` の実行中に出るので、常にテキストの行です。

レベルと形式は `./<app> server`、`worker`、`feeds` に加えて、登録したコマンド、`jobs`、`console` にも効きます。これらは未知の値を同じメッセージで拒み、データベースを開く前に終了ステータス 1 で終わります。`migrate`、`db`、`dbconsole` には効きません。これらの行は `info` レベルのテキストです。

### リクエスト ID

すべてのリクエストに ID（バージョン 4 の UUID）が付きます。アクションは `request.request_id` で読み、レスポンスは `X-Request-Id` で返します。ホスト確認の 403、`force_ssl` の https へのリダイレクト、エラーページ、開発用の診断ページ、サーバー自身の 500 にも付きます。サーバーが読めないリクエストに、アプリケーションに渡す前に返す 400 と 413 には付きません。リクエストの実行中に出たすべての行は、その ID をタグとして（デフォルトの `log_tags` では最初のタグとして）持ちます。アプリケーション自身の `Cybertrain.logger.info` の行も、ストリーミングのボディ（`stream do ... end`、Server-Sent Events）や、リクエストが開いた WebSocket の接続も、開いている間ずっと同じです。

```ruby
Cybertrain.logger.info("export #{report.id} for #{request.request_id}")
```

プロキシの ID は、アプリケーションが信頼するプロキシからのものだけを使います。接続が信頼するプロキシ（`CYBERTRAIN_TRUSTED_PROXY` または `CYBERTRAIN_TRUSTED_PROXIES`。`request.client_ip` と同じ確認です。[プロキシの背後のクライアントアドレス](requests.md#the-client-address-behind-a-proxy)）から来て、その `X-Request-Id` が 1〜255 文字の ASCII の英字、数字、ハイフンなら、リクエストはその ID を使うので、プロキシのログとアプリケーションのログが同じ ID を共有します。それ以外の `X-Request-Id`（2 回送られたヘッダーも含む）は捨てて新しい ID を作ります。値を書き換えることはありません。

`c.log_tags` はリクエストのタグとその順序を決めます。デフォルトは `[:request_id]`、`[:request_id, :remote_ip]` で `request.client_ip` を足します（アドレスは個人データなのでデフォルトでは付けません）、`[]` で何も付けません（ヘッダーは送ります）。それ以外では起動が止まります：`error: log_tags may hold :request_id and :remote_ip (got :user_agent)`。

### タグ

`Cybertrain.logger.tagged` は、ブロックの間にこのスレッドで出たすべての行に、リクエストのタグの後ろにタグを足し、ブロックが終わると（例外を投げたときも）外します。ブロックの値を返します。入れ子にできます。ブロックなしの形はありません。

```ruby
Cybertrain.logger.tagged("billing", "order #{order.id}") do
  Cybertrain.logger.info("charged 300")
  # 2026-11-14T09:30:00.140Z INFO [3f2a9c1e-...] [billing] [order 7] charged 300
end
```

タグはスレッドのものです。自分で起こしたスレッドは、起こしたスレッドが何を持っていてもタグなしで始まります。フレームワークも自分の仕事に同じようにタグを付けます：

- **ジョブ。** 各試行の行は `[<JobClass> <id>]`（`Job.handle` のブロックのジョブならその種類）を持ち、続けてキューに入れたリクエストの ID を持ちます：`INFO [WelcomeJob 7] [3f2a9c1e-...] welcome 1`。ID は `log_tags` にかかわらずジョブの行（`cybertrain_jobs.request_id`）に記録され、`log_tags` に `:request_id` があるときに表示されます。ジョブがキューに入れたジョブは親の ID を記録し、定期タスク、フィード、コマンドがキューに入れたジョブは何も記録しません。
- **定期タスク。** タスクの実行中は `[schedule:<name>]`。失敗の行も含みます。
- **フィード。** フィードのスレッドが出すすべての行（コールバックの行も含む）に `[feed:<name>]`。スーパーバイザー自身のスレッドで出る再起動とあきらめの行にはタグがありません。

## エラー報告

`Cybertrain.error` は、リクエスト、ジョブの試行、定期タスク、フィードを終わらせた例外と、アプリケーションが自分で報告する例外を集め、アプリケーションが追加したサブスクライバーに渡し、DSN が設定されていれば Sentry（または GlitchTip）にも送ります。これはコアにあります。Sentry への送信はそれだけの 1 行で、`require "cybertrain"` が読み込み、`cybertrain/core` のアプリケーションは `bin/<app>.rb` に足します（`bin/db.rb` には足しません。[サブシステム](how-it-works.md#subsystems)）。`cybertrain new` は、この節の行をコメントにして書きます：`.env.example` の変数、`config/app.rb` のサブスクライバー、`config/deploy.yml` と `.kamal/secrets` の DSN、そして `bin/<app>.rb` のコメントのこの行です：

```ruby
require "cybertrain/error_reporter/sentry"   # bin/<app>.rb の require "cybertrain/core" の後
```

```ruby
# アプリケーションが rescue したものを、わかっていることと一緒に：
begin
  charge(order)
rescue PaymentError => e
  Cybertrain.error.report(e, context: { "order_id" => order.id })
end

# ブロックを実行し、投げたものを報告して、nil で続ける：
price = Cybertrain.error.handle(context: { "feed" => "prices" }) do
  parse_price(text)
end
```

`report(e, handled: true, context: {})` はすぐに nil を返します。報告はレポーター自身のスレッドで届けられます。コンテキストのキーと値は String になり、フレームワークが足すコンテキスト（ジョブの ID と試行回数）の上に重なります。`handle(context: {}) { }` はブロックの値を返します。ブロックが `StandardError`（または `JSON::ParserError`、`JSON::NestingError`）を投げたときは、それを報告して nil を返します。ブロックの中の `break v` で `handle` は `v` を返し、`return` は周りのメソッドから戻ります。どちらも呼び出し元に例外を投げることはありません。報告そのものが失敗したときは、error レベルで `error report failed: <Class>: <message>` とログに出ます。

**サブスクライバー。** サブスクライバーはアプリケーションのクラスで、`report(event)` を定義した `Cybertrain::ErrorSubscriber` のサブクラスです：

```ruby
# config/app.rb の、それを登録する行より上（bin/<app>.rb は app/ より前に
# config/app を読み込むので、ここでは app/ の下のクラスはまだ読み込まれていない）
class AuditSubscriber < Cybertrain::ErrorSubscriber
  def report(event)
    Cybertrain.logger.warn("reported #{event.error_class}: #{event.error_message} at #{event.error_where}")
  end
end
Cybertrain.error.subscribe(AuditSubscriber.new)
```

各サブスクライバーはすべての報告を、失敗したリクエストやジョブの中ではなく、レポーターのスレッドで受け取ります。例外を投げたサブスクライバーは error レベルで `error subscriber AuditSubscriber failed: <Class>: <message>` とログに出し、それ自体は報告しません。ほかのサブスクライバーはそのままイベントを受け取ります。イベントは String でできた値です：

| リーダー | 内容 |
| --- | --- |
| `error_class` | 例外のクラス名。名前空間付き（`"Cybertrain::DB::Error"`） |
| `error_message` | そのメッセージ |
| `error_where` | `"ArticlesController#create"`、`"request"`（アクションが動かなかった）、ジョブのクラスか種類、`"cybertrain mail"`、`"job thread"`、`"schedule:<name>"`、`"feed:<name>"`、または `""` |
| `error_request_id`、`error_request_method`、`error_request_path` | リクエストのもの。パスはクエリを除き、リクエストログと同じようにフィルタされます。ジョブの中では、キューに入れたリクエストの ID。リクエストの外では `""` |
| `error_environment`、`error_release` | `Cybertrain.config.env` と `c.release` |
| `error_handled` | `report` と `handle` では true、フレームワークが報告したものでは false |
| `error_context` | `Hash{String => String}`。アプリケーションのコンテキストと、ジョブの中では `job.id`、`job.attempt`、`job.max_attempts` |
| `error_backtrace` | `Array<String>`。`cybertrain build` のバイナリでは空（後述） |
| `error_occurred_at` | `Time`。クロックから |

**自分で何も書かなくても報告されるもの：**

- 500 で終わったリクエスト。1 回だけです。`Cybertrain::ClientError.status_for` が 500 以上に対応させる例外です。4xx（不正なパラメーター、CSRF の失敗、404）と、`rescue_from` が処理したものは報告しません。
- ジョブの失敗した試行（`where` はそのクラスか種類。コンテキストに `job.attempt` と `job.max_attempts`）。デフォルトのポリシー、`retry_on`、`discard_on` のどれでも報告されます。同じ種類の試行が 1 分以内に同じクラスとメッセージで報告されていれば、その試行はログに出ますが、もう一度は報告されません（[配送](#error-reporting)、後述）。デフォルトのポリシーでは最初の再試行まで 1 分待つので各試行が報告されますが、`retry_on ..., wait: 30` では報告された試行の 30 秒後の試行は報告されません。破棄は 1 回報告されます。`job.max_attempts` は、デフォルトのポリシーでは `job_max_attempts`、`retry_on` ではポリシーの `attempts:`、`discard_on` では破棄されたときの試行回数です。失敗した `deliver_later` のメールは `cybertrain mail` ジョブのものです。ジョブのスレッドのループから漏れた例外や、そこでのデータベースのエラーは `where` が `job thread` です。
- ブロックが例外を投げた定期タスク、または 5 年以内に次の実行がない `cron` タスク（`schedule:<name>`）。
- 例外を投げたフィードの `on_open`、`on_message`、`on_tick`、死んだフィードのスレッド、フィードをあきらめたスーパーバイザー（`Cybertrain::Background::FeedFailed`。裏にクラスのない名前だけで、メッセージは `feed <name> restarted <n> times in <w> s; exiting`）。どれも `feed:<name>` です。

報告しないもの：ストリーミングのボディを書いている間の例外（サーバーが `stream error:` とログに出します。レスポンスはもう始まっています）、ハンドラーのない種類のジョブ、そして開発中に、すでに報告された例外を表示している診断ページ自身が投げた例外。フレームワークが以前から出していたログの行はそのままで、報告はそれに加えて行われます。

**送らないもの。** パラメーター、ヘッダー、Cookie、セッション、クライアントのアドレス、クエリ文字列はイベントに入りません。リクエストのパスはリクエストログと同じようにフィルタされます。足されるのはアプリケーションが `context:` に入れたものだけです。例外のメッセージはフィルタしません。個人データを含むメッセージ（宛先を書いた SMTP サーバーの拒否）はそのまま送られます。

**配送。** 報告は 100 件のキューに入り、1 つのスレッドが届けます。同じクラス、メッセージ、`where` の報告は 1 分に 1 回までしかキューに入らないので、訪問者全員に同じメッセージで失敗するページでも報告は 1 分に 1 件です（ID を含むメッセージ、`Couldn't find Article with id=5` なら、メッセージごとに 1 件です）。キューが満杯のときは報告を捨てて数え、`error reports dropped: <n>` を warn レベルで 1 分に 1 回まで出します。サブスクライバーも DSN もない間は、何もキューに入らず、スレッドも起動しません。失敗した配送は `error delivery failed: <Class>: <message>` とログに出し、前のスレッドが終わっていれば次の報告が新しいスレッドを起動します。サーバー、ワーカー、feeds プロセスは止まるとき、サービスを止めた後、キューの報告を最大 2 秒待ちます。残ったものは失われます。開発中の再ビルドも待ちます。

**Sentry または GlitchTip に送る。** `bin/<app>.rb` にその行があれば、`CYBERTRAIN_SENTRY_DSN`（または `c.sentry_dsn`）をプロジェクトの DSN にすると、各報告を Sentry のイベントとして送ります：

```sh
CYBERTRAIN_SENTRY_DSN=https://<public key>@o1.ingest.sentry.io/42
CYBERTRAIN_RELEASE=2026.11.14-3f2a9c1    # 任意：イベントの release として送られる
CYBERTRAIN_ERROR_SAMPLE_RATE=0.25        # 任意：4 分の 1 を送る
```

- DSN は `http[s]://<public key>[:<secret>]@<host>[:<port>][/<path>]/<project id>` の形です（secret、Sentry の古い後半部分は無視します）。イベントは `<scheme>://<host>[:<port>][/<path>]/api/<project id>/envelope/` に送られ、Sentry と GlitchTip のどちらも受け付けます。キーを含むので、コミットするファイルではなくデプロイのシークレットに置いてください。読めない DSN では起動が止まり、どの部分かを示しますがキーは示しません：`error: sentry_dsn must look like https://<public key>@<host>/<project id>: the project id must be digits`。
- 送信側をリンクしていないプログラムで DSN を設定すると、起動が止まります：`error: CYBERTRAIN_SENTRY_DSN is set, but this program does not link the Sentry sender: add require "cybertrain/error_reporter/sentry" to bin/<app>.rb`。自分で作った送信側のクラス（`Cybertrain::ErrorReporter::Sender` のサブクラス）は、空でない名前を返す `sender_name` を定義します。そうしないと同じ拒否に当たります。
- `CYBERTRAIN_ERROR_SAMPLE_RATE`（`c.error_sample_rate`、1.0）は送る報告の割合で、0.0〜1.0 です。サブスクライバーはすべての報告を受け取ります。変数は数字に任意の `.数字` が続く形でなければならず、そうでなければ起動が止まります：`error: error_sample_rate must be a number from 0.0 to 1.0 (got "x")`。
- `CYBERTRAIN_RELEASE`（`c.release`。デフォルトは空）はバージョンかコミットを示します。検査はしません。
- 1 回の送信は最大 5 秒待ち、再試行はしません。拒否は warn レベルで `error report not sent: Sentry answered 429` とログに出し、接続の失敗も `error report not sent: <Class>: <message>` と出します。
- イベントには、クラスとメッセージ、トランザクションとしての `where`、環境、release、タグとしてのリクエスト ID、リクエストのメソッドとパス、`extra` としてのコンテキスト、そしてバックトレースがあればフレームが入ります。
- 呼び出しは `Cybertrain::HttpClient` と、そのプライベートアドレスへの防御を通ります（[外向きの HTTP](external-services.md#outbound-http)）。プライベートネットワークや同じマシンの GlitchTip には `CYBERTRAIN_HTTP_ALLOW_PRIVATE=1` が要り、これはアプリケーションのすべての外向きの呼び出しで防御を外します。

**バックトレース。** `cybertrain build` のバイナリは Spinel のリリースビルドで、その例外はバックトレースを持ちません。報告にはクラス、メッセージ、`where` が入ります。`--debug` ビルドと CRuby では、フレームが付きます。

`cybertrain test` は Sentry に何も送りません。`config/app.rb` が代入していない限り、エクスポートされた `CYBERTRAIN_SENTRY_DSN` を空にします。テストは代わりに DSN を `Test::SentryReceiver` に向けます（[ログとエラー報告のテスト](testing.md#testing-logs-and-error-reports)）。設計：[docs/design.md](../design.md) の D86 と D87。

### ログとエラー報告の 0.4 からの更新

- ログの行の形がすべて変わります。行頭の角括弧のレベル（`[INFO]`）が、時刻、レベル、タグに置き換わります：`2026-11-14T09:30:00.132Z INFO [<request id>] Completed 200 in 3ms`。ログを読むもの（スクリプトの `[ERROR]` の grep、アラート）も合わせて変えます。行を丸ごと探していたテストは、レベルとメッセージを別々に探します（`" ERROR "` とメッセージ。[0.4 からのアップグレード](testing.md#upgrading-from-04)）。
- すべてのレスポンスが `X-Request-Id` を持ちます。それを付けていたプロキシの値は、プロキシが信頼されているときだけ使われます。
- `cybertrain_jobs` に `request_id` の列が増えます。最初にテーブルに触ったプロセスが足します。
- フレームワークが `request_id` と `release`（どちらも String を返す）、`handle`（ブロックの値）という名前のメソッドを定義するようになりました。リーダーが別の型を返す同名のモデルの列（整数の `request_id`、外部キー）は、ビルドを止めることがあります。メソッド名はプログラム全体で戻り値の型が 1 つだからで（spikes/NOTES.md の規則 34）、gen は名前を変えません。列の名前を変えてください。
- `cybertrain test` は、`config/app.rb` が設定していない限り、エクスポートされた `CYBERTRAIN_LOG_FORMAT` と `CYBERTRAIN_SENTRY_DSN` を無視します（テストはテキストの行を読み、何も送りません）。`generate authentication` が書くパスワードのテストは、`with_config` の中で JSON の行を止めるようになりました。テストを `log_format :json` で動かしている、以前に生成したアプリケーションは、ジェネレーターを再実行するか、その変更を写してください。
- `require "cybertrain"` は、Sentry の送信側を通じて `HttpClient` と TLS 層をリンクするようになりました。
