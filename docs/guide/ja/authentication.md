---
source_sha256: bf76107df3cdd4c82d1f4ac76516e56c5642ba63dac0216c31cd68886477dd46
---
# 認証

`cybertrain generate authentication` は、Rails 8 のジェネレーターと同じくメールアドレスとパスワードによるサインインを、アプリケーションが所有するコードとして書き出します。Devise が加えるものも一緒です：メールによるパスワードリセット、任意のメールアドレス確認、ロックアウト、「ログインしたままにする」、アカウントページ、管理者ユーザー。

## 生成する

```shell ターミナル — blog/
cybertrain generate authentication                  # 公開のサインアップページ
cybertrain generate authentication --invite-only    # サインアップなし：ユーザーはコマンドラインか /setup から
cybertrain generate authentication --confirmable    # （どちらのモードでも）新しいアドレスはメールで確認
cybertrain db migrate
```

アプリケーションに書き出すもの：

| ファイル | 内容 |
| --- | --- |
| `db/migrate/*_create_users.rb`、`*_create_sessions.rb` | `users`（`email_address`、`password_digest`、`admin`、`failed_attempts`、`locked_until`。`--confirmable` では `confirmed_at`、`unconfirmed_email` も）と `sessions`（サインイン中のブラウザーごとに 1 行、`remember` と `last_active_at` つき） |
| `app/models/user.rb`、`session.rb` | `password=`、`authenticate`、`User.authenticate_by`、トークン、ロックアウト |
| `app/controllers/concerns/authentication.rb` | `ApplicationController` にインクルードされる `Authentication` コンサーン |
| `sessions_controller.rb`、`registrations_controller.rb`（または `setup_controller.rb`）、`passwords_controller.rb`、`accounts_controller.rb`、`confirmations_controller.rb` | サインイン、サインアップ（または最初のユーザーのページ）、パスワードリセット、アカウントページ、確認 |
| `app/mailers/passwords_mailer.rb`、`confirmations_mailer.rb` | メール |
| `app/commands/user_command.rb` | `./<app> user ...`。`bin/<app>.rb` から require される |
| `app/views/...` | 画面（すべてのテキストは `t()` を通る）と `sessions/_nav` パーシャル |
| `test/*.rb`、`test/support/*.rb` | 各部分のテスト（[テスト](#testing)） |

そして次の編集を 1 回ずつ行います：`ApplicationController` への `include Authentication`、ルート、ジョブページの行（[管理者ユーザー](#admin-users-and-the-jobs-page)）、レイアウトへの nav パーシャル、`bin/<app>.rb` へのユーザーコマンド、`config/app.rb` への `base_url` 設定（[メール中のリンク](#links-in-mails)）。同じオプションでもう一度実行しても何も変わりません：すでに行った編集は見つけて飛ばし、書き出すとおりのファイルはそのままにします。違う内容で書き出すことになるファイル（自分で編集したもの、古いジェネレーターや別のオプションが書いたもの）は、`--force` なしでは決して上書きせず、代わりに差分を表示します（[0.4 からのアップグレード](#upgrading-from-04)、[あとから確認を有効にする](#turning-on-confirmation-later)）。

生成される画面のテキストは、フレームワークの英語と日本語の辞書に、それぞれの遅延ルックアップのキー（`sessions.new.title`、`passwords.create.sent`）で入っています。アプリケーションは `config/locales/` でそれらを上書きしたり、言語を足したりできます（[国際化](i18n.md#the-bundled-dictionaries)）。

## サインインとサインアウト

```ruby app/controllers/concerns/authentication.rb（抜粋）
module Authentication
  extend ActiveSupport::Concern

  included do
    before_action :resume_session
    before_action :require_authentication
    helper_method :authenticated?
  end
```

これ以降、すべてのアクションはサインイン済みのユーザーを必要とし、訪問者は `/session/new` に送られます（303。GET はローカルのパスなら記憶され、サインイン後にそこへ戻ります）。コントローラーは Rails と同じようにアクションを訪問者に開放します：

```ruby app/controllers/articles_controller.rb（抜粋）
class ArticlesController < ApplicationController
  allow_unauthenticated_access only: [:index, :show]
```

`allow_unauthenticated_access(only:, except:)` は `Cybertrain::Controller` のメソッドで、`skip_before_action :require_authentication` です。開放されたページでも `resume_session` は実行されるので、テンプレートは `@current_user`（と `@current_session`）を読んだり `authenticated?` を呼んだりできます。`Current` オブジェクトはありません。

<!-- list: points -->
- `SessionsController`（`resource :session`）：`GET /session/new`、`POST /session`、`DELETE /session`。サインインの試行はクライアントのアドレスごとに 3 分間で 10 回までに制限され、キャッシュで数えるので、すべてのプロセスが合わせて数えます。プロキシの背後では [信頼するプロキシ](requests.md#rate-limiting-and-the-client-address) を設定してください。
- 間違ったパスワード、未知のアドレス、ロックされたアカウントは、同じパスワード検証（アカウントがなければダミーのダイジェストに対して）の後に同じメッセージを受け取ります。
- `resume_session` は、その後パスワードが変わったとき、有効期間が過ぎたとき、`auth_idle_timeout` の間リクエストがなかったときに、サインインを終わらせます（Session の行も削除します）（[ログインしたままにする](#remember-me-and-session-limits)）。
- サインアウトは Session の行を削除し、クッキーのセッションを空にします。

## サインアップか、招待制か

既定では、ジェネレーターは `RegistrationsController`（`/sign_up`）を書き出します。これはユーザーを作ってサインインさせます。Rails のジェネレーターにはサインアップページがなく、最初のユーザーはコンソールに任せますが、CyberTrain には Ruby のコンソールがないので、これを書き出します。サインアップはサインインと同じく、クライアントのアドレスごとに 3 分間で 10 回までに制限されます：1 回ごとにパスワードをハッシュし、リンクをメールすることがあり、その "has already been taken" はアドレスが登録済みかどうかを教えてしまうからです。

生成されるコードが保存するアドレスは、サインアップページ、`/setup`、アカウントページ、ユーザーコマンドのどこから来ても、1 つのアドレスでなければなりません：`User.email_address_format?` は、前後に文字のある `@` がちょうど 1 つあり、カンマ、空白、山かっこ、制御文字を含まないことを求めます。メーラーは `ann@example.com,eve@evil.example` を 2 つの宛先として読むので、この検査がなければ 1 つのアカウントが 2 つのメールボックスを持ち、リセットのリンクが両方に届き、`--confirmable` ではどちらからでも確認できてしまいます。メールの規格が認めるアドレスの一部（空白やカンマを含む引用符付きのローカル部）も拒否されます。このメソッドはアプリケーションが変えてかまいません。検査ができる前に保存されたアドレスはもう一度検査されないので、そのアカウントは引き続きリセットでき、サインインできます。

`--invite-only` はサインアップページを書き出しません。社内ツールには正しい既定値で、そうでなければ最初にサーバーへたどり着いた人がアカウントを持ってしまいます。最初のユーザーはユーザーコマンドから作るか、`SetupController`（`GET` と `POST /setup`）から作ります。これはユーザーを作ってサインインさせます：

<!-- list: points -->
- 応答するのは、ユーザーがまだいない間だけ、ワンタイムトークンがあるときだけ、そしてソケットの相手がループバックアドレスで `X-Forwarded-For` ヘッダーのない接続にだけです（同じホストのプロキシはすべてのリクエストをループバックにし、そのヘッダーを付けます）。それ以外はすべて 404 です。
- トークンはプログラムの起動時に作られる 32 文字のランダムな 16 進文字列（`SetupController.setup_token`）で、定数時間で比較されます。`X-Forwarded-For` を付けないプロキシの背後のように、アドレスの検査が効かない場面でもページを閉じたままにします。リクエストログには `[FILTERED]` と出ます。
- ユーザーがいない間、サーバーは起動前に `[WARN] no user exists yet: run ./<app> user EMAIL, or open /setup?token=<token> from this machine` をログに出します。トークンが表示されるのはこの行だけです。
- `<APP>_SETUP_OPEN=1`（`config/app.rb` の `setup_open` 設定）は、別のホストのプロキシの背後での初回起動のために、アドレスの検査を外します。トークンの検査は外しません。ユーザーができたら解除してください。

## ユーザーコマンド

`./<app> user` はどちらのモードでも書き出されます：

```shell ターミナル — 本番ホスト
./blog user ann@example.com                       # 作成、またはパスワードの設定。パスワードは標準入力から読む
printf '%s' "$PASSWORD" | ./blog user ann@example.com
./blog user admin ann@example.com                 # 管理者にする
./blog user unadmin ann@example.com
```

パスワードの引数がなければ標準入力から 1 行読みます（端末ではプロンプトを出します。入力はエコーされます）。これでパスワードが `ps` やシェルの履歴に残りません。パスワードを設定すると、そのユーザーのブラウザーはサインアウトされ、ロックアウトも解除されます。`--confirmable` では、このコマンドが作るユーザーは確認済みになります。`created`、`updated`、`admin`、`unadmin` のいずれかとアドレスを表示して 0 で終了するか、使い方かエラーを表示して 1 で終了します。

## ログインしたままにする、とセッションの期限

サインインのフォームには「Keep me signed in」のチェックボックス（`check_box_tag :remember_me`）があります。サインインの持続期間：

| | チェックあり | チェックなし |
| --- | --- | --- |
| Session の行とクッキーが終わるまで | `auth_remember_for`（30 日） | `session_absolute_max_age`（2 週間） |
| クッキー | 残り時間の `Max-Age` | `Max-Age` も `Expires` もなし：ブラウザーとともに終わる |
| `auth_idle_timeout`（7 日。`0` で無効）の間使われない | 終わる | 終わる |

`last_active_at` の書き込みは多くても 1 分に 1 回です。生成される `start_new_session_for(user, remember:)` は `session.restart_lifetime!`、続いて `session.stamp_lifetime!(seconds, persistent)` をこの順に呼びます：再開はスタンプを消すからです。スタンプする期限は決して 0 になりません：`session_absolute_max_age = 0` では、チェックなしのサインインは `session_max_age`、それもなければ 2 週間続きます。設定は [設定](configuration.md#authentication-settings) にあります。

## ロックアウト

`auth_lockout_attempts`（10）回パスワードを間違えると、アカウントは `auth_lockout_period`（1 時間）ロックされます。ロックされたアカウントは、パスワードが何であっても間違ったパスワードのメッセージを返します。サインインの成功、パスワードリセット、`./<app> user EMAIL` が回数を消します。`auth_lockout_attempts = 0` はロックアウトを無効にし、以前のロックも適用しなくなります。回数は行をそのときの値で読む 1 つの `UPDATE`（`Relation#update_all_sql`）で数えるので、同時のサインインもすべて数えられます。クライアントのアドレスごとのレート制限はそのまま残ります。

## パスワードリセット

サインインページは `/passwords/new` にリンクしています。アドレスのフォームは常に "If that address is registered, a link to reset the password was sent to it." と答え、未知のアドレスでも送信の手前まで同じ処理をします。メール（`PasswordsMailer.reset(user, url).deliver_later`、リクエストの言語で）は `/passwords/<token>/edit` を含みます。トークンは 15 分間、かつパスワードとアドレスが変わらない間だけ有効なので、使えるのは 1 回です。新しいパスワードを設定するとロックアウトが解除され、そのユーザーのすべてのセッションが終わります。`--confirmable` では、待っている新しいアドレスも取り消します（[アドレスの確認](#confirming-addresses)）。

<!-- list: points -->
- メールは `CYBERTRAIN_SMTP_*` の設定でジョブスレッドが送ります（[メールの送信](external-services.md#sending-e-mail)）：ジョブを実行するプロセスとデータベースが必要です。
- リンクのページは `Referrer-Policy: no-referrer` を返し、フレームワークのリクエストログはトークンを `[FILTERED]` と書きます。
- クライアントのアドレスごとに 3 分間で 10 リクエストまで。

### メール中のリンク

リンクは、ジェネレーターが `config/app.rb` に宣言する `base_url` 設定（`<APP>_BASE_URL` から。`BLOG_BASE_URL=https://blog.example.com`）で始まります。アプリケーションを提供するすべての場所で、https で設定してください。設定がなければ、リンクがリクエストの来たアドレスを使うのは `Host` ヘッダーが検査される場合（開発環境、または `CYBERTRAIN_HOSTS` を設定したとき）かテストのときだけです。それ以外ではメールは送られず、ログに `[ERROR] password reset mail not sent: set <APP>_BASE_URL (or CYBERTRAIN_HOSTS)` と出て、ページはいつもどおり答えます。偽の `Host` がリンクに入ることはありません。

## アドレスの確認

`--confirmable` では、サインアップはアドレスにリンクをメールし、誰もサインインさせません。まだ確認されていないアドレスに正しいパスワードを入れると専用のメッセージで拒否され（間違ったパスワードにはいつものメッセージ）、サインインページはリンクをもう一度送るフォームにリンクしています。リンク（`/confirmations/<token>`、3 日間有効、1 回だけ）を開くとアドレスが確認され、その後ユーザーはサインインします。コンサーンの `start_new_session_for` も、どのコントローラーから呼ばれても未確認のユーザーを拒否し、`[WARN] no session started: user <id> has not confirmed its address` をログに出します。この検査は、ジェネレーターが `--confirmable` で書き出すコンサーンにあります：新しいアプリケーションと、コンサーンが新しいファイルになる 0.4 からのアップグレードではそうです。すでにコンサーンのあるアプリケーションでは、検査は差分として届きます（[あとから確認を有効にする](#turning-on-confirmation-later)）。

アカウントページで入力した新しいアドレスは `unconfirmed_email` で待ち、そのアドレス宛のリンクが開かれると古いアドレスに置き換わります。ページから取り消すこともでき（`DELETE /account/pending_email`）、そのリンクは使えなくなります。ユーザーコマンドと `/setup` が作るユーザーは確認済みです。パスワードリセットは一度も確認されていないアカウントを確認しますが（リンクがメールボックスを証明したため）、待っている新しいアドレスは確認しません：そのアドレスを取り消し、そのリンクも使えなくします。それを求めたのは、持ち主がアカウントを取り戻そうとしている相手かもしれないからです。持ち主はあとでもう一度求めます。アカウントページでの新しいパスワードは、待っているアドレスをそのままにします（ユーザーはそこにいて、それが見えています）。

## アカウントページ

`/account/edit`（nav の "Account"）は、現在のパスワードがあるときに限ってアドレスかパスワードを変更し、パスワードがあるときに限ってアカウントを（そのセッションとともに 1 つのトランザクションで）削除します。新しいパスワードはそのユーザーのすべてのセッションを終わらせ、このブラウザーを元の「ログインしたまま」の状態で再びサインインさせます。アカウントの変更と削除は（したがって現在のパスワードの間違いも）、クライアントのアドレスごととユーザーごとに 3 分間で 10 回までに制限され、現在のパスワードの間違いはロックアウトには数えられません。

## 管理者ユーザーとジョブページ

`users.admin`（false）は `./<app> user admin EMAIL` で設定します。コンサーンの `require_admin` は、サインインしているユーザーが管理者でない限り 404 を返します：

```ruby app/controllers/concerns/admin_gate.rb（抜粋、examples/blog）
module AdminGate
  extend ActiveSupport::Concern

  included do
    before_action :require_admin
  end
end
```

ジェネレーターは、`cybertrain new` が書くコメントの代わりに、それで守られたジョブページを描きます：

```ruby config/routes.rb（抜粋）
jobs_page "/admin/jobs", before_action: :require_admin, skip_before_action: :require_authentication
```

<!-- list: points -->
- ジョブページでは `require_admin` だけが実行されるので、訪問者はページがないかのように 404 を受け取ります。`before_action :require_admin` を自分で宣言するコントローラーでは `require_authentication` が先に実行される（Rails の順序）ので、訪問者はサインインに送られ（303）、サインインした管理者でないユーザーが 404 を受け取ります。
- gen は、`before_action:` のない `skip_before_action:` と、`before_action:` そのものを指す `skip_before_action:` を拒否します：どちらもページを誰にでも開いてしまうからです。
- アプリケーションが自分で書いた `jobs_page` の行はそのままにされます。すでに `skip_before_action: :require_authentication` のある行は描かれたものとみなし、それ以外の行には、それを足すようにジェネレーターが伝えます。404 にするには、その行を `jobs_page "...", before_action: :require_admin, skip_before_action: :require_authentication` にしてください（gen は `before_action:` のないスキップを拒否します）。
- `ApplicationController` が `require_admin` を自分で定義していると、そのメソッドがすべてのコントローラーでコンサーンのものの代わりになります。ジェネレーターは `include Authentication` を挿入するときにそう伝え（`warn  app/controllers/application_controller.rb defines require_admin itself: ...`）、ジョブページをスキップなしで描くので（`jobs_page "/admin/jobs", before_action: :require_admin`）、そこでも `require_authentication` が先に実行されます。コンサーンのものを使うには、そのメソッドを削除してください。
- 失敗した、または破棄されたメールのジョブは、その行にメールを残し、ジョブページは行の引数を表示します：管理者は、有効な間はリセットや確認のリンクをそこで読めます。このページは管理者専用で、管理者はもともとどのアカウントにも手を出せます。
- `/setup` とユーザーコマンドが作るのは普通のユーザーです。最初のユーザーは `./<app> user admin EMAIL` で管理者にしてください。

## アプリケーションに残されること

生成されるコードが行う選択と、それぞれの理由です：

<!-- list: points -->
- 存在するロックされていないアカウントへの間違ったパスワードは、その行を 1 回書き込みます（回数）。未知のアドレスとロックされたアカウントは書き込みません。この 1 回の書き込みは時間差になりますが、Devise の lockable と同じく受け入れています：未知のアドレスにも同じ書き込みをすると、レート制限がすでに抑えている信号のために負荷が増えるからです。パスワードリセットのフォームにも同じ種類の差があります：既知のアドレスはメールをキューに入れるので、1 行多く書きます。
- サインアップ、リセット、確認のメールは、送り先のアドレスごとではなく、クライアントのアドレスごとにだけ制限されます：誰かがその頻度であるアドレスにメールを送らせることができます。サインインはクライアントのアドレスごとに 3 分間で 10 回までで、これはロックアウトのしきい値と同じなので、1 つのクライアントが既知のアカウントをロックし続けられます。アドレスごとの制限（`rate_limit ... by:`）や長い時間枠はアプリケーションが足すものです。
- アドレスの変更は古いアドレスに通知されず、待っている新しいアドレスは期限切れになりません（リンクは期限切れになり、パスワードリセットはそのアドレスを取り消します）。一度も確認されていないアカウントが削除されることもありません。
- アカウントページの "has already been taken" は、現在のパスワードを入れたサインイン中のユーザーに、あるアドレスが登録済みであることを教えます（Devise と同じ）。ページのレート制限の範囲内でです。

## フレームワークが提供する部品

生成されるコードはフレームワークの API で組み立てられており、それだけでも使えます：

| API | 役割 |
| --- | --- |
| `Cybertrain::Password` | PBKDF2-HMAC-SHA256 のダイジェスト：`hash`、`verify?`、`verify_serialized`、`dummy_digest`、`needs_rehash?`、`session_key`、`session_key_matches?`（[docs/design.md](../design.md) D25） |
| `Cybertrain::Token` | `issue(purpose, id, expires_in, bound_to)` は `"<id>--<expires>--<hmac>"` を返す。`id_from(token)`、`valid?(token, purpose, bound_to)` |
| `Cybertrain::MailMessage` | メーラーのメソッドが返すもの：`deliver_later`（ジョブ）または `deliver_now` |
| `Session#restart_lifetime!`、`stamp_lifetime!(seconds, persistent)` | サインインごとの有効期間と、ブラウザーセッションのクッキー |
| `Relation#update_all_sql(sql, binds)` | 一致する行への `UPDATE ... SET <sql>` |
| `Controller.allow_unauthenticated_access`、`skip_before_action` | アクションを訪問者に開放する |
| `Controller#safe_redirect_path(text, fallback)` | リクエストから来たローカルのパス、またはフォールバック |
| `ParameterFilter.filter_path(path)` | トークンの形をした部分を `[FILTERED]` にしたパス |
| `check_box_tag(name, value = "1", checked = false)` | hidden フィールドのないチェックボックス |

手書きのサインインは、生成される `User` と同じように `Password` を使います：`Cybertrain::Password.verify_serialized(password, user.nil? ? Cybertrain::Password.dummy_digest : user.password_digest)` はプロセスごとに 1 つずつパスワードを検証し（1 回の検証に約 0.2 秒の CPU を使います）、未知のアドレスでも同じ時間がかかります。サインイン時の `session[:password_key] = Cybertrain::Password.session_key(user.password_digest)` を各リクエストで `session_key_matches?` で確かめれば、パスワードが変わったときにブラウザーをサインアウトさせられます。

`Token.valid?` は渡された `bound_to` に対してトークンを検証するので、先に `Token.id_from` でレコードを見つけ、そのレコード自身の値に対して検証してください。`User.find_by_password_reset_token` はそうしています。

## テスト

ジェネレーターは部分ごとにテストプログラムを書き出します：`test/authentication.rb`、`admin.rb`、`remember_me.rb`、`lockout.rb`、`passwords.rb`、`accounts.rb`、`--confirmable` では `confirmations.rb`。どれも SQLite を使うので、`cybertrain spin test` で実行し、スナップショットはバイナリから取ります。サポートファイルはアプリケーションでも使えます：

<!-- list: points -->
- `test/support/app_test.rb`：`AppTest.boot`、`AppTest.user(email, password)`、`AppTest.sign_in(client, email, password)`（レート制限の回数もリセットします）、`AppTest.form_token(client)`。
- `test/support/authentication_helpers.rb`：`with_smtp_receiver { |receiver| ... }`（アプリケーションのメールはテストプロセス内の受信者に届きます）、`last_mail_link(receiver)`、`backdate_session(row, seconds)`、そして `with_config(env, hosts, base_url, log = nil) { ... }`。最後のものはブロックの間だけ環境、`CYBERTRAIN_HOSTS`、ベース URL を設定し、元に戻します。

このリポジトリの `script/auth-e2e signup invite confirmable upgrade04` は、ジェネレーターでアプリケーションを作り、端から端まで動かします。

## 0.4 からのアップグレード

0.4 が生成したアプリケーションで、ジェネレーターをもう一度実行します。足りないファイル、既存のマイグレーションにない列を足すマイグレーション、そして編集を書き出します。丸ごと書き出すはずのファイルが別の内容で存在する場合は何も変えず、差分を表示します：

```text 出力 — cybertrain generate authentication（抜粋）
exist db/migrate/20260925120000_create_users.rb
create db/migrate/20260925120002_add_authentication_columns.rb
manual  app/models/user.rb (diff below)
create app/controllers/concerns/authentication.rb
manual  app/controllers/sessions_controller.rb (diff below)
create app/controllers/passwords_controller.rb
...
manual  app/controllers/application_controller.rb (diff below)
...
manual  app/controllers/application_controller.rb: apply this diff by hand, or re-run with --force to overwrite the file
--- a/app/controllers/application_controller.rb
+++ b/app/controllers/application_controller.rb
@@ -1,95 +1,5 @@
 class ApplicationController < Cybertrain::Controller
-  # ---- Authentication (cybertrain generate authentication) -------------
-  # Every action needs a signed-in user unless its controller opens it:
...
-  # ---- end of authentication ------------------------------------------
+  include Authentication
```

[test/fixtures/auth_04_app.upgrade.diff](../../test/fixtures/auth_04_app.upgrade.diff) は、0.4 が生成したサインアップ型のアプリケーションに対する出力の全体です。

<!-- list: points -->
- 出力を保存し、アプリケーションのディレクトリで `patch -p1` で適用するか（patch は差分でない行を読み飛ばします）、ファイルを変更した箇所では差分を手で適用してください。適用するまでアプリケーションはビルドできないことがあります：新しいファイルが、差分で足されるものを呼ぶからです。
- `--force` は代わりに新しいファイルを古いファイルの上に書き出します。編集していないファイル向けです。`ApplicationController` の 0.4 のブロックが置き換えられるのは、0.4 が書いたとおりのままのときだけです。
- 新しいマイグレーションは足りない列だけを足します。`cybertrain db migrate` を実行してください。`--confirmable` では、すでにいるユーザーを（作成時から）確認済みとして扱います。そうしないと誰もサインインできなくなるからです。
- `--confirmable` では、sessions と registrations のコントローラーの差分に `IMPORTANT:` の行が付きます：適用するまで、未確認のアカウントはサインインできない理由を知らされず、サインアップしてもリンクがメールされません。0.4 のアプリケーションではコンサーンは新しいファイルで、確認の検査とともに書き出されるので、それらの差分が適用されなくても、未確認のアカウントにセッションを始めません（そして `[WARN] no session started: user <id> has not confirmed its address` をログに出します）。
- アップグレードの際、すべてのセッションは一度終わります（クッキーが暗号化されたため）。[0.4 のアプリケーションのアップグレード](requests.md#upgrading-an-application-from-04) の残りも当てはまります。

### あとから確認を有効にする

確認なしで生成したアプリケーションで、`cybertrain generate authentication --confirmable` を実行します（アプリケーションが `--invite-only` なら、それも付けます）。確認のファイルと、すでにいるユーザーを確認済みとして扱う列追加のマイグレーションを書き出し、以前に書き出した各ファイルの差分を表示します。この場合コンサーンはすでにあるので、確認の検査はそれらの差分の 1 つとして届き、出力はそれに `IMPORTANT:` を付けます：コンサーンの差分を適用するまで、ほかの差分がどうであれ、未確認のアカウントはサインインできてしまいます。デプロイする前に、それと sessions コントローラーの差分を適用してください。`--invite-only` では setup コントローラーの差分にも印が付きます：適用するまで、`/setup` が作る最初のユーザーは確認されておらず、サインインできません（パスワードリセットで確認されます）。
