---
title: "Advanced tutorial: taking the blog further"
description: "Carry the Getting Started blog on with CyberTrain: a component and a helper, live comments with Turbo Streams, a background job, JSON, sign-in, an uploaded cover image and a build for deployment with cybertrain build."
og_title: "Advanced tutorial: taking the CyberTrain blog further"
og_description: "Turbo, a background job, JSON, sign-in, uploads and a deployable build, added to the blog of CyberTrain's Getting Started."
og_image: tutorial.png
crumb: Advanced tutorial
nav: tutorial
toc_title: "Steps 13–19"
meta:
  - term: You need
    text: 'The blog from the [tutorial](tutorial.md#test), up to step 12'
  - term: You start from
    text: "`blog/`, with articles, comments and tests"
  - term: You finish with
    text: "`dist/blog`"
---

# Advanced tutorial: taking the&nbsp;blog further

The [tutorial](tutorial.md) ends with a blog of articles and comments. This
page carries the same app on: render comments with a component, push new ones
to every open page with Turbo, queue a background job, answer JSON, add
sign-in, attach an uploaded image and build the app into a deployable `dist/`
folder. The app this grows into is [`examples/blog`](../../examples/blog),
exercised by CI on Linux and macOS.

<!-- step 13 #component stage: You write · `app/components/`, `app/helpers/` -->
## A component and a helper

> [!WHY]
> From the next step on a comment is rendered in two places: on the page, and
> in a broadcast that no request is behind. A component, a class with its
> template beside it, renders the same in both; a helper is a method every
> template can call.

```shell terminal — blog/
cybertrain generate component comment comment   # the name, then its attributes: one, also called comment
cybertrain generate helper comments
```

The first writes `app/components/comment_component.rb`, with one keyword per
attribute, and its template; the second writes an empty `CommentsHelper`.
Each also writes a test, which the end of this step comes back to. The class is
already what the blog needs:

```ruby app/components/comment_component.rb
class CommentComponent < Cybertrain::Component
  def initialize(comment:)
    @comment = comment
  end
end
```

Replace the generated template with the comment's markup, and give the helper
its one method:

```erb app/components/comment_component.html.erb
<div class="comment" id="<%= dom_id(comment) %>">
  <p><%= comment_author(comment) %> wrote:</p>

  <p><%= comment.body %></p>

  <%= button_to "Destroy comment", article_comment_path(comment.article_id, comment), method: :delete %>
</div>
```

```ruby app/helpers/comments_helper.rb
module CommentsHelper
  # The commenter's name in a <strong>, escaped: <%= comment_author(c) %>
  def comment_author(comment)
    name = case comment
           when Comment then comment.commenter.to_s
           else ""
           end
    Cybertrain::Html.tag("strong", { class: "comment-author" }, name)
  end
end
```

Then render the component where the page rendered the partial, and delete
`app/views/comments/_comment.html.erb`:

```erb app/views/articles/show.html.erb (excerpt)
<% @article.comments.each do |comment| %>
  <%= render component: "comment", comment: comment %>
<% end %>
```

<!-- list: points -->
- The template sees the component's instance variables as locals (`comment`)
  and its public methods without parameters by name. It is given the comment
  only, not the page's `@article`, so the button's path is built from
  `comment.article_id`.
- `dom_id(comment)` is `comment_7` for the comment with id 7: the element id
  the next step's broadcasts aim at.
- A component is named as a partial is, by its snake-case name without
  `_component`: templates cannot name constants.
- `Cybertrain::Html.tag` escapes its content and returns a `SafeString`, which
  a template prints as it is; a plain `String` a helper returns is escaped.

> [!RULE] Spinel rule: helpers and components are generated dispatch
> ### Helpers and components are generated dispatch
>
> Templates cannot `send`, so `spin run gen` reads `app/helpers/` and
> `app/components/` as text and writes the dispatch into `gen/helpers.rb` and
> `gen/components.rb`. A helper's parameters are named (no `*rest`, no
> `**opts`), and its arguments arrive as the template's values, which is why
> `comment_author` narrows its argument with `case ... when Comment`. The rest
> is in [Application helpers](template-language.md#application-helpers) and
> [Components](template-language.md#components).

### The component's test

The generated test renders `CommentComponent` with a String where the
template now expects a comment. Render the fixture comment instead:

```ruby test/components/comment_component_test.rb
require "test_helper"

class CommentComponentTest < ViewComponent::TestCase
  test "renders the comment with its author" do
    render_inline(CommentComponent.new(comment: comments(:one)))
    assert_select "div.comment strong.comment-author", text: "MyString"
  end
end
```

`render_inline` renders as a broadcast does, with no request, and
`assert_select` reads what it rendered
([Testing streams and components](testing.md#testing-streams-and-components)).
The helper's test passes as it was generated. Run them as in
[step 12](tutorial.md#test): `cybertrain test`.

<!-- step 14 #turbo stage: Run time · Turbo Streams over Server-Sent Events -->
## Live comments with Turbo

> [!WHY]
> A comment posted in one browser should appear on every open page of that
> article without a reload. As in a Rails 8 app, that is Turbo Streams, and
> there is nothing to install or to start beside the server.

### Load Turbo

`cybertrain new` left both lines commented out; uncomment them:

```ruby config/importmap.rb
pin "application"
pin "@hotwired/turbo", to: "https://cdn.jsdelivr.net/npm/@hotwired/turbo@8.0.12/dist/turbo.es2017-esm.js"
```

```javascript app/javascript/application.js
import "@hotwired/turbo"
```

The layout's `javascript_importmap_tags` writes the import map and
`import "application"`, so every page now runs Turbo
([The import map](assets.md#the-import-map)).

The server side of Turbo Streams is a subsystem: add its line under the
core's in `bin/blog.rb`, and the same line in `bin/db.rb`. Without it,
`spin run gen` stops at the `turbo_stream_from` below and names the line.

```ruby bin/blog.rb (excerpt)
require "cybertrain/core"
require "cybertrain/streams"
```

### Subscribe the page

Give the list and the form an id each, and subscribe the page to the
article's stream:

```erb app/views/articles/show.html.erb (excerpt)
<h2>Comments</h2>

<%= turbo_stream_from @article %>

<div id="comments">
  <% @article.comments.each do |comment| %>
    <%= render component: "comment", comment: comment %>
  <% end %>
</div>

<h2>Add a comment:</h2>

<div id="comment_form">
  <%= render "comments/form", comment: @comment %>
</div>
```

### Broadcast and answer

`create` broadcasts the saved comment, then answers the browser that posted
it; `destroy` tells the other pages to drop the element:

```ruby app/controllers/comments_controller.rb (excerpt)
  def create
    @comment = Comment.new(comment_params)
    @comment.article_id = @article.id
    unless @comment.save
      flash[:alert] = "Comment could not be saved: #{@comment.errors.full_messages.join(", ")}"
      redirect_to article_path(@article), status: :see_other
      return
    end

    # Every page subscribed with turbo_stream_from @article appends the comment.
    Cybertrain::Stream.broadcast_append_to(@article, target: "comments",
                                           component: CommentComponent.new(comment: @comment))
    @new_comment = Comment.new   # the empty form create.turbo_stream.erb puts back
    respond_to do |format|
      format.turbo_stream   # app/views/comments/create.turbo_stream.erb
      format.html do
        flash[:notice] = "Comment was successfully created."
        redirect_to article_path(@article), status: :see_other
      end
    end
  end

  def destroy
    @comment = @article.comments.find(params[:id])
    target = Cybertrain::Html.dom_id(@comment)   # read before destroy clears the id
    @comment.destroy
    Cybertrain::Stream.broadcast_remove_to(@article, target: target)
    flash[:notice] = "Comment was successfully destroyed."
    redirect_to article_path(@article), status: :see_other
  end
```

```erb app/views/comments/create.turbo_stream.erb
<%= turbo_stream.append "comments", html: render(component: "comment", comment: @comment) %>
<%= turbo_stream.update "comment_form", partial: "comments/form", locals: { comment: @new_comment } %>
```

Open one article in two windows and post a comment in one: it appears in
both, and the form that sent it comes back empty.

### What happens

<!-- list: points -->
- `turbo_stream_from @article` writes a `<turbo-stream-source>` element for
  the stream `articles:<id>`, with a signed token. Turbo opens it as an
  `EventSource` on `/cybertrain/stream`, which the server already serves.
- A broadcast is a row in `cybertrain_messages`, a table the framework creates
  itself. Each server process polls it and hands the row to the pages it
  holds, within about a tenth of a second.
- Turbo submits the form asking for a Turbo Stream, so `format.turbo_stream`
  renders `create.turbo_stream.erb`, without a layout. A plain form post, with
  JavaScript off, takes `format.html` and is redirected as before.
- The window that posted gets the comment twice, in the answer and in the
  broadcast, and shows it once: Turbo replaces an element that has the same
  id.

More, including WebSocket and streams for your own JavaScript:
[Realtime](realtime.md#turbo-streams).

> [!NOTE]
> Turbo is fetched from jsDelivr here. To serve it yourself, copy
> `turbo.es2017-esm.js` into `vendor/javascript/` and pin it with
> `to: "turbo.es2017-esm.js"`. If you turn on the Content Security Policy
> `config/app.rb` has commented out, its `script_src` must allow whichever
> origin serves Turbo
> ([Content Security Policy](requests.md#content-security-policy-force_ssl-and-hosts)).

### Test the Turbo Stream answer

A request that asks for a Turbo Stream, as Turbo's form submission does, is
answered with one. Add a test for it to the comments test of
[step 12](tutorial.md#test):

```ruby test/controllers/comments_controller_test.rb (excerpt)
  test "a form Turbo submits is answered with a Turbo Stream" do
    post article_comments_path(articles(:one)), params: { comment: { commenter: "Dave", body: "First!" } },
                                               headers: { "Accept" => "text/vnd.turbo-stream.html, text/html" }
    assert_response :ok
    assert_turbo_stream action: "append", target: "comments"
  end
```

<!-- step 15 #job stage: You write · `app/jobs/` -->
## A background job

> [!WHY]
> Work that should not hold up the response, such as a notification, runs
> on its own, apart from the request: it may start before the response is
> written or after it. As with Active Job on Solid Queue, a job is a class in
> `app/jobs/` and a row in the application's own database: no other service.

```shell terminal — blog/
cybertrain generate job notify_comment --retry StandardError:30:3
```

It writes `app/jobs/notify_comment_job.rb`, with the `retry_on` line the
option asked for and an empty `perform`, and a test, and adds
`require "cybertrain/jobs"` to `bin/blog.rb` and `bin/db.rb`, and uncomments
the `worker` role in `config/deploy.yml` ([step 19](#ship)). Fill `perform` in; this
one only logs, where a real application would send a mail:

```ruby app/jobs/notify_comment_job.rb
class NotifyCommentJob < Cybertrain::Job::Base
  retry_on StandardError, wait: 30, attempts: 3

  def perform(args)
    comment_id = Cybertrain::Cast.int(args["comment_id"])
    article_id = Cybertrain::Cast.int(args["article_id"])
    Cybertrain.logger.info("new comment #{comment_id} on article #{article_id}")
    nil
  end
end
```

Queue it from `create`, once the comment is saved:

```ruby app/controllers/comments_controller.rb (excerpt)
    NotifyCommentJob.perform_later("comment_id" => @comment.id, "article_id" => @article.id)
    # Every page subscribed with turbo_stream_from @article appends the comment.
    Cybertrain::Stream.broadcast_append_to(@article, target: "comments",
                                           component: CommentComponent.new(comment: @comment))
```

Post a comment, and the server's log shows the job running, its lines
tagged with the job and with the id of the request that queued it. Here it
runs after the response; a job thread may also take the row before the
response is written, so the order of the lines can differ:

```text output — cybertrain server
2026-11-14T09:30:00.120Z INFO [3f2a9c1e-6c1d-4f0b-9a52-0d1e2f3a4b5c] Started POST "/articles/1/comments" for 127.0.0.1
2026-11-14T09:30:00.122Z INFO [3f2a9c1e-6c1d-4f0b-9a52-0d1e2f3a4b5c] Completed 200 in 2ms
2026-11-14T09:30:00.950Z INFO [NotifyCommentJob 1] [3f2a9c1e-6c1d-4f0b-9a52-0d1e2f3a4b5c] new comment 1 on article 1
2026-11-14T09:30:00.951Z INFO [NotifyCommentJob 1] [3f2a9c1e-6c1d-4f0b-9a52-0d1e2f3a4b5c] job 1 (NotifyCommentJob) done
```

<!-- list: points -->
- `args` is the Hash given to `perform_later`, stored as JSON and read back
  with String keys: pass ids, not records, and narrow the values with
  `Cybertrain::Cast`. `perform_in(seconds, args)` and `perform_at(time, args)`
  queue it for later.
- Jobs are rows of `cybertrain_jobs`, run by three job threads of the serving
  process, or of a separate one started with `./blog worker`
  ([Process roles](background-and-operations.md#process-roles)).
- `retry_on StandardError, wait: 30, attempts: 3` queues a failed run again
  30 seconds later, three attempts in all; the row is then `failed` and kept
  ([Retries and discards](background-and-operations.md#retries-and-discards)).
- A job can run more than once (a process that dies in the middle of one has
  it run again), so write `perform` to be safe to repeat.
- Failed jobs are listed, retried and discarded with `./blog jobs`, or on the
  jobs page at `/admin/jobs`: the commented `jobs_page` line in
  `config/routes.rb` names `require_admin`, a method
  [step 17](#authentication)'s generator writes, and that generator mounts
  the page for you
  ([The jobs page](background-and-operations.md#the-jobs-page-and-the-jobs-command)).

> [!RULE] Spinel rule: job policies are read as text
> ### Job policies are read as text
>
> `spin run gen` reads each class under `app/jobs/` and writes its other half
> into `gen/jobs.rb`: `perform_later`, and each `retry_on` as a `rescue` arm.
> So `retry_on`, `discard_on` and `limits_concurrency` take one line each with
> literal values: `wait: 30`, not `wait: 30.seconds` or a lambda.

> [!EXAMPLE] Deleting finished jobs every night
> ### Deleting finished jobs every night
>
> Every comment leaves a `done` row behind. `config/app.rb` ends with a
> scheduled task, commented out, that deletes the ones a week old; uncomment
> it:
>
> ```ruby config/app.rb (excerpt)
> Cybertrain::Scheduler.cron("0 4 * * *", "prune done jobs") do
>   Cybertrain::Job.prune_done(Time.now.to_i - 7 * 86_400)
> end
> ```
>
> The cron expression is read in `CYBERTRAIN_SCHEDULER_TZ` (by default the application's `time_zone`, UTC unless set),
> and one process at a time runs the schedule
> ([Scheduled tasks](background-and-operations.md#scheduled-tasks)).

### Test that a comment queues the job

The generator's job test passes as it is. Add one to the comments test that
checks `create` queues the job, and runs it:

```ruby test/controllers/comments_controller_test.rb (excerpt)
  test "a comment queues its notification" do
    post article_comments_path(articles(:one)), params: { comment: { commenter: "Dave", body: "First!" } }
    assert_enqueued_with "NotifyCommentJob", { "comment_id" => Comment.last.id }
    assert_equal 1, perform_enqueued_jobs
  end
```

A test runs no job thread, so a queued job waits until the test runs it
(`perform_enqueued_jobs`); the other job assertions are in
[Testing jobs](testing.md#testing-jobs).

<!-- step 16 #json stage: You write · `app/controllers/` -->
## Answer JSON

> [!WHY]
> One action can serve the page and an API: `respond_to`, as in Rails.

```ruby app/controllers/articles_controller.rb (excerpt)
  def index
    @articles = Article.all.to_a
    respond_to do |format|
      format.html
      format.json { render json: @articles.map(&:as_json) }
    end
  end

  def show
    @comment = Comment.new
    respond_to do |format|
      format.html
      format.json { render json: @article.as_json }
    end
  end
```

```console terminal — blog/
$ curl http://127.0.0.1:3000/articles.json
[{"id":1,"title":"Hello Rails","body":"I am on Rails! This is my first article.","created_at":"2026-11-12T10:22:45.852Z","updated_at":"2026-11-12T10:22:45.852Z"}]
```

<!-- list: points -->
- The format comes from the extension (`/articles.json`) or, without one,
  from the `Accept` header. A format the action does not list, such as
  `/articles.xml`, is answered `406 Not Acceptable`.
- `format.html` without a block renders the action's template, as before.
- `as_json` is the record's columns, times in ISO 8601, UTC. JSON has no
  templates: an action answers it with `render json:`.
- Keep the block to its `format.` lines: when a request falls back to html
  the block runs a second time.

`/articles/1.json` is one article, from the same block in `show`. Everything
about formats: [Formats and `respond_to`](requests.md#formats-and-respond_to).

<!-- step 17 #authentication stage: You write · `app/`, `db/migrate/`, `config/routes.rb`, `test/` -->
## Add sign-in

> [!WHY]
> So far anyone can edit or delete an article. Like Rails 8&rsquo;s
> `bin/rails generate authentication`, one command adds email-and-password
> sign-in, written as code the app owns rather than installed as an engine.

```shell terminal — blog/
cybertrain generate authentication
cybertrain db migrate    # creates the users and sessions tables
```

It writes the `users` and `sessions` migrations and models, the
`Authentication` concern, which it includes into `ApplicationController`,
controllers and views for signing in, signing up, resetting a password and
the account page, a mailer, the `./blog user` command, and tests. It also
adds the routes (the jobs page at `/admin/jobs`, for admins, among them), a `sessions/_nav` partial at the top of the layout, and a
`base_url` setting in `config/app.rb`, where links in mails start, and the
lines of the subsystems its code uses to `bin/blog.rb` and `bin/db.rb`:
`cybertrain/jobs` (the jobs page and the thread that sends mail),
`cybertrain/mailer`, `cybertrain/mailer/later` (mails go out with
`deliver_later`) and `cybertrain/rate_limit` (sign-in attempts are rate
limited, below). Every file is listed in
[Authentication](authentication.md#generating-it).

```ruby app/controllers/concerns/authentication.rb (excerpt)
module Authentication
  extend ActiveSupport::Concern

  included do
    before_action :resume_session          # sets @current_user and @current_session
    before_action :require_authentication  # 303 to /session/new unless signed in
    helper_method :authenticated?
  end
```

From now on every action needs a signed-in user, and a visitor is redirected
to `/session/new`. Open the pages anyone may read again, as Rails&rsquo; guide
does:

```ruby app/controllers/articles_controller.rb (excerpt)
class ArticlesController < ApplicationController
  allow_unauthenticated_access only: [:index, :show]
  before_action :set_article, only: [:show, :edit, :update, :destroy]
```

`resume_session` still runs on those pages, so templates can read
`@current_user`. Hide what a visitor cannot use:

```erb app/views/articles/show.html.erb (excerpt)
<% if @current_user %>
  <%= button_to "Destroy this article", article_path(@article), method: :delete %>
<% end %>

<% if @current_user %>
  <h2>Add a comment:</h2>

  <div id="comment_form">
    <%= render "comments/form", comment: @comment %>
  </div>
<% end %>
```

The comment component keeps its "Destroy comment" button for everyone: a
broadcast renders it once for all viewers, with no request and so no current
user. A visitor who clicks it is sent to the sign-in page, since
`CommentsController` opens no action; new comments still reach a visitor's
page, because the stream is not an action of a controller.

Start the server and open `http://127.0.0.1:3000/sign_up` to create the first
user. Rails&rsquo; generator has no sign-up page and leaves that to the
console; CyberTrain writes `RegistrationsController`, so the first user signs
up in the browser. For an invitation-only app, run the generator with
`--invite-only` instead: there is no sign-up page, and the first user comes
from `./blog user EMAIL` or from a `/setup` page only the server's own
machine can open
([Sign-up, or invite-only](authentication.md#sign-up-or-invite-only)).

The sign-in page also links to a password reset by mail, and the nav to an
account page; the [Authentication](authentication.md) guide covers them,
with lockout, "keep me signed in", `--confirmable` and admin users. A reset
mail needs the SMTP settings and, in production, `BLOG_BASE_URL`
([Links in mails](authentication.md#links-in-mails)).

> [!RULE] has_secure_password is written out
> ### `has_secure_password` is written out
>
> CyberTrain has no `has_secure_password` macro. The generator writes what it
> would define into the `User` model, as code the application owns:
> `password=`, `authenticate` and
> `User.authenticate_by(email_address:, password:)`. Passwords are hashed by
> `Cybertrain::Password`, PBKDF2-HMAC-SHA256 in Ruby, 100,000 iterations by
> default (about 0.2 s compiled): bcrypt would need a C library the binary
> links. Raise the cost with `Cybertrain::Password.iterations = 600_000` in
> `config/app.rb`; `User#authenticate` rehashes each user as they sign in.

### Update the tests

Any test of [step 12](tutorial.md#test) or since that opens a form, submits one, or reaches an
action other than `index` and `show` now meets the sign-in page instead. The
generator wrote `test/fixtures/users.yml` (`one` and `two`, whose password
is `"password"`) and `test/support/session_test_helper.rb`, whose
`sign_in_as` `test/test_helper.rb` now gives every integration test, and
the generator added the sign-in to the articles test's `setup` (it prints `insert
test/controllers/articles_controller_test.rb (sign_in_as users(:one))`), so
you will find:

```ruby test/controllers/articles_controller_test.rb (excerpt)
  setup do
    sign_in_as users(:one)
    @article = articles(:one)
  end
```

The comments test has no `setup` for the generator to add to, and every
action of `CommentsController` (create and destroy) now needs a signed-in
user, so each of its four tests does too; give it one:

```ruby test/controllers/comments_controller_test.rb (excerpt)
class CommentsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in_as users(:one)
  end
```

A scaffold generated from now on signs in by itself.

> [!NOTE]
> The generator's own tests (`test/controllers/sessions_controller_test.rb`,
> `registrations_controller_test.rb`, `passwords_controller_test.rb`,
> `accounts_controller_test.rb`, `test/integration/remember_me_test.rb`,
> `lockout_test.rb`, `admin_test.rb`, [Testing](authentication.md#testing))
> run with the rest under `cybertrain test`, moving the clock with
> `travel_to` to check day 15 and day 30. Sign-in attempts are rate
> limited as in Rails' generator, ten per client address every three
> minutes, counted in the application's database so that every process
> counts together; behind a reverse proxy, configure
> [trusted proxies](requests.md#rate-limiting-and-the-client-address).
> `examples/blog` takes this step with `--invite-only` and makes its
> `/admin` pages admin-only.

<!-- step 18 #attachments stage: You write · `app/`, `db/migrate/`, `config/routes.rb`, `test/` -->
## Add a cover image

> [!WHY]
> An article can carry a picture. The same split as sign-in: the framework
> parses `multipart/form-data` and stores the bytes, and one command writes
> the rest as code the app owns, in place of Active Storage&rsquo;s
> `has_one_attached`.

The image will be shown on the article page, which visitors may read since
step 17, so its download has to be open to them too. Before running the
generator, add `:cover` to the list step 17 wrote. The download will not
run the code inside `def show` either, and this `show` has some (it builds a
blank comment for the form and picks a format), so the generator stops unless
`--show-checks-nothing` says that code limits nobody, which this code does
not:

```ruby app/controllers/articles_controller.rb (excerpt)
  allow_unauthenticated_access only: [:index, :show, :cover]
```

```shell terminal — blog/
cybertrain generate attachment article cover --show-checks-nothing   # a new model: generate scaffold NAME field:type ... cover:attachment
cybertrain db migrate                                                # adds the cover_* columns to articles
```

It writes a migration that adds five columns to `articles` (`cover_key`,
`cover_filename`, `cover_content_type`, `cover_byte_size`, `cover_checksum`;
the file itself is not in SQLite) and a block in `Article` with `cover_file=`,
`cover_attached?`, `cover_url`, a validation and save and destroy callbacks.
In `ArticlesController` it adds a `cover` action behind
`before_action :set_article` and one line in `create` and in `update`:

```ruby app/controllers/articles_controller.rb (excerpt)
class ArticlesController < ApplicationController
  allow_unauthenticated_access only: [:index, :show, :cover]   # step 17 wrote [:index, :show]; you added :cover
  before_action :set_article, only: [:show, :edit, :update, :destroy, :cover]

  # GET /articles/1/cover -- @article comes from before_action :set_article, so
  # the download is scoped exactly like show (and authentication applies).
  # send_blob is the one way to serve uploads: it sets the type from what the
  # server detected, nosniff, a locked-down CSP and Content-Disposition
  # (inline for images only, a download otherwise).
  def cover
    if @article.cover_attached? && Cybertrain::BlobStore.exist?(@article.cover_key)
      send_blob(Cybertrain::BlobStore.read(@article.cover_key), filename: @article.cover_filename, content_type: @article.cover_content_type)
    else
      head 404
    end
  end
  # ...
  def create
    @article = Article.new(article_params)
    @article.cover_file = params.nested(:article).upload(:cover)
    if @article.save
  # ...
  def update
    @article.cover_file = params.nested(:article).upload(:cover)
    if @article.update(article_params)
```

The download finds its article through `set_article`, as `show` does, so
whatever `set_article` does to limit which articles a user may see limits the
download too. Among its lines the generator still prints a warning, because
this `show` has code of its own:

```text output — cybertrain generate attachment
warning: app/controllers/articles_controller.rb: def show has code of its own, which def cover does not run; if that code limits who may see articles, check the same in def cover
```

Here that code builds a comment and picks a format; it refuses nobody, so
there is nothing to copy into `cover`. Had it refused someone (`head 404 if
@article.draft?`), the place for that check is a `before_action` listing both
`:show` and `:cover`, which the generator reads. Moving it out does not empty
this `show`, which still builds the comment and picks the format, so the
generator would still stop: run it with an empty `show`, or with
`--show-checks-nothing` once the code left in `show` limits nobody.

The generator also adds `get "/articles/:id/cover"` to `config/routes.rb`,
`multipart: true` and a file input to the form, above the submit button, and
the image to the show page, right after the `<h1>`:

```erb app/views/articles/_form.html.erb (excerpt)
<%= form_with(model: article, multipart: true) do |f| %>
  <%# ... %>
  <div class="field">
    <%= f.label :cover %>
    <%= f.file_field :cover, accept: "image/png,image/jpeg,image/gif,image/webp" %>
  </div>
```

```erb app/views/articles/show.html.erb (excerpt)
<h1>Article</h1>
<% if @article.cover_attached? %><p><img src="<%= @article.cover_url %>" alt="<%= @article.cover_filename %>"></p><% end %>
```

> [!NOTE]
> The generator copies the access rules of `show` to the download, and only
> those it can read: the callbacks. A `before_action` other than `set_article`
> that lists `:show` without the new action stops it with `cannot preserve
> show's authorization for :cover`, and nothing is written. Code inside
> `def show` it cannot read for what it checks, so it stops the same way
> unless `--show-checks-nothing` vouches for it, and then warns. With an
> empty `show` it adds `:cover` to `allow_unauthenticated_access` by itself
> where `:show` is listed; with code in `show` it leaves the line alone, and
> without `:cover` there the image needs a sign-in.

> [!RULE] has_one_attached is written out
> ### `has_one_attached` is written out
>
> There is no `has_one_attached` and no shared attachments table: allowed
> types, sizes and who may download differ per application, so the generator
> spells the methods out, named after the field, in `Article`, and puts
> the metadata in five columns of `articles`. They are `NOT NULL`, with `""` and
> `0` meaning &ldquo;nothing attached&rdquo;: nullable columns cost Spinel its
> type inference. SQLite holds the metadata only (a text value stops at a NUL
> byte); the bytes are files.

### How files are served

<!-- list: points -->
- **Types.** By default only PNG, JPEG, GIF and WebP up to 2 MB are accepted
  (`COVER_TYPES` and `COVER_MAX_BYTES` in the model; `--any` accepts any
  type). The type is detected from the file&rsquo;s first bytes, never taken
  from the browser.
- **Storage.** The bytes go to `storage/uploads/<2 hex>/<32 hex key>`
  (`Cybertrain::BlobStore`, mode 0600). Replacing a file deletes the old one,
  and destroying the article deletes its file. Back up `storage/uploads/`
  together with the SQLite file.
- **Serving.** Files go out through `send_blob` in the controller, never from
  `public/`. The four image types are served inline; anything else is a
  download (`application/octet-stream`). Every response carries
  `X-Content-Type-Options: nosniff` and
  `Content-Security-Policy: default-src 'none'; sandbox`.
- **Params.** `params.nested(:article).upload(:cover)` is a
  `Cybertrain::UploadedFile`, or nil when no file was chosen. `permit` never
  returns files, so a file can only arrive through that explicit line. The
  CSRF token is read from multipart bodies like any form&rsquo;s. A broken or
  oversize body is a 400; `max_upload_bytes` and `max_multipart_parts` in
  `config/app.rb` set the limits, and `upload_root` the directory.

Start the server, edit an article and choose an image. The generator also
wrote `test/integration/article_cover_attachment_test.rb` and the image
`test/fixtures/files/cover.png`, which test the whole flow and sign
in first now that the app has a `User`. Since `:cover` is public here, it
checks that a visitor can download the cover, and it fills the body with
`"A article."`, stretched to the 10-character minimum from
[step 05](tutorial.md#validations).

> [!NOTE]
> Run `cybertrain test` as in [step 12](tutorial.md#test) (measured on 2026-11-13,
> the tutorial's blog then runs 83 tests and 870 assertions). `examples/blog` has this
> step too, and keeps the `cover_*` columns out of its JSON
> (`Article#public_json`). Not built yet: several files per field, S3 or other remote
> storage, image variants, and streaming large bodies to disk (the whole body
> is read into memory, up to `max_body_bytes`).

<!-- step 19 #ship stage: Run time · `dist/blog` -->
## Build for deployment

> [!WHY]
> One command builds the app into a deployable `dist/` folder, with every view
> embedded.

```shell terminal — blog/
cybertrain build
```

This writes `dist/`: the app binary with every view embedded, plus the files
it uses beside it. It runs `SPIN_DEBUG=1 spin run gen -- --embed-views`,
`spin build blog` and `SPIN_DEBUG=1 spin run gen` (which puts the committed, empty `gen/views.rb` back, even
after a failure or Ctrl-C), then assembles:

<ul class="ship-grid">
  <li class="ship-bin"><code>dist/blog</code><span>the compiled framework, controllers, models and template interpreter, with every view embedded</span></li>
  <li><code>dist/public/</code><span>static assets and error pages, or let a reverse proxy serve it</span></li>
  <li><code>dist/storage/</code><span>created empty; the SQLite file by default (a rebuild never empties it)</span></li>
  <li><code>dist/tmp/</code><span>created empty (a rebuild never empties it)</span></li>
</ul>

Copy `dist/` to a machine with the same OS and CPU (the binary links the
system SQLite) and run it there. A built binary is production by default
(`CYBERTRAIN_ENV` overrides). Set `CYBERTRAIN_SECRET_KEY_BASE`
(`cybertrain secret` prints one too); for illustration:

```shell terminal — production host
cd dist
export CYBERTRAIN_SECRET_KEY_BASE="$(openssl rand -hex 32)"
./blog migrate && ./blog
```

`./blog migrate` applies the migrations compiled into the binary, and
`./blog db status` shows their status; `PORT` sets the port. Keep the secret
the same across restarts: changing it ends every session. `./blog help` lists
the binary's other commands, among them `worker`, `jobs`, `console` and
`db backup`.

`Cybertrain::Config` reads the environment first; `config/app.rb` overrides.
The variables a first deploy meets (all of them:
[Configuration](configuration.md#configuration-and-environment-variables)):

<div class="table-scroll" role="region" aria-label="Environment variables" tabindex="0" markdown="0">
<table class="env">
  <thead><tr><th scope="col">Variable</th><th scope="col">Attribute</th><th scope="col">Default</th></tr></thead>
  <tbody>
    <tr><td data-label="Variable"><code>CYBERTRAIN_ENV</code></td><td data-label="Attribute"><code>env</code></td><td data-label="Default"><code>"development"</code>; <code>"production"</code> in a binary from <code>cybertrain build</code> (also <code>"test"</code>)</td></tr>
    <tr><td data-label="Variable"><code>PORT</code></td><td data-label="Attribute"><code>port</code></td><td data-label="Default"><code>3000</code></td></tr>
    <tr><td data-label="Variable"><code>CYBERTRAIN_DATABASE</code></td><td data-label="Attribute"><code>database_path</code></td><td data-label="Default"><code>storage/#{env}.sqlite3</code></td></tr>
    <tr><td data-label="Variable"><code>CYBERTRAIN_SECRET_KEY_BASE</code></td><td data-label="Attribute"><code>secret_key_base</code></td><td data-label="Default">required in production; dev/test auto-generate one into <code>tmp/secret_key</code></td></tr>
    <tr><td data-label="Variable"><code>SPINEL_WORKERS</code></td><td data-label="Attribute"><code>workers</code></td><td data-label="Default"><code>1</code></td></tr>
    <tr><td data-label="Variable"><code>CYBERTRAIN_HOST</code></td><td data-label="Attribute"><code>host</code></td><td data-label="Default"><code>"127.0.0.1"</code>; <code>0.0.0.0</code> listens on every interface (containers)</td></tr>
    <tr><td data-label="Variable"><code>CYBERTRAIN_SESSION_SAME_SITE</code></td><td data-label="Attribute"><code>session_same_site</code></td><td data-label="Default"><code>"Lax"</code>; also <code>Strict</code> or <code>None</code> (<code>None</code> always adds <code>Secure</code>); anything else stops the server at boot</td></tr>
    <tr><td data-label="Variable"><code>CYBERTRAIN_SESSION_PARTITIONED</code></td><td data-label="Attribute"><code>session_partitioned</code></td><td data-label="Default"><code>false</code>; <code>1</code> or <code>true</code> adds <code>Partitioned</code> (and <code>Secure</code>)</td></tr>
  </tbody>
</table>
</div>

```ruby config/app.rb
# config/app.rb
Cybertrain.configure do |c|
  c.port = 3000
  c.workers = 1
end
```

<!-- list: points -->
- The server speaks plain HTTP/1.1: put nginx or Caddy in front for TLS and
  HTTP/2. The session cookie is `Secure` in production, so serve it over HTTPS
  (set `c.session_secure = false` in `config/app.rb` only if production really
  is plain http). Behind such a proxy, `CYBERTRAIN_FORCE_SSL=1` redirects http
  to https and `CYBERTRAIN_HOSTS` names the hosts the app answers to
  ([hosts and `force_ssl`](requests.md#content-security-policy-force_ssl-and-hosts)).
- The serving process also runs the jobs, the scheduled tasks and the stream
  poller of steps 14 and 15: one process is a whole deployment. `./blog
  worker` moves the jobs into a process of their own
  ([Process roles](background-and-operations.md#process-roles)).
- Production refuses to start without `CYBERTRAIN_SECRET_KEY_BASE`.
- In production an exception answers 500, and a bare error response (the
  router's plain-text 404, `head :not_found`, `render plain:`) is replaced by
  `public/<status>.html` when that file exists; `cybertrain new` writes
  `404.html` and `500.html`.
- `SIGTERM` stops accepting, lets requests in flight finish and exits when
  they are done, or after the server's `drain_timeout` (10 s).
- The watcher, the CRuby preview and the rebuild loop never run in
  production. A running `cybertrain server` regenerates and restarts
  nothing while `cybertrain build` holds `tmp/cybertrain-build.lock`.

`cybertrain new` also writes a [Kamal 2](https://kamal-deploy.org) setup. The
`Dockerfile` runs `cybertrain setup` and `cybertrain build` in an Ubuntu build
stage and copies `dist/` into a slim stage of the same release, which migrates
on boot and then serves on `0.0.0.0:3000`. Beside it are `.dockerignore`,
`config/deploy.yml` (kamal-proxy with Let&rsquo;s Encrypt in front, the health
check on `public/up.html`, the SQLite file on a volume at `/app/storage`, and
the `worker` role step 15 uncommented: a second container of the same image
running `./blog worker`; the web role runs jobs too unless
`CYBERTRAIN_WORKER` is 0) and
`.kamal/secrets`, which reads `KAMAL_REGISTRY_PASSWORD` and
`CYBERTRAIN_SECRET_KEY_BASE` from the environment. Fill in the values marked
`CHANGE ME` in `config/deploy.yml`, commit, then:

```shell terminal — blog/
kamal setup    # first time: installs Docker and kamal-proxy on the server, builds, pushes and starts
kamal deploy   # every deploy after that
```

The binary is compiled inside the image, so it always matches the
image&rsquo;s OS; set `builder.arch` in `config/deploy.yml` to the
server&rsquo;s CPU. Deploy to one server: the database is a SQLite file on
that server&rsquo;s volume. Part 8 of
[`docs/deploy.md`](../../docs/deploy.md#第-8-部-kamal-でデプロイする) (Japanese; in
English, [`docs/deploy-kamal.md`](../../docs/deploy-kamal.md)) walks through
it, backups included.

The finished app, [`examples/blog`](../../examples/blog#deploying-with-kamal),
carries this setup with one difference: it builds against the framework in the
repository (`path = "../.."` in its `spin.toml`), so its `Dockerfile` runs
`cybertrain setup` and `cybertrain build` from the checkout instead of
installing the gem, and the build context is the repository root
(`builder.context: ../..`, with `Dockerfile.dockerignore` sending only the
framework and the app). CI
([`blog-image.yml`](../../.github/workflows/blog-image.yml)) builds that image
for every release, checks the health check, an article created through the form,
a clean stop and the database kept on its volume, and loads
`config/deploy.yml` with Kamal.

> [!NOTE]
> How these pieces fit together, and Kamal compared with a server behind
> Caddy, are on the [deploy page](site:deploy.html).

<!-- step + #things-to-know -->
## Things to know

> [!WHY]
> Limits and quirks worth knowing before they surprise you.

<!-- list: points know -->
- Sessions hold Strings only, in an encrypted cookie.
- SQLite only, through Spinel&rsquo;s FFI.
- No backtraces: errors show class, message, request line and template
  name/line.
- A misspelled attribute in a view raises (`undefined method 'titel' for
  Article`); a column that holds `nil` renders empty.
- Associations come from foreign keys or one-line declarations; no
  `has_many :through`, nested `includes`, enums, STI or polymorphic
  associations.
- No `constraints` or `mount`; JSON is answered with `render json:` (there
  are no JSON templates).
- Only the first string field gets a default presence validation in a
  scaffolded model.
- The generator uses a lexical scan (regexes), not a parser, over
  `app/controllers`, `app/models`, `app/helpers`, `app/components` and
  `app/jobs`.
- Jobs run at least once, and a broadcast reaches only the pages open when it
  is sent, or reconnecting within a minute.
- Views are embedded at build time: a view-only change needs
  `cybertrain build` and a restart before it reaches production.
- Build `dist/` on the same OS and CPU as the machine that runs it: the binary
  links the system SQLite.
- `SPINEL_WORKERS` defaults to `1`.
- Only the pinned Spinel release (`Cybertrain::SPINEL_TAG`) is tested.
- More differences from Rails, in one table: [Differences from Rails](how-it-works.md#differences-from-rails).

<!-- step → #where-next -->
## Where next

<!-- list: next-list -->
- [**`examples/blog`**](../../examples/blog) — The app this tutorial grows into, with its tests.
- [**Deploying**](site:deploy.html) — How the built app runs in production: Kamal, or systemd behind Caddy.
- [**Authentication**](authentication.md) — Password reset, confirmation, lockout, remember me, the account page and admin users.
- [**Internationalization**](i18n.md) — Dictionaries, `t` and `l`, and a locale per request.
- [**Guides**](index.md) — One page per topic: models, requests, templates, realtime, background work, testing.
- [**CyberTrain on GitHub**](https://github.com/saeki-mototsune/CyberTrain) — The source, the README and releases.
- [**API reference**](site:api/index.html) — Every class and method an app uses, with examples.
- [**`spikes/NOTES.md`**](../../spikes/NOTES.md) — Spikes and the compiler constraints they found.
- [**Spinel**](https://github.com/matz/spinel) — matz's ahead-of-time Ruby compiler.
- [**CyberTrain home**](site:index.html) — Overview, features and how it works.
