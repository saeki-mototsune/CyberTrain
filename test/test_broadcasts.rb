# Broadcast assertions and assert_turbo_stream (spec section 9.3,
# acceptance 6): assert_broadcasts with a record and a name, with and
# without a block (since the test began: the floor the reset hook reads),
# answering the payloads; assert_no_broadcasts; their failure text; the
# floor hook with no database and with no messages table (nothing read,
# nothing created); assert_turbo_stream over a Turbo Stream response (an
# IntegrationTest request with `Accept: text/vnd.turbo-stream.html`) and
# over HTML set as the last render, with a record target, `count:`, the
# template's content left unread, and the failure text. The instance
# forms (an IntegrationTest's methods) reach the same checks as the
# top-level ones. Application#boot links SQLite through FFI, so this
# runs compiled only (NOTES rule 23).
require "cybertrain"
require "cybertrain/test_help"
require "cybertrain/test/bundle"

DB = Cybertrain::DB
Stream = Cybertrain::Stream
Turbo = Cybertrain::Turbo

class Article < Cybertrain::Model
  def self.table_name = "articles"
  def model_name = "Article"
end

# A record with an id, as Stream.name_for and dom_id read it.
def saved_article(id)
  article = Article.new
  article.set_id(id)
  article
end

# POST /articles/:article_id/comments broadcasts the comment to the
# article's stream and answers a Turbo Stream, or text for HTML (the
# blog's CommentsController#create in small).
class CommentsController < Cybertrain::Controller
  def create
    article = saved_article(params[:article_id].to_i)
    body = params[:body].to_s
    Cybertrain::Stream.broadcast_append_to(article, target: "comments", html: body)
    respond_to do |format|
      format.turbo_stream { render turbo_stream: turbo_stream.append("comments", html: body) }
      format.html { render plain: "Comment saved" }
    end
  end
end

def build_router
  router = Cybertrain::Router.new
  router.add("POST", "/articles/:article_id/comments", "article_comments") do |ctx|
    CommentsController.new(ctx).process(:create) { |c| c.create }
  end
  router
end

def resolver
  ->(name, args, options) { "/" }
end

TURBO = { "Accept" => "text/vnd.turbo-stream.html" }.freeze

# Class-form tests as gen's rewrite writes them (each method ends in nil):
# the instance forms.
class CommentsTest < ActionDispatch::IntegrationTest
  def test_turbo_stream_response
    begin
      payloads = assert_broadcasts(saved_article(3), 1) do
        post "/articles/3/comments", params: { body: "Hi" }, headers: TURBO
      end
      assert_response :success
      assert_includes payloads[0], 'target="comments"'
      assert_includes response.header("Content-Type"), "text/vnd.turbo-stream.html"
      assert_turbo_stream action: "append", target: "comments"
      message = assert_raises("AssertionFailed") { assert_turbo_stream action: "remove", target: "comments" }
      assert_equal "Expected a <turbo-stream action=\"remove\" target=\"comments\">, found: append comments", message
      assert_broadcasts("articles:3", 1)
      assert_no_broadcasts("articles:4")
      assert_no_broadcasts("articles:4") { post "/articles/3/comments", params: { body: "Again" } }
    end
    nil
  end

  def test_html_response
    begin
      post "/articles/3/comments", params: { body: "Hi" }
      assert_response :success
      assert_equal "Comment saved", response.body
      message = assert_raises("AssertionFailed") { assert_turbo_stream action: "append", target: "comments" }
      assert_equal "Expected a <turbo-stream action=\"append\" target=\"comments\">, found: none", message
    end
    nil
  end
end

# ---- the boot, as gen/tests.rb does it ----

def make_dir(dir)
  Dir.mkdir(dir) unless File.directory?(dir)
  nil
end

DATABASE = "tmp/test_broadcasts/test.sqlite3"
make_dir("tmp")
make_dir("tmp/test_broadcasts")
ENV["CYBERTRAIN_TEST_DATABASE"] = DATABASE

def broadcasts_config
  c = Cybertrain::Config.new
  c.env = "test"
  c.database_path = DATABASE
  c.secret_key_base = "test-broadcasts-secret"
  c.views_root = "tmp/test_broadcasts/views"
  c.public_root = "tmp/test_broadcasts/public"
  Cybertrain.config = c
  c
end

CONFIG = broadcasts_config
APP = Cybertrain::Test::Bundle.boot(build_router, resolver)
at_exit do
  [DATABASE, "#{DATABASE}-wal", "#{DATABASE}-shm"].each { |f| File.delete(f) if File.exist?(f) }
end

def messages_table_count
  rows = DB.with { |c| c.execute("SELECT COUNT(*) AS n FROM sqlite_master WHERE type = 'table' AND name = 'cybertrain_messages'") }
  Cybertrain::Cast.int(rows[0]["n"])
end

test "assert_broadcasts with a record and a name answers the payloads" do
  article = saved_article(1)
  payloads = assert_broadcasts(article, 1) do
    Cybertrain::Stream.broadcast_append_to(article, target: "comments", html: "<p>Hi</p>")
  end
  assert_equal 1, payloads.length
  assert_includes payloads[0], 'target="comments"'
  assert_equal "<turbo-stream action=\"append\" target=\"comments\"><template>&lt;p&gt;Hi&lt;/p&gt;</template></turbo-stream>", payloads[0]
  payloads = assert_broadcasts("articles", 2) do
    Stream.broadcast_append_to("articles", target: "articles", html: Cybertrain::Html.safe("<li>one</li>"))
    Stream.broadcast("elsewhere", "not counted")
    Stream.broadcast_remove_to("articles", target: article)
  end
  assert_equal ["<turbo-stream action=\"append\" target=\"articles\"><template><li>one</li></template></turbo-stream>",
                "<turbo-stream action=\"remove\" target=\"article_1\"></turbo-stream>"], payloads
  # A record's stream is its name_for: "articles:1".
  payloads = assert_broadcasts("articles:1", 1) { Stream.broadcast_refresh_to(article) }
  assert_equal "<turbo-stream action=\"refresh\"></turbo-stream>", payloads[0]
  # A plain payload is answered as it was written.
  assert_equal ["{\"n\":1}"], assert_broadcasts("json", 1) { Stream.broadcast("json", "{\"n\":1}") }
end

test "without a block it counts since the test began" do
  # The previous test's rows are still in the table, below the floor.
  assert Cybertrain::Test.case_message_floor > 0
  assert_equal Array.new(0) { "" }, assert_broadcasts("articles", 0)
  assert_no_broadcasts(saved_article(1))
  Stream.broadcast_append_to("articles", target: "articles", html: "a")
  Stream.broadcast("other", "x")
  Stream.broadcast_append_to("articles", target: "articles", html: "b")
  payloads = assert_broadcasts("articles", 2)
  assert_includes payloads[0], "<template>a</template>"
  assert_includes payloads[1], "<template>b</template>"
  # A block counts only its own; the count since the test began includes it.
  assert_broadcasts("articles", 1) { Stream.broadcast_append_to("articles", target: "articles", html: "c") }
  assert_equal 3, assert_broadcasts("articles", 3).length
  # Nested blocks: each counts what ran inside it.
  outer = assert_broadcasts("articles", 2) do
    Stream.broadcast("articles", "d")
    assert_broadcasts("articles", 1) { Stream.broadcast("articles", "e") }
  end
  assert_equal %w[d e], outer
end

test "assert_broadcasts fails with the counts" do
  message = assert_raises("AssertionFailed") do
    assert_broadcasts("articles", 2) { Stream.broadcast_append_to("articles", target: "articles", html: "x") }
  end
  assert_equal "Expected 2 broadcasts on \"articles\", got 1", message
  message = assert_raises("AssertionFailed") { assert_broadcasts(saved_article(7), 1) { nil } }
  assert_equal "Expected 1 broadcast on \"articles:7\", got 0", message
  message = assert_raises("AssertionFailed") { assert_broadcasts("articles", 3) }
  assert_equal "Expected 3 broadcasts on \"articles\", got 1", message
  message = assert_raises(ArgumentError) { assert_broadcasts(Article.new, 1) { nil } }
  assert_equal "Stream.name_for: the record is not saved (it has no id)", message
end

test "assert_no_broadcasts passes when nothing was broadcast to the stream and fails naming the count" do
  article = saved_article(2)
  assert_nil(assert_no_broadcasts("articles") { Stream.broadcast("other", "x") })
  assert_nil assert_no_broadcasts(article)
  message = assert_raises("AssertionFailed") do
    assert_no_broadcasts(article) { Stream.broadcast_refresh_to(article) }
  end
  assert_equal "Expected 0 broadcasts on \"articles:2\", got 1", message
  Stream.broadcast("articles", "y")
  Stream.broadcast("articles", "z")
  message = assert_raises("AssertionFailed") { assert_no_broadcasts("articles") }
  assert_equal "Expected 0 broadcasts on \"articles\", got 2", message
end

test "the floor hook and the reads touch no database that has no messages table" do
  DB.connect(":memory:")
  Cybertrain::Test::Broadcasts.floor_reset.call
  assert_equal 0, Cybertrain::Test.case_message_floor
  assert_equal 0, messages_table_count
  assert_no_broadcasts("articles")
  assert_equal 0, messages_table_count
  DB.disconnect
  Cybertrain::Test::Broadcasts.floor_reset.call
  assert_equal 0, Cybertrain::Test.case_message_floor
  assert_no_broadcasts("articles")
  DB.connect(DATABASE)
  Cybertrain::Test::Broadcasts.floor_reset.call
  assert Cybertrain::Test.case_message_floor > 0
  assert_equal 1, messages_table_count
end

test "assert_turbo_stream finds the action and target" do
  CommentsTest.new.test_turbo_stream_response
end

test "assert_turbo_stream reads the last response, so an HTML answer has none" do
  CommentsTest.new.test_html_response
end

test "assert_turbo_stream reads the last render and names every stream it found" do
  html = +""
  html << Turbo.append("comments", Cybertrain::Html.safe("<p>a</p>")).to_s
  html << Turbo.update("comment_form", "f").to_s
  html << Turbo.refresh.to_s
  Cybertrain::Test.last_html = html
  assert_nil assert_turbo_stream(action: "update", target: "comment_form")
  assert_turbo_stream action: "append", target: "comments"
  message = assert_raises("AssertionFailed") { assert_turbo_stream action: "append", target: "comment_form" }
  assert_equal "Expected a <turbo-stream action=\"append\" target=\"comment_form\">, found: append comments, update comment_form, refresh", message
end

test "assert_turbo_stream never reads the previous test's response or render" do
  # The previous test's last render held an append on comments.
  message = assert_raises("AssertionFailed") { assert_turbo_stream action: "append", target: "comments" }
  assert_equal "Expected a <turbo-stream action=\"append\" target=\"comments\">, " \
               "found: none (no response or render yet in this test, or an empty body)", message
  assert_equal "", Cybertrain::Test.last_html
end

test "assert_turbo_stream takes a record as the target and count:" do
  article = saved_article(5)
  Cybertrain::Test.last_html = "#{Turbo.replace(article, "x")}#{Turbo.replace(article, "y")}"
  assert_turbo_stream action: "replace", target: article, count: 2
  assert_turbo_stream action: "replace", target: "article_5", count: 2
  assert_turbo_stream action: "remove", target: article, count: 0
  message = assert_raises("AssertionFailed") { assert_turbo_stream action: "replace", target: article }
  assert_equal "Expected exactly 1 <turbo-stream action=\"replace\" target=\"article_5\">, found 2 in: replace article_5, replace article_5", message
  message = assert_raises("AssertionFailed") { assert_turbo_stream action: "replace", target: article, count: 0 }
  assert_equal "Expected no <turbo-stream action=\"replace\" target=\"article_5\">, found 2 in: replace article_5, replace article_5", message
  message = assert_raises(ArgumentError) { assert_turbo_stream action: "replace", target: article, count: -1 }
  assert_equal "assert_turbo_stream: count: must be 0 or more (got -1)", message
end

test "assert_turbo_stream does not read a template's content, only the elements around it" do
  # Raw HTML inside the template that is not balanced (Turbo inserts it as
  # a fragment): not read.
  Cybertrain::Test.last_html = "<turbo-stream action=\"append\" target=\"list\"><template><li>open<b></template></turbo-stream>"
  assert_turbo_stream action: "append", target: "list"
  # A turbo-stream inside a (nested) template is content, not a stream.
  Cybertrain::Test.last_html = "<turbo-stream action=\"update\" target=\"a\"><template>" \
                               "<turbo-stream action=\"remove\" target=\"b\"></turbo-stream><TEMPLATE id=\"t\"><p></Template>" \
                               "</template></turbo-stream>"
  message = assert_raises("AssertionFailed") { assert_turbo_stream action: "remove", target: "b" }
  assert_equal "Expected a <turbo-stream action=\"remove\" target=\"b\">, found: update a", message
  # "<template>" in a script or a comment is not a template.
  Cybertrain::Test.last_html = "<div><script>let t = \"<template>\";</script><!-- <template> -->" \
                               "<turbo-stream action=\"remove\" target=\"c\"></turbo-stream></div>"
  assert_turbo_stream action: "remove", target: "c"
  # HTML outside a template is read as assert_select reads it: a missing
  # end tag fails with its offset in the HTML as written.
  html = "<turbo-stream action=\"append\" target=\"x\"><template><li></template>"
  Cybertrain::Test.last_html = html
  message = assert_raises("AssertionFailed") { assert_turbo_stream action: "append", target: "x" }
  assert_equal "assert_turbo_stream: the HTML could not be read: missing end tag </turbo-stream> for <turbo-stream> opened at byte 0\n" \
               "HTML (first 500 characters):\n#{html}", message
  html = "<template><p></template><p></div>"
  Cybertrain::Test.last_html = html
  message = assert_raises("AssertionFailed") { assert_turbo_stream action: "append", target: "x" }
  assert_equal "assert_turbo_stream: the HTML could not be read: mismatched end tag </div> at byte 27 (open: <p>)\n" \
               "HTML (first 500 characters):\n#{html}", message
  # An unterminated template is left as it is, and read.
  html = "<template><p>"
  Cybertrain::Test.last_html = html
  message = assert_raises("AssertionFailed") { assert_turbo_stream action: "append", target: "x" }
  assert_includes message, "missing end tag </p> for <p> opened at byte 10"
end

Cybertrain::Test.run!
