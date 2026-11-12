require "cybertrain/test"
require "cybertrain/controller"
require "cybertrain/router"
require "cybertrain/app"
require "cybertrain/test/client"

# cybertrain/controller links SQLite through FFI, so this program cannot run
# under CRuby: its snapshot comes from the compiled binary (spikes/NOTES.md
# rule 23).
#
# respond_to, the implicit render by format and 406 Not Acceptable, through
# the whole stack (router, format extension, Accept). Controllers and routes
# are hand-written in the shape gen/controllers.rb and gen/routes.rb emit;
# templates are test/fixtures/views/formats/**.

TURBO_ACCEPT = { "accept" => "text/vnd.turbo-stream.html, text/html" }
JSON_ACCEPT = { "accept" => "application/json" }

# Stands in for a record: as_json is what a `format.json` block renders.
class Article
  def initialize(id, title)
    @id = id
    @title = title
  end

  def as_json
    { "id" => @id, "title" => @title }
  end
end

class ArticlesController < Cybertrain::Controller
  # No respond_to: html renders index.html.erb, csv index.csv.erb, and json
  # (no index.json.erb) answers 406.
  def index
    @id = 1
    @title = "Hello"
  end

  def show
    @id = 1
    @title = "Hello"
    @article = Article.new(1, "Hello")
    respond_to do |format|
      format.html
      format.json { render json: @article.as_json }
      format.turbo_stream
    end
  end

  # No respond_to: a turbo_stream request renders create.turbo_stream.erb.
  def create
    @title = "Hello"
  end

  def pick
    @article = Article.new(1, "Hello")
    respond_to do |format|
      format.json { render json: @article.as_json }
      format.any { render plain: "any" }
    end
  end

  def edit
    respond_to do |format|
      format.html { render plain: "html arm" }
      format.json { render json: Article.new(2, "Edit").as_json }
    end
  end

  # The html arm sets an ivar and renders nothing: the implicit render
  # follows the arm that matched (peek.html.erb), not the request's
  # turbo_stream format (peek.turbo_stream.erb exists too).
  def peek
    @title = "Hello"
    respond_to do |format|
      format.html { @title = "From html" }
    end
  end

  # `render :show` in the turbo_stream arm renders show.turbo_stream.erb.
  def stream_show
    @id = 1
    @title = "Hello"
    respond_to do |format|
      format.turbo_stream { render :show }
      format.html { render :show }
    end
  end

  def varied
    response.set_header("Vary", "Accept-Encoding")
    render plain: "varied"
  end

  # What gen/controllers.rb emits for this class.
  def view_assigns
    { "id" => @id, "title" => @title }
  end
end

class NotesController < Cybertrain::Controller
  def show
    @id = params[:id].to_s
    response.set_header("X-Seen", "#{params[:id]} #{request.format}")
  end

  def view_assigns
    { "id" => @id }
  end
end

Cybertrain::Views.configure("test/fixtures/views/formats", cache: true)

def build_app
  router = Cybertrain::Router.new
  router.add("GET", "/articles", "") { |ctx| ArticlesController.new(ctx).process(:index) { |c| c.index } }
  router.add("POST", "/articles", "") { |ctx| ArticlesController.new(ctx).process(:create) { |c| c.create } }
  router.add("PATCH", "/articles/:id", "") { |ctx| ArticlesController.new(ctx).process(:edit) { |c| c.edit } }
  router.add("GET", "/articles/:id/pick", "") { |ctx| ArticlesController.new(ctx).process(:pick) { |c| c.pick } }
  router.add("GET", "/articles/:id/peek", "") { |ctx| ArticlesController.new(ctx).process(:peek) { |c| c.peek } }
  router.add("GET", "/articles/:id/stream_show", "") { |ctx| ArticlesController.new(ctx).process(:stream_show) { |c| c.stream_show } }
  router.add("GET", "/varied", "") { |ctx| ArticlesController.new(ctx).process(:varied) { |c| c.varied } }
  router.add("GET", "/articles/:id", "") { |ctx| ArticlesController.new(ctx).process(:show) { |c| c.show } }
  router.add("GET", "/notes/:id", "") { |ctx| NotesController.new(ctx).process(:show) { |c| c.show } }
  Cybertrain::App.new(router, public_root: "test/no_such_public_dir", logging: false)
end

client = Cybertrain::Test::Client.new(build_app)

test "respond_to picks html, json or turbo_stream" do
  html = client.get("/articles/1")
  assert_equal "<p>Hello</p>", html.body.strip
  assert_equal "text/html; charset=utf-8", html.header("content-type")
  json = client.get("/articles/1.json")
  assert_equal "application/json; charset=utf-8", json.header("content-type")
  assert_equal "{\"id\":1,\"title\":\"Hello\"}", json.body
  ts = client.get("/articles/1", TURBO_ACCEPT)
  assert_equal "text/vnd.turbo-stream.html; charset=utf-8", ts.header("content-type")
  assert_equal "<turbo-stream action=\"replace\" target=\"article_1\"><template><p>Hello</p></template></turbo-stream>",
               ts.body.strip
end

test "a format the action does not list is 406" do
  res = client.get("/articles/1.xml")
  assert_equal 406, res.status
  assert_equal "Not Acceptable", res.body
  assert_equal "text/plain; charset=utf-8", res.header("content-type")
end

test "implicit rendering: create.turbo_stream.erb without a layout; index.csv.erb" do
  Cybertrain::Views.layout_name = "layouts/wrap"
  html = client.get("/articles")
  ts = client.post("/articles", {}, TURBO_ACCEPT)
  csv = client.get("/articles.csv")
  Cybertrain::Views.layout_name = "layouts/application"
  # The layout exists and wraps the html render...
  assert html.body.start_with?("<html class=\"wrap\">")
  # ...but not the turbo_stream or csv one.
  assert_equal 200, ts.status
  assert ts.body.start_with?("<turbo-stream action=\"append\"")
  refute ts.body.include?("<html")
  assert_equal "text/vnd.turbo-stream.html; charset=utf-8", ts.header("content-type")
  assert_equal 200, csv.status
  assert_equal "text/csv; charset=utf-8", csv.header("content-type")
  assert_equal "id,title\n1,Hello\n", csv.body
end

test "an unregistered extension reaches the action and an implicit render is 406" do
  assert_equal "<p>Note 1</p>", client.get("/notes/1").body.strip
  res = client.get("/notes/1.v2")
  assert_equal "1 unknown", res.header("x-seen")
  assert_equal 406, res.status
  assert_equal "Not Acceptable", res.body
end

test "json without a template and without render is 406" do
  res = client.get("/articles.json")
  assert_equal 406, res.status
  assert_equal "Not Acceptable", res.body
  res = client.get("/articles", JSON_ACCEPT)
  assert_equal 406, res.status
end

test "blocks see ivars and stop at the first match" do
  res = client.get("/articles/1/pick", JSON_ACCEPT)
  assert_equal "{\"id\":1,\"title\":\"Hello\"}", res.body
  assert_equal "application/json; charset=utf-8", res.header("content-type")
  # any matches a format no arm before it listed.
  assert_equal "any", client.get("/articles/1/pick.xml").body
  assert_equal "any", client.get("/articles/1/pick").body
  # ...but not an unregistered extension.
  assert_equal 406, client.get("/articles/1/pick.v2").status
end

test "a Turbo request that also takes html falls back to the html answer" do
  res = client.patch("/articles/1", {}, TURBO_ACCEPT)
  assert_equal "html arm", res.body
  res = client.get("/articles", TURBO_ACCEPT)
  assert_equal 200, res.status
  assert_equal "text/html; charset=utf-8", res.header("content-type")
  assert_equal "<p>Index</p>", res.body.strip
  # Asking for the stream alone, by Accept or extension, is 406.
  only_stream = { "accept" => "text/vnd.turbo-stream.html" }
  assert_equal 406, client.patch("/articles/1", {}, only_stream).status
  assert_equal 406, client.get("/articles", only_stream).status
  assert_equal 406, client.get("/articles.turbo_stream", TURBO_ACCEPT).status
end

test "the implicit render after a respond_to arm follows the format the arm matched" do
  res = client.get("/articles/1/peek", TURBO_ACCEPT)
  assert_equal 200, res.status
  assert_equal "text/html; charset=utf-8", res.header("content-type")
  assert_equal "<p>Peek From html</p>", res.body.strip
end

test "render :x inside a non-html arm renders that format's template" do
  ts = client.get("/articles/1/stream_show", TURBO_ACCEPT)
  assert_equal "text/vnd.turbo-stream.html; charset=utf-8", ts.header("content-type")
  assert ts.body.start_with?("<turbo-stream action=\"replace\" target=\"article_1\">"), ts.body
  html = client.get("/articles/1/stream_show")
  assert_equal "text/html; charset=utf-8", html.header("content-type")
  assert_equal "<p>Hello</p>", html.body.strip
end

AXIOS_ACCEPT = { "accept" => "application/json, text/plain, */*" }

test "any format from an Accept that lists */* falls back to html (axios)" do
  res = client.get("/articles", AXIOS_ACCEPT)
  assert_equal 200, res.status
  assert_equal "text/html; charset=utf-8", res.header("content-type")
  assert_equal "<p>Index</p>", res.body.strip
  # an action that answers json still answers it
  assert_equal "{\"id\":2,\"title\":\"Edit\"}", client.patch("/articles/1", {}, AXIOS_ACCEPT).body
  # neither text/html nor */*: still 406
  assert_equal 406, client.get("/articles", JSON_ACCEPT).status
  # an extension asks for its format alone
  assert_equal 406, client.get("/articles.json", AXIOS_ACCEPT).status
end

test "text/html refused with q=0 is no fallback, with or without a wildcard" do
  # implicit render: index has an html template only
  assert_equal 406, client.get("/articles", { "accept" => "application/json, text/html;q=0" }).status
  assert_equal 406, client.get("/articles", { "accept" => "application/json, text/html;q=0, */*" }).status
  assert_equal 406, client.get("/articles", { "accept" => "application/json, */*, Text/HTML ; Q=0.0" }).status
  # respond_to: peek offers format.html only
  assert_equal 406, client.get("/articles/1/peek", { "accept" => "text/vnd.turbo-stream.html, text/html;q=0" }).status
  assert_equal 406, client.get("/articles/1/peek", { "accept" => "application/json, text/html;q=0, */*;q=0.5" }).status
  # a wildcard refused with q=0 offers nothing either
  assert_equal 406, client.get("/articles", { "accept" => "application/json, */*;q=0" }).status
  # also on the 406: the answer depended on Accept
  assert_equal "Accept", client.get("/articles", { "accept" => "application/json, text/html;q=0" }).header("Vary")
end

test "a low but non-zero q still takes html" do
  res = client.get("/articles", { "accept" => "application/json, text/html;q=0.1" })
  assert_equal 200, res.status
  assert_equal "text/html; charset=utf-8", res.header("content-type")
  assert_equal "<p>Index</p>", res.body.strip
  assert_equal 200, client.get("/articles", { "accept" => "application/json, */*;q=0.1" }).status
  assert_equal 200, client.get("/articles", { "accept" => "application/json, text/html;level=1" }).status
  # text/html wins over a refused wildcard: it is the more specific entry
  assert_equal 200, client.get("/articles", { "accept" => "application/json, */*;q=0, text/html" }).status
  peek = client.get("/articles/1/peek", { "accept" => "application/json, text/html;q=0.5" })
  assert_equal "<p>Peek From html</p>", peek.body.strip
end

test "a format chosen by Accept sends Vary: Accept" do
  assert_equal "Accept", client.get("/articles/1", TURBO_ACCEPT).header("Vary")
  assert_equal "Accept", client.get("/articles/1", JSON_ACCEPT).header("Vary")
  assert_equal "Accept", client.get("/articles", { "accept" => "text/html" }).header("Vary")
  # also on the 406
  assert_equal "Accept", client.get("/articles", JSON_ACCEPT).header("Vary")
  # an extension decides the format; no Accept, nothing to vary on
  assert_nil client.get("/articles/1.json", JSON_ACCEPT).header("Vary")
  assert_nil client.get("/articles/1").header("Vary")
  # added to the action's own Vary, once
  assert_equal "Accept-Encoding, Accept", client.get("/varied", JSON_ACCEPT).header("Vary")
  assert_equal "Accept-Encoding", client.get("/varied").header("Vary")
end

test "FormatCollector: the first matching arm, with or without a block" do
  c = Cybertrain::FormatCollector.new(:json)
  assert_equal :none, c.matched_format
  refute c.matched_without_block?
  c.html
  assert_equal :none, c.matched_format
  c.json
  assert_equal :json, c.matched_format
  assert c.matched_without_block?
  c.any { raise "never runs" }
  assert_equal :json, c.matched_format
  ran = []
  d = Cybertrain::FormatCollector.new(:csv)
  d.csv { ran << "csv" }
  d.text { ran << "text" }
  assert_equal :csv, d.matched_format
  refute d.matched_without_block?
  assert_equal ["csv"], ran
end

Cybertrain::Test.run!
