# Testing an app

An application's tests are Rails-shaped classes under `test/`, and
`cybertrain test` runs them all as one compiled program. Minitest and RSpec
find test methods by reflection, which an ahead-of-time compiler cannot do,
so `spin run gen` rewrites each test class into plain methods and writes
one dispatch table over every test.

## Writing a test

`cybertrain new` writes `test/test_helper.rb`; every test file starts by
requiring it, as in Rails:

```ruby test/test_helper.rb
ENV["CYBERTRAIN_ENV"] ||= "test"
require_relative "../config/app"
require "cybertrain/test_help"

class ActiveSupport::TestCase
  fixtures :all

  # Helper methods used by all tests go here.
end
```

```ruby test/models/article_test.rb
require "test_helper"

class ArticleTest < ActiveSupport::TestCase
  test "title must be present" do
    article = Article.new(body: "a body long enough to pass length")
    assert_not article.save
    assert_includes article.errors.full_messages, "Title can't be blank"
  end
end
```

```ruby test/controllers/articles_controller_test.rb
require "test_helper"

class ArticlesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @article = articles(:one)
  end

  test "shows an article" do
    get article_path(@article)
    assert_response :success
    assert_select "h1", text: @article.title
  end

  test "creates an article" do
    assert_difference -> { Article.count }, 1 do
      post articles_path, params: { article: { title: "New", body: "A body long enough" } }
    end
    assert_redirected_to article_path(Article.last)
  end
end
```

There are three base classes, Rails' own: `ActiveSupport::TestCase` (models,
jobs, mailers, anything without a request), `ActionDispatch::IntegrationTest`
(requests, [Integration tests](#integration-tests)) and
`ViewComponent::TestCase` (`render_inline`,
[Testing streams and components](#testing-streams-and-components)). An
application may put a base class of its own in `test/test_helper.rb` or
`test/support/` and inherit from it. Helper methods, constants and
`private` go in the class body as in Rails; each test runs on a new
instance, so instance variables set in `setup` belong to that test.
`fixtures :all` and `require "test_helper"` are accepted and do nothing of
their own: every fixture is loaded for every test.

Every test runs in this order:

1. every table is emptied, the framework's (jobs, cache, Turbo messages,
   schedules, feeds, leases) included, and ids start again at 1;
2. the fixtures are inserted ([Fixtures](#fixtures));
3. `Mailer.deliveries`, the rate-limit counters and `I18n.locale` are reset,
   and the time zone is the one `config/app.rb` configured;
4. `setup` (a superclass's first; several `setup do` blocks in order);
5. the test body, if nothing before it failed;
6. `teardown`, always: after a failed assertion, an exception or a failed
   setup (several `teardown do` blocks in reverse order, then the
   superclass's);
7. the clock is real again, and every receiver the test started is stopped.

Rails rolls each test back in a transaction instead. That does not fit
here: SQLite has no savepoints in this framework, so a test's own
`transaction` would end the wrapping one, and job threads use other
connections that would not see the test's rows.

## Running the tests

```sh
cybertrain test                                         # every test
cybertrain test test/controllers                        # the files under a directory
cybertrain test test/models/article_test.rb             # one file
cybertrain test -n "creates an article"                 # one test by its name
cybertrain test -n test_creates_an_article              # or by its method name
cybertrain test -n /article/                            # the tests whose name contains "article"
```

`cybertrain test` runs `SPIN_DEBUG=1 spin run gen` (gen built in spin's
debug mode, as every command of the CLI builds it), which writes `gen/tests.rb` (the
program) and a rewritten copy of each test class under `gen/test/`, both
committed with the rest of `gen/`; it then compiles `gen/tests.rb` into
`build/test/tests` (a release build) when any input is newer than that binary, and runs it.
Every `test/**/*_test.rb` and every other `test/*.rb` but
`test/test_helper.rb` is in it; `test/support/` (required by the helper)
and `test/fixtures/` hold no tests. The program deletes
`storage/test.sqlite3`, migrates a new one and boots the application on it
before the first test (no job, scheduler or feed threads: a test runs jobs
itself). `CYBERTRAIN_TEST_DATABASE` names another file instead. Since the program
deletes the file it tests on, it refuses, with exit status 2 and nothing
deleted, a file that is the development or production database: one named
`development.sqlite3` or `production.sqlite3`, or the file those
environments resolve to (`config/app.rb`'s `c.database_path` included, also
through a symlink). It prints `cybertrain test refuses to delete <path>: it
is the <env> database`.

The program sets up the test environment as Rails' does, unless
`config/app.rb` sets the same thing itself: forgery protection off, the
request log silent, mail kept in `Mailer.deliveries` (`:test`) and
`force_ssl` off (the variables `CYBERTRAIN_MAIL_DELIVERY_METHOD` and
`CYBERTRAIN_FORCE_SSL` are not read for the tests), and uploads written to
`tmp/test_uploads/`, emptied at every run. `www.example.com`, the host of
the `*_url` helpers, is always an allowed host.

```text output — cybertrain test
test/controllers/articles_controller_test.rb
  ok   ArticlesControllerTest: shows an article
  FAIL ArticlesControllerTest: creates an article (test/controllers/articles_controller_test.rb:14)
         Expected change of 1, got 0 (from 2 to 2)
test/models/article_test.rb
  ok   ArticleTest: title must be present

3 tests, 6 assertions, 1 failure
```

A heading per file, a line per test, then the totals, with no timings. The
line named is the test's `test "..."` line: a compiled program has no
backtrace, so the line of the failing assertion is not known. The exit status is 1 when a test failed, 0 otherwise, and 2 for arguments it does
not take. What the code under test prints itself (a command's output line)
appears between the test lines. A test, setup, teardown or hook that raises
`NotImplementedError`, another `ScriptError` or `SystemStackError` is an
`ERR` like any other exception, and the run goes on; only `Interrupt`,
`SystemExit` and `NoMemoryError` end it. Under Spinel a real stack overflow
still ends the process with a segmentation fault: only a
`SystemStackError` raised by the code itself reaches the runner.

The arguments: `-n NAME` keeps the test with that name or method name, and
`-n /TEXT/` the tests whose name or method name contains TEXT as plain
text (`.`, `?` and `()` are themselves). TEXT with one of
`^ $ \ * + [ ] { } |` is refused with exit status 2, since it is not a
regexp: `-n /^test_create/: the text between the slashes is a plain
substring of the test name, not a regexp (^ would be looked for as itself);
write the text to look for (-n /test_create/)`. A file or directory keeps
its tests; `FILE:LINE` is refused (`line filters are not supported; give
the file, and -n for the name`); `--` ends the options. A filter that keeps
no test prints `no test matched the filter` before the totals and exits 0.
Adding or deleting a file under `test/` compiles the program again.

**What a change costs.** A file argument and `-n` choose which tests run,
not what is compiled: the program always holds every test, so changing the
filter reuses the binary, and editing any test (or anything else the
program is built from) compiles the whole program again, and rebuilds
`bin/gen` first. Measured on 2026-11-12 and 2026-11-13 on a shared 4-vCPU
cloud machine (a machine of your own will differ): examples/blog's 149
tests in 21 files compiled in about 527 s the first time (the whole first
run took 656 s, the binary is 10.2 MB), and a later `cybertrain test
test/controllers` with nothing changed reused the binary and started in
about 1 s (the blog's own run, 2026-11-13); the blog's application with
three test files of eight tests compiled in 162 to 233 s at a peak of
about 2.2 GB, into an 8.1 MB binary (2026-11-12). Write several tests before running them, and narrow the run, not
the build, while you work on one.

`gen/tests.rb` is refused, and `cybertrain test` exits 1 with the reason
and no compile, when two test or support files define the same top-level
method or constant (they would become one in one program: move a shared
helper to `test/support/`, or into the class), and for the other cases of
[What gen refuses in a test class](#what-gen-refuses-in-a-test-class).

## Fixtures

```yaml test/fixtures/users.yml
alice:
  email_address: alice@example.com
  admin: true
```

```yaml test/fixtures/articles.yml
one:
  title: First post
  body: A body long enough to pass the length check.
  author: alice
  created_at: 2026-11-01 09:00:00

two:
  id: 42
  title: Second post
  body: Another body long enough.
  author: alice
```

`test/fixtures/<table>.yml` is Rails' shape: labels, then columns. gen reads
the files when it runs, with the YAML subset of [the dictionaries](i18n.md#dictionaries),
and refuses with `file:line` a file that is not a table of `db/schema.rb`, a
key that is neither a column nor a `belongs_to` of the model, ERB (`<%`
anywhere: there is no `eval`; set a time relative to now in `setup` or with
`travel_to`), a value that is not of the column's type (an impossible date,
an integer outside 64 bits, `yes` for a boolean), two labels with one id,
and a `belongs_to` label that names no row of the parent's file. `DEFAULTS`
is not a row, as in Rails.

- A row without `id:` gets Rails' id for its label
  (`ActiveRecord::FixtureSet.identify`), so a label has the same id as in a
  Rails application. `author: alice` sets `author_id` to alice's id.
- Datetimes are UTC. `created_at` and `updated_at` that a row leaves out
  are the clock's time when the row is inserted, before each test.
- `articles(:one)` answers `Article.find` of that row; an unknown label
  raises `Cybertrain::Test::FixtureNotFound`. One label per call.
- A fixture is checked when gen runs, but its error stops only the test
  run: `spin run gen` (and so `cybertrain db migrate`, which a scaffold's
  fixture comes before) goes on, and `cybertrain test` prints
  `test/fixtures/<table>.yml:<line>: ...` and exits 1.
- As in Rails, a fixture that points at a parent keeps that parent from
  being deleted: once `comments.yml` has `article: one`, the scaffold's
  "should destroy article" fails on the foreign key. Declare
  `has_many :comments, dependent: :destroy`, point the child fixtures at
  another row (`article: two`), or destroy a row nothing references.
- Not offered: `fixtures :articles` (every file is loaded),
  `articles(:one, :two)`, polymorphic labels (`commentable: one (Article)`;
  write the `_id` and `_type` columns), `has_and_belongs_to_many` labels,
  and anchors and aliases.

## Integration tests

`ActionDispatch::IntegrationTest` requests the booted application in
process, with no socket and a new cookie jar for each test:

- `get`, `post`, `patch`, `put`, `delete`, `head` (path, `params: {}`,
  `headers: {}`), as Rails spells them. Each answers the
  `Cybertrain::Response` (Rails answers the status), which is also
  `response` (`response.body`, `response.status`, `response.header(name)`).
- `params:` takes nested Hashes, sent as a form sends them
  (`article[title]=New`); a value may be a String, a Symbol, a number,
  `true` / `false`, nil, a Date or a Time (sent as the text the column reads
  back), so a scaffold test can send a record's values as they are. An
  Array is refused.
- `fixture_file_upload("cover.png", "image/png")` in `params:` of `post`,
  `patch` or `put` sends the request as multipart; the file is read from
  `test/fixtures/files/`.
- `headers:` takes the header's name, or Rails' `HTTP_ACCEPT` form.
- The path helpers of `config/routes.rb` work as in a controller. A `*_url`
  helper writes `http://www.example.com/...`; a URL on that host is
  requested by its path, and `assert_redirected_to` compares either form.
  A URL on another host is refused.
- `cookies` is the test's cookie jar, a `Cybertrain::Test::ClientCookies`:
  `cookies[:user]` or `cookies["user"]` (the raw, still percent-encoded
  value), `[]=`, `key?`, `delete`, `keys`, `size`, `empty?` and `to_h`. A
  cookie whose `Max-Age` or `Expires` has passed on the clock, so also
  after `travel_to` past it, is gone (`Max-Age` wins over `Expires`); one a
  test writes with `[]=` never expires.
- `follow_redirect!` requests the last response's `Location` (without its
  `#fragment`); after a response that is not a redirect it fails the test:
  `follow_redirect!: the last response was 200, not a redirect (3xx with a
  Location)`.
- `assert_response(:success)` (or any status
  symbol, or a number; `:error` means exactly 500, where Rails takes any
  5xx), `assert_redirected_to(path)`, `assert_select`, `assert_turbo_stream`.
- Not there: `session`, `flash`, `assigns`, `request`, `host!` and `as:`.
  Assert on the page (`assert_select`, `response.body`) instead.

**Forgery protection** is off in tests unless `config/app.rb` sets `csrf`,
as in Rails' test environment, so a `post` needs no token. A test of the
check turns it on for some requests:

```ruby
test "a form without the token is refused" do
  with_forgery_protection do
    post articles_path, params: { article: { title: "x" } }
    assert_response :forbidden
  end
end
```

Inside the block a form needs the `authenticity_token` of a page the test
requested; everything is put back when the block ends, also when an
assertion in it fails, and what the test itself set (the upload root, the
zone, the locale, the log level) is kept.

**Signing in.** `cybertrain generate authentication` writes
`test/support/session_test_helper.rb`, included into every integration
test: `sign_in_as users(:one)` (fixture users' password is `"password"`;
`remember: true` checks "Keep me signed in"), `sign_out`,
`authenticity_token_in(response.body)` (the token of the first form in a
page, for requests inside `with_forgery_protection`), and
`open_session`, a second browser with cookies of its own (`phone =
open_session`, then `phone.sign_in_as users(:two)` and `phone.get ...`).
Every request comes from `127.0.0.1`; a test that needs another client
address makes its own `client = Cybertrain::Test::Client.new(Cybertrain::Test.app)`
and sets `client.peer_address = "203.0.113.7"` (the client's own methods
are `client.get(path, headers)` and `client.post(path, fields, headers)`).

## Assertions

`assert`, `assert_not` (`refute`), `assert_equal`, `assert_not_equal`,
`assert_nil`, `assert_not_nil`, `assert_includes`, `assert_not_includes`,
`assert_empty`, `assert_not_empty`, `assert_match` / `assert_no_match` (a
Regexp, or a String as a substring), `assert_in_delta(expected, actual,
delta = 0.001)`, `assert_nothing_raised { }` and `flunk`, as Minitest has
them. `assert_equal` fails with Minitest's text (`Expected: 1` and
`  Actual: 0` on two lines), and so do the newer assertions;
`assert_includes`, `assert_nil` and `flunk` keep shorter texts of their
own. `assert` and `refute` take a message as their second argument. The
block forms take a lambda, passed positionally:

```ruby
assert_difference -> { Article.count }, 1 do
  post articles_path, params: { article: { title: "New", body: "A body long enough" } }
end
assert_no_difference(-> { Article.count }) { post articles_path, params: { article: { title: "" } } }
assert_changes(-> { article.reload.title }, from: "Old", to: "New") { article.update(title: "New") }

message = assert_raises(Cybertrain::RecordNotFound) { Article.find(999) }
assert_includes message, "999"
```

- `assert_raises` takes a class (a subclass matches, as in Minitest), part
  of a class name as a String (`assert_raises("RecordNotFound")`), or
  nothing (any StandardError), and answers the exception's **message**, not
  the exception: where Rails writes `error = assert_raises(X) { }` and
  `error.message`, use the String it answers. A method answers one type
  under Spinel, and the message is what tests read.
- The block assertions answer nil, not the block's value.
- Not offered: `assert_predicate` (it needs a computed `send`: write
  `assert article.valid?`), String expressions in `assert_difference` (they
  need `eval`), an Array or Hash of expressions, and a message argument
  on the other assertions.

## Time travel

```ruby
test "a remembered session survives day 15" do
  sign_in_as users(:one), remember: true
  travel_to 15.days.from_now do
    get root_path
    assert_response :success
  end
end

test "the cache entry expires" do
  freeze_time
  Cybertrain::Cache.write("k", "v", expires_in: 5.minutes)
  travel 6.minutes
  assert_nil Cybertrain::Cache.read("k")
end
```

`travel_to(time)`, `travel(seconds)`, `freeze_time` and `travel_back` are
Rails' helpers: each freezes the clock and drops the sub-second part;
with a block the previous time comes back when the block ends (also when
it raises), and without one the travel lasts until `travel_back` or the end
of the test. Everything the framework times follows: `Time.current`,
`Time.now` in a test program, records' timestamps, the cache's expiry, rate
limits, the session's lifetime, jobs' `run_at`, tokens' expiry, the
scheduler. Waits and timeouts (stream reads, receivers) keep real time,
so a frozen clock never hangs one. `Time.now` answers local time, in the process's `TZ`, as the builtin
does, while `Time.current` is UTC. In production `Time.now` is the
system's clock: code that should follow a travel reads `Time.current`, as
Rails advises. `travel_to` takes a Time, not a Date, and there is no
`Time.zone.local`: write the instant with `Time.utc(...)`. The scheduler
keeps what it remembers (the last recovery, the next run times) across a
travel; a test that travels while live scheduler or worker threads are
running is not supported.

Durations are Integer seconds: `5.minutes` is `300`, and `2.weeks.ago` and
`3.days.from_now` answer a Time on the clock. There is no `1.month` (a month
has no length in seconds): it is a `NoMethodError` when it runs. Use the
calendar methods on Time: `Time.current.months_ago(1)`,
`advance(months: 1)`, `beginning_of_day`, `end_of_month`, `yesterday`
([Times and the time zone](models.md#times-and-the-time-zone)). `advance`
adds hours, minutes and seconds as elapsed time, after the calendar part,
and takes Integers; the real clock keeps microseconds.

## Testing streams and components

```ruby test/components/comment_component_test.rb
require "test_helper"

class CommentComponentTest < ViewComponent::TestCase
  test "renders the comment" do
    render_inline(CommentComponent.new(comment: comments(:one)))
    assert_select "div.comment strong.comment-author", text: "Alice"
  end

  test "renders the form partial" do
    html = render_inline(partial: "articles/form", locals: { article: Article.new })
    assert_select "form[action=\"/articles\"] input[name=\"article[title]\"]"
    assert_includes html, "Save"
  end
end
```

`render_inline(component, content: "")` and `render_inline(partial:,
locals: {})` render outside any request, answer the HTML (Rails answers a
Nokogiri fragment, and takes the content as a block) and keep it for
`assert_select`. A helper that needs a request raises
`Cybertrain::Views::OutsideRequest`.

`assert_select(selector, equality = nil, count:, minimum:, maximum:,
text:)` checks the last `render_inline` or response of this test (with
neither it fails: "No response yet") and answers the matching elements:

- Selectors: a tag, `.class`, `#id`, `[attr]`, `[attr="v"]`, compounds
  (`a.btn[href="/x"]`), the descendant and child (`>`) combinators, and a
  list (`h1, h2`). Pseudo-classes, `+` and `~`, other attribute operators, a backslash
  (`assert_select: CSS escapes (\) are not supported`) and the nested block
  form fail with `assert_select: <feature> is not supported`.
- `text:` is a String compared with each element's text, or a Regexp
  matched against it. The text has its runs of whitespace made one space
  and its ends stripped (Rails strips the ends only). The second argument may be Rails' positional text (a String or a Regexp),
  count (an Integer, or a Range such as `2..3`) or `true` / `false`; a count
  given there and in `count:`, `minimum:` or `maximum:` too is refused, and
  so are a negative or crossed Range.
- The HTML is read as written, not repaired as a browser (and Nokogiri,
  behind Rails' `assert_select`) would: `table > tr` matches a table
  written without `<tbody>`, `p > div` matches `<p><div>`, and an omitted
  end tag (`<li>a<li>b`, `<p>a<p>b`) or a self-closing `<div/>` fails the
  assertion with its position. The framework's own templates all read.

A broadcast is a row of `cybertrain_messages`, so the stream assertions
read the table, with no poller or socket:

```ruby
test "a new comment is broadcast and answered with a Turbo Stream" do
  article = articles(:one)
  payloads = assert_broadcasts(article, 1) do
    post article_comments_path(article), params: { comment: { commenter: "Dave", body: "Hi" } },
                                         headers: { "Accept" => "text/vnd.turbo-stream.html" }
  end
  assert_includes payloads[0], 'target="comments"'
  assert_turbo_stream action: "append", target: "comments"
end
```

`assert_broadcasts(stream, count) { }` counts what was broadcast to a
stream (a name, or a record) while the block ran, or without a block since
the test began, and answers the payloads; `assert_no_broadcasts(stream)`
wants none. `assert_turbo_stream(action:, target:, count: 1)` reads the
last response, which must be `text/vnd.turbo-stream.html`, or the last
`render_inline`. To read a live stream as a browser does,
`client.get_stream(path, events: n)` of a `Cybertrain::Test::Client` runs a
streaming response in memory ([Realtime](realtime.md)).

## Testing mail

In `cybertrain test` `Cybertrain.config.mail_delivery_method` is `:test` unless
`config/app.rb` sets it: `deliver_now`, `Mailer.deliver` and the `deliver_later` job check
the message and keep it in `Cybertrain::Mailer.deliveries` instead of
connecting, and the list is emptied before every test. The test program
gives mail the sender `from@example.com` when the application sets none.

```ruby
test "a reset mails a link" do
  assert_emails 1 do
    post passwords_path, params: { email_address: users(:one).email_address }
  end
  mail = Cybertrain::Mailer.deliveries.last
  assert_equal "Reset your password", mail.mail_subject
  assert_includes mail.mail_body, "/passwords/"
end
```

`assert_emails(count) { }` counts the mail the block delivered; mail queued
in it with `deliver_later` is delivered first, and a mail job that fails
fails the assertion with its error. `assert_no_emails { }` wants none. A
message's readers are `mail_to`, `mail_from`, `mail_subject`, `mail_body`
and `mail_html`. A test of the SMTP path itself sets
`Cybertrain.config.mail_delivery_method = :smtp` and puts `:test` back in
`teardown` (the setting is not reset between tests), as in
[Testing outbound calls](#testing-outbound-calls). Outside the test
environment `:test` boots with a warning, and no mail is sent.

## Testing jobs

```ruby test/jobs/notify_comment_job_test.rb
require "test_helper"

class NotifyCommentJobTest < ActiveSupport::TestCase
  test "a comment queues its notification, which runs" do
    comment = comments(:one)
    NotifyCommentJob.perform_later("comment_id" => comment.id, "article_id" => comment.article_id)
    assert_enqueued_jobs 1, "NotifyCommentJob"
    assert_enqueued_with "NotifyCommentJob", { "comment_id" => comment.id }
    assert_equal 1, perform_enqueued_jobs
    assert_no_enqueued_jobs
  end

  test "the jobs a block queues run at once" do
    performed = perform_enqueued_jobs { ReminderJob.perform_in(3600, { "id" => 1 }) }
    assert_equal 1, performed
  end
end
```

- `assert_enqueued_jobs(count, kind = "")` counts the queued jobs (of one
  kind when given); `assert_no_enqueued_jobs(kind = "")` wants none.
- `assert_enqueued_with(kind, args)` wants a queued job of that kind whose
  args hold every given key with an equal value (`"comment_id" => 7`
  matches a JSON `7`; `comment_id: 7` works too).
- `perform_enqueued_jobs { }`, Rails' inline form, runs the block, then
  every job queued in it and the jobs those queue, whatever their `run_at`,
  and answers how many ran. A job that raises fails the test with its class
  and error, and is not retried; a job the application discards
  (`discard_on`) counts as run.
- `perform_enqueued_jobs(now = Time.current)` without a block runs every
  job due at `now`, one by one, until none is due. A retry scheduled for
  later stays queued: `travel` past it, or pass a later `now`. Either form
  fails the test after 10,000 jobs (a job that queues itself again).
- `clear_enqueued_jobs` deletes the queued jobs; `WelcomeJob.perform_now(args)`
  runs one directly, an exception reaching the test.
- Scheduled tasks run one tick at a time with `Cybertrain::Scheduler.run_due(Time.current.to_i)`
  (epoch seconds).

## Testing outbound calls

When the code under test sends a webhook ([Outbound HTTP](external-services.md#outbound-http)) or
an e-mail over SMTP ([Sending e-mail](external-services.md#sending-e-mail)), the test receives
it in process: `Cybertrain::Test::HttpReceiver` and `Cybertrain::Test::SmtpReceiver`
listen on `127.0.0.1`, record what arrives and answer with a canned reply.
A receiver started in a test is stopped after it, also when it fails.

```ruby test/integration/signup_hook_test.rb
require "test_helper"
require "cybertrain/test/http_receiver"
require "cybertrain/test/smtp_receiver"

class SignupHookTest < ActiveSupport::TestCase
  setup do
    Cybertrain.config.http_allow_private = true   # HttpClient refuses loopback otherwise
  end

  teardown do
    Cybertrain.config.http_allow_private = false
    Cybertrain.config.mail_delivery_method = :test
  end

  test "a sign-up posts a webhook" do
    hook = Cybertrain::Test::HttpReceiver.new(status: 202, body: "queued")
    hook.start                                   # binds a free port, returns it
    SignupHook.post(hook.url("/hooks/signup"), "ann@example.com")   # the app's code
    req = hook.received_request                  # waits at most 5 s; nil if nothing came
    assert_equal "POST", req.http_method
    assert_equal "/hooks/signup", req.http_target
    assert_equal "application/json", req.http_header("Content-Type")
    assert_includes req.http_body, "ann@example.com"
  end

  test "a refused recipient is reported" do
    Cybertrain.config.mail_delivery_method = :smtp
    smtp = Cybertrain::Test::SmtpReceiver.new(reject: { rcpt: "550 5.1.1 no such user" })
    port = smtp.start
    mailer = Cybertrain::Mailer.new(host: "127.0.0.1", port: port, tls: "none", from: "app@example.com")
    assert_raises("RejectedError") { mailer.deliver(to: "nobody@example.org", subject: "Hi", body: "Hello\n") }
    mail = smtp.received_message
    assert_equal ["EHLO localhost", "MAIL FROM:<app@example.com>", "RCPT TO:<nobody@example.org>"],
                 mail.transcript.first(3)
    assert_not mail.delivered?
  end
end
```

`HttpReceiver.new` takes the canned `status:`, `headers:`, `body:` and
`chunked:` (`respond_with` changes them between requests); the request comes
back as a `ReceivedRequest` (`http_method`, `http_target`, `http_path`,
`http_headers` with lowercased names, `http_header(name)`, `http_body` with a
chunked body decoded). `SmtpReceiver` plays 220, EHLO (with 8BITMIME unless
`eight_bit_mime: false`, AUTH PLAIN with `auth: true`), MAIL, RCPT, DATA and
QUIT; `reject:` fails any of `:greeting`, `:ehlo`, `:mail`, `:rcpt`, `:data`
or `:message` with the reply given. A `ReceivedMessage` has the
`envelope_from`, `envelope_recipients`, the `message_data` (dot-stuffing
undone), `message_header(name)`, `message_body` and the `transcript` of
commands; for an HTML message, `message_parts` decodes it into
`"subject"`, `"text"` and `"html"`. Both accept one connection unless `max:` says more
(`received_requests` / `received_messages` return them all). Every wait is
bounded: a receiver gives up after `accept_window:` (10 s) without a
connection and a silent client after `read_timeout:` (5 s), and `stop` (safe
to call twice) ends its thread and closes its port, so a receiver never
takes a later test's connection. A receiver started outside a test (at the
top of a file) is not stopped for you.

A feed is tested the same way with `Cybertrain::Test::WebSocketReceiver`, a
scripted WebSocket server on `127.0.0.1`: each connection plays a list of
`Cybertrain::Test::WsStep`s (`"accept"`, `"send_text"`, `"expect"`,
`"silent"`, `"close"`, `"drop"`, `"echo_until_close"`, ...), and the frames
the client sent come back unmasked from `ws_received`.

```ruby test/integration/trades_feed_test.rb
require "test_helper"
require "cybertrain/websocket"
require "cybertrain/test/websocket_receiver"

TICKS = Array.new(0) { "" }   # a constant: the blocks cannot see locals

# The blocks are written in a method, where their parameters are used.
def subscribe_trades(url)
  Cybertrain::WebSocket.subscribe("trades", url, allow_private: true)
    .on_open { |conn| conn.send_text("subscribe") }
    .on_message { |conn, text| TICKS << text }
end

class TradesFeedTest < ActiveSupport::TestCase
  test "a trade message is stored" do
    rx = Cybertrain::Test::WebSocketReceiver.new
    rx.ws_script([Cybertrain::Test::WsStep.new("accept"), Cybertrain::Test::WsStep.new("expect"),
                  Cybertrain::Test::WsStep.new("send_text", "tick"), Cybertrain::Test::WsStep.new("echo_until_close")])
    rx.start
    subscribe_trades(rx.url("/trades"))
    Cybertrain::WebSocket.start!               # the test program never starts feeds
    # ... poll TICKS for at most a few seconds ...
    Cybertrain::WebSocket.stop!
    assert_equal ["tick"], TICKS
    assert_equal "subscribe", rx.ws_received[0].rec_data
  end
end
```

`Cybertrain::WebSocket.random_source = -> { 0.5 }` makes the retry delays exact.
`test/websocket_integration.rb` in this repository shows a complete test.

## What gen refuses in a test class

gen rewrites a test class into methods: `test "shows it" do` becomes `def
test_shows_it` (an ASCII character outside `[A-Za-z0-9_]` turned into `_`, any
other into `_u<hex>`, so `"ログ"` is `test__u30ed_u30b0`; `-n` takes the
method name or the written one), and the `setup do` and `teardown do` blocks
become `setup` and `teardown` methods calling `super`. Whatever the rewrite cannot carry over
exactly refuses that file, never a silently wrong copy or a lost test:

- a test name that is not a plain string literal (interpolation), or one
  with an escape gen does not read (`\u`, `\x`, `\c`, `\C`, `\M` or an
  octal one: write the character itself; `\n`, `\t` and `\"` are read);
- two tests whose method names coincide in one class, a `def test_x`
  included;
- both `setup do` and `def setup` in one class (likewise `teardown`), and
  a `def setup` or `def teardown` without `super` in a class whose parent is
  an application base class (its `setup do` blocks would not run);
- a `def test_x` that takes parameters, or one after `private` or
  `protected` (Minitest runs only public test methods);
- `setup { }` and `setup :name` (write `setup do ... end`), and block
  parameters on `test`, `setup` or `teardown`;
- `next`, `break` or `redo` in a test, setup or teardown body, also inside
  an `if`, `unless`, `case` or `begin` there (use `return`), and
  `return <value>` (each answers nil);
- a test class nested in another class or module, a test class opened
  twice, and `setup do` in a reopened `ActiveSupport::TestCase` (write an
  application base class with `setup do` and inherit from it);
- a `test`, `setup` or `teardown` line gen cannot place in the class body
  (inside a condition, a loop, a string or a heredoc), a one-line form that
  does not end with `end`, an `end` with code after it, and indentation
  that mixes tabs and spaces;
- a `require_relative` whose argument is not a string literal.

A refused file does not stop `spin run gen`, so the development server,
`cybertrain db migrate` and `cybertrain build` keep working: gen writes a
`gen/tests.rb` that only prints the reason, and `cybertrain test` then
prints `<path>:<line>: <reason>` and exits 1, with
no compile. Fix the line it names. `test "name" do` may also be written
`test"name"` or with a tab. A `test "x" do` written after `private` is not
refused, but it becomes a private method of the copy and fails when it
runs, where Rails runs it: keep tests above `private`.

`cybertrain test` also refuses, the same way, a top-level
`test`, `setup` or `teardown` in `test/test_helper.rb` or `test/support/`
(it would never run), a top-level `def render_inline` (it would replace
the framework's), `assert_select ... do` and `render_inline ... do`, and
the duplicate top-level helpers of [Running the tests](#running-the-tests).
A class-form file runs only through `cybertrain test`: under `spin test`
its class body raises "class-form tests run with `cybertrain test FILE`".

## The top-level form

The earlier shape, `test` blocks at the top of a file, keeps working, in
`cybertrain test` (as here, with the bundle's application and fixtures) and
under `cybertrain spin test`:

```ruby test/legacy.rb
require "test_helper"

setup do
  Cybertrain.config.http_allow_private = true
end

teardown do
  Cybertrain.config.http_allow_private = false
end

test "shows an article" do
  client = Cybertrain::Test::Client.new(Cybertrain::Test.app)
  res = client.get("/articles/#{articles(:one).id}")
  assert_response res, :success
  assert_includes res.body, articles(:one).title
end

Cybertrain::Test.run!
```

Top-level `setup do` and `teardown do` run before and after every test of
their file. `cybertrain spin test` compiles each `test/*.rb` into its own
program and compares its output with `test/<name>.rb.expected`; there it
has no clear and no fixtures (they need gen's table list), and
`Cybertrain::Test.run!` runs the file's tests. In `cybertrain test` the
file's tests run with the others, after the clear and the fixtures, and
`run!` does nothing. Under `spin test` nothing boots the application for
the file, so such a file boots it itself, as 0.4's support files
(`AppTest.boot`, `BlogTest.boot`) did, and uses no fixtures.
`Cybertrain::Test::Client` drives the application
with a cookie jar, CSRF included (`client.get`, `client.post(path, fields,
headers)`, `client.follow_redirect!`, `client.response`, and the two-argument
`assert_response res, :ok` and `assert_redirected_to res, path`). A
snapshot whose test touches SQLite comes from the compiled binary:
`script/regen-snapshot test/<name>.rb` in the framework's checkout, or
`rm -f build/test/<name>; cybertrain spin test test/<name>.rb; ./build/test/<name> > test/<name>.rb.expected 2>&1`.

## Upgrading from 0.4

- Add `test/test_helper.rb` as above, and move what a support file did at
  load time (`AppTest.boot`, `BlogTest.boot`, migrating a database) out of
  it: the test program boots on a fresh database before the first test,
  and a second boot only costs time.
- Change the CI step from `spin test` to `cybertrain test`.
- Two files that define the same top-level helper or constant (a
  `new_client` in each, as the 0.4 generators wrote them) are refused
  together: move the helper to `test/support/` or rename one.
- Every table is emptied before each test, so a later test can no longer
  rely on rows an earlier one made: move such data to fixtures or `setup`.
- The clock seams are gone: `Cybertrain::Cache.clock=`,
  `Cache.system_clock`, `RateLimit.current_time=`, `SessionStore#fixed_now=`,
  `Application.status_now=` and `Background.supervisor_clock=`. Use
  `travel_to`, `travel` or `freeze_time`, whose block puts the time back
  without an `ensure` of your own.
- Mail in tests is kept in `Cybertrain::Mailer.deliveries`; a test that
  reads mail at a `Test::SmtpReceiver` sets
  `Cybertrain.config.mail_delivery_method = :smtp` first.
- A helper test 0.4's `generate helper` wrote defines a top-level
  `render_inline(source)`, which clashes with the framework's: rename it
  `render_helper_template` in that file, calls included.
- `1.month.ago` is `Time.current.months_ago(1)`.
- `assert_equal` fails with Minitest's two-line text; a passing snapshot
  does not change.
- `cybertrain generate authentication`, run again, writes the class-form
  tests and names each old file they replace (`test/authentication.rb`,
  `test/support/app_test.rb`, ...); `--force` deletes them.

## Continuous integration

`cybertrain new` writes `.github/workflows/ci.yml` for the app. It calls the
`setup-cybertrain` action of this repository
([.github/actions/setup-cybertrain](../../.github/actions/setup-cybertrain/action.yml)),
pinned to the CLI's release tag, which installs the SQLite, zlib and OpenSSL
headers and Ruby, reads the framework commit the app is locked to out of
`spin.lock`, fetches the framework at that commit and runs its `cybertrain
doctor` and `cybertrain setup` (with `~/.cybertrain/spinel` cached per Spinel
release and runner image). The workflow then checks that `spin.lock` is
current (`spin lock && git diff --exit-code spin.lock`) and `gen/` is fresh
(`SPIN_DEBUG=1 spin run gen -- --check`), and runs `cybertrain test`. When the toolchain
steps change, the action changes, not every app's copy. The commit is read
from `spin.lock`, so the workflow assumes the default git dependency; an app
made with `--path` passes the framework checkout to the action as
`framework-path`.
