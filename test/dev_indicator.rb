# Cybertrain::Dev::Indicator, the development middleware `cybertrain
# server` puts in front of its child: the X-Cybertrain-Runtime header on
# every response, the corner indicator on HTML pages, its text
# (Indicator.text), and the two reserved development paths it answers
# itself, the state as JSON and the script. Runs under CRuby too: no FFI.
require "stringio"
require "cybertrain/logger"
require "cybertrain/middleware"
require "cybertrain/dev/state_file"
require "cybertrain/dev/build_status"
require "cybertrain/dev/error_page"
require "cybertrain/dev/indicator"
require "cybertrain/test"

# Keep the error log out of the snapshot.
Cybertrain.logger = Cybertrain::Logger.new(StringIO.new)

ROOT = "tmp/dev_indicator_test"
Dir.mkdir("tmp") unless Dir.exist?("tmp")
Dir.mkdir(ROOT) unless Dir.exist?(ROOT)
at_exit do
  Dir.children(ROOT).each { |child| File.delete("#{ROOT}/#{child}") }
  Dir.rmdir(ROOT)
end

# The inner application; counts the requests that reach it.
class IndicatorPage < Cybertrain::Middleware
  attr_reader :calls, :seen_none_match, :seen_modified_since

  def initialize
    super(nil)
    @calls = 0
    @seen_none_match = ""
    @seen_modified_since = ""
  end

  def call(ctx)
    @calls += 1
    response = ctx.response
    case ctx.request.path
    when "/json"
      response.content_type = "application/json"
      response.body = "{\"ok\":true}"
    when "/no_content"
      response.status = 204
    when "/redirect"
      response.redirect("/elsewhere")
      response.body = "<html><body>moved</body></html>"
    when "/empty"
      response.status = 200
    when "/not_modified"
      # What fresh_when / stale? answer (head :not_modified): the browser
      # shows the body it cached, rendered by whichever child served it.
      response.status = 304
    when "/etag"
      # What fresh_when answers: the ETag the test names (W/"abc" when it
      # names none; "none" sets no ETag), and a 304 when the If-None-Match
      # the application sees lists it. Records the validators it was sent.
      request = ctx.request
      listed = request.header("If-None-Match")
      @seen_none_match = listed.nil? ? "(none)" : listed.to_s
      since = request.header("If-Modified-Since")
      @seen_modified_since = since.nil? ? "(none)" : since.to_s
      tag = request.query_value("tag")
      tag = "W/\"abc\"" if tag.empty?
      response.set_header("ETag", tag) unless tag == "none"
      if @seen_none_match.split(", ").include?(tag)
        response.status = 304
      else
        response.body = "<!DOCTYPE html>\n<html><body><h1>Cached</h1></body></html>"
      end
    when "/fragment"
      response.body = "<p>no body tag</p>"
    when "/download"
      # An HTML file served for saving, its header names spelled as an
      # application might; inline is still shown in the browser.
      response.content_type = "text/html; charset=utf-8"
      response.set_header("content-disposition", ctx.request.query_value("disposition"))
      response.body = "<!DOCTYPE html>\n<html><body><h1>Export</h1></body></html>"
    when "/encoded"
      # A body the application says it has encoded, the header's name and
      # value spelled as the test asks (the body itself is left plain, so
      # the test can see whether anything was written into it).
      response.content_type = "text/html; charset=utf-8"
      response.set_header(ctx.request.query_value("name"), ctx.request.query_value("value"))
      response.body = "<!DOCTYPE html>\n<html><body><h1>Encoded</h1></body></html>"
    when "/bytes"
      # A page sent as bytes (send_data of a file read in binary, a blob
      # column): a binary String with a byte past 0x7F (é in Latin-1).
      response.content_type = "text/html"
      response.body = "<html><body>caf\xE9</body></html>".b
    else
      response.body = "<!DOCTYPE html>\n<html><body class=\"app\"><h1>Posts</h1></body></html>"
    end
    nil
  end
end

def state_reader(name, generation, serving, build, output)
  path = "#{ROOT}/#{name}"
  File.write(path, Cybertrain::Dev::StateFile.format(generation, serving, build, output))
  Cybertrain::Dev::StateFile::Reader.new(path)
end

def snapshot(generation, build)
  Cybertrain::Dev::StateFile.parse(Cybertrain::Dev::StateFile.format(generation, "cruby", build, ""))
end

def no_directives
  Array.new(0) { "" }
end

def indicator(inner, reader, runtime, generation, directives)
  Cybertrain::Dev::Indicator.new(inner, reader, Cybertrain::Dev::BuildStatus.new(reader), runtime, generation, directives)
end

def run_request(app, target)
  ctx = Cybertrain::Context.new(Cybertrain::Request.new("GET", target, {}, "", "127.0.0.1"))
  app.call(ctx)
  ctx
end

def run_conditional(app, target, headers)
  ctx = Cybertrain::Context.new(Cybertrain::Request.new("GET", target, headers, "", "127.0.0.1"))
  app.call(ctx)
  ctx
end

def count_of(text, needle)
  n = 0
  at = text.index(needle)
  until at.nil?
    n += 1
    at = text.index(needle, at + needle.size)
  end
  n
end

INDICATOR_DIV = "<div id=\"cybertrain-dev-indicator\""

test "the text: a newer generation wins, then a Spinel page, then the build" do
  assert_equal "Source changed — reload", Cybertrain::Dev::Indicator.text("spinel", 3, snapshot(4, "ready"))
  assert_equal "Source changed — reload", Cybertrain::Dev::Indicator.text("cruby", 3, snapshot(4, "failed"))
  assert_equal "Spinel", Cybertrain::Dev::Indicator.text("spinel", 3, snapshot(3, "building"))
  assert_equal "CRuby preview · Spinel building…", Cybertrain::Dev::Indicator.text("cruby", 3, snapshot(3, "building"))
  assert_equal "Spinel ready — reload", Cybertrain::Dev::Indicator.text("cruby", 3, snapshot(3, "ready"))
  assert_equal "CRuby preview · Spinel build failed", Cybertrain::Dev::Indicator.text("cruby", 3, snapshot(3, "failed"))
  assert_equal "CRuby preview · Spinel binary failed", Cybertrain::Dev::Indicator.text("cruby", 3, snapshot(3, "binary_failed"))
  assert_equal "CRuby preview", Cybertrain::Dev::Indicator.text("cruby", 3, snapshot(3, "idle"))
  assert_equal "CRuby preview", Cybertrain::Dev::Indicator.text("cruby", 3, snapshot(2, "idle"))
end

test "an HTML page gets the header and one indicator before </body>, also through two passes" do
  reader = state_reader("html", 12, "cruby", "building", "")
  page = IndicatorPage.new
  app = indicator(indicator(page, reader, "cruby", 12, no_directives), reader, "cruby", 12, no_directives)
  response = run_request(app, "/").response
  assert_equal "cruby", response.header("X-Cybertrain-Runtime")
  expected = "<h1>Posts</h1><div id=\"cybertrain-dev-indicator\" data-runtime=\"cruby\" data-generation=\"12\">" \
             "CRuby preview &#183; Spinel building&#8230;</div><script src=\"/__cybertrain/dev/indicator.js\"></script></body></html>"
  assert_includes response.body, expected
  assert_equal 1, count_of(response.body, INDICATOR_DIV)
  assert_equal 1, count_of(response.body, "indicator.js")
end

test "a Spinel page says so in its header and its indicator" do
  reader = state_reader("spinel", 5, "spinel", "ready", "")
  response = run_request(indicator(IndicatorPage.new, reader, "spinel", 5, no_directives), "/").response
  assert_equal "spinel", response.header("X-Cybertrain-Runtime")
  assert_includes response.body, "data-runtime=\"spinel\" data-generation=\"5\">Spinel</div>"
end

test "JSON, a 204, a redirect and an empty body get the header and no indicator" do
  reader = state_reader("plain", 1, "cruby", "idle", "")
  app = indicator(IndicatorPage.new, reader, "cruby", 1, no_directives)
  ["/json", "/no_content", "/redirect", "/empty"].each do |path|
    response = run_request(app, path).response
    assert_equal "cruby", response.header("X-Cybertrain-Runtime")
    assert response.body.index("cybertrain-dev-indicator").nil?, "no indicator on #{path}"
  end
  assert_equal "{\"ok\":true}", run_request(app, "/json").response.body
end

test "a body without </body> gets the indicator at its end" do
  reader = state_reader("fragment", 1, "cruby", "idle", "")
  body = run_request(indicator(IndicatorPage.new, reader, "cruby", 1, no_directives), "/fragment").response.body
  assert_equal "<p>no body tag</p><div id=\"cybertrain-dev-indicator\" data-runtime=\"cruby\" data-generation=\"1\">" \
               "CRuby preview</div><script src=\"/__cybertrain/dev/indicator.js\"></script>", body
end

test "with nonce directives the script tag carries the request's nonce, without them none" do
  reader = state_reader("nonce", 1, "cruby", "idle", "")
  directives = no_directives
  directives << "script-src"
  ctx = run_request(indicator(IndicatorPage.new, reader, "cruby", 1, directives), "/")
  assert !ctx.csp_nonce.empty?
  assert_includes ctx.response.body, "<script src=\"/__cybertrain/dev/indicator.js\" nonce=\"#{ctx.csp_nonce}\"></script>"
  plain = run_request(indicator(IndicatorPage.new, reader, "cruby", 1, no_directives), "/").response.body
  assert plain.index("nonce=").nil?, "no nonce without nonce directives"
end

test "the state path answers the JSON for the asking page without calling the app" do
  reader = state_reader("state", 12, "spinel", "ready", "")
  page = IndicatorPage.new
  app = indicator(page, reader, "spinel", 12, no_directives)
  response = run_request(app, "/__cybertrain/dev/state?runtime=cruby&generation=12").response
  assert_equal 0, page.calls
  assert_equal 200, response.status
  assert_equal "{\"generation\":12,\"serving\":\"spinel\",\"build\":\"ready\",\"text\":\"Spinel ready — reload\"}", response.body
  assert_equal "no-store", response.header("Cache-Control")
  assert response.header("Content-Type").start_with?("application/json")
  assert_equal "spinel", response.header("X-Cybertrain-Runtime")
  older = run_request(app, "/__cybertrain/dev/state?runtime=cruby&generation=3").response.body
  assert_includes older, "\"text\":\"Source changed — reload\""
  spinel = run_request(app, "/__cybertrain/dev/state?runtime=spinel&generation=12").response.body
  assert_includes spinel, "\"text\":\"Spinel\""
  assert_equal 0, page.calls
end

test "the JSON escapes quotes and backslashes in the text" do
  assert_equal "a\\\"b\\\\c", Cybertrain::Dev::Indicator.json_escape("a\"b\\c")
  assert_equal "Spinel", Cybertrain::Dev::Indicator.json_escape("Spinel")
end

test "a garbled generation reads as 0 and an unknown runtime as cruby" do
  reader = state_reader("garbled", 0, "cruby", "building", "")
  app = indicator(IndicatorPage.new, reader, "cruby", 0, no_directives)
  ["/__cybertrain/dev/state?runtime=cruby&generation=x7", "/__cybertrain/dev/state?runtime=cruby",
   "/__cybertrain/dev/state?runtime=cruby&generation=99999999999999999999999",
   "/__cybertrain/dev/state?runtime=perl&generation=0", "/__cybertrain/dev/state?runtime=%zz&generation=%zz",
   "/__cybertrain/dev/state"].each do |target|
    body = run_request(app, target).response.body
    assert_equal "{\"generation\":0,\"serving\":\"cruby\",\"build\":\"building\",\"text\":\"CRuby preview · Spinel building…\"}", body
  end
  newer = state_reader("garbled_newer", 1, "cruby", "building", "")
  body = run_request(indicator(IndicatorPage.new, newer, "cruby", 0, no_directives), "/__cybertrain/dev/state?generation=junk").response.body
  assert_includes body, "\"text\":\"Source changed — reload\""
end

test "the state path without runtime and generation answers for a page of the state file's serving and generation" do
  ready = state_reader("current_ready", 5, "spinel", "ready", "")
  body = run_request(indicator(IndicatorPage.new, ready, "cruby", 4, no_directives), "/__cybertrain/dev/state").response.body
  assert_equal "{\"generation\":5,\"serving\":\"spinel\",\"build\":\"ready\",\"text\":\"Spinel\"}", body
  building = state_reader("current_building", 6, "cruby", "building", "")
  app = indicator(IndicatorPage.new, building, "cruby", 2, no_directives)
  assert_equal "{\"generation\":6,\"serving\":\"cruby\",\"build\":\"building\",\"text\":\"CRuby preview · Spinel building…\"}",
               run_request(app, "/__cybertrain/dev/state").response.body
  # Empty values count as not given.
  assert_includes run_request(app, "/__cybertrain/dev/state?runtime=&generation=").response.body,
                  "\"text\":\"CRuby preview · Spinel building…\""
  failed = state_reader("current_failed", 7, "cruby", "failed", "boom\n")
  assert_includes run_request(indicator(IndicatorPage.new, failed, "cruby", 7, no_directives), "/__cybertrain/dev/state").response.body,
                  "\"text\":\"CRuby preview · Spinel build failed\""
end

test "the state path while the supervisor holds answers for a page of the child's own runtime" do
  holding = state_reader("current_holding", 3, "holding", "building", "")
  cruby = run_request(indicator(IndicatorPage.new, holding, "cruby", 3, no_directives), "/__cybertrain/dev/state").response.body
  assert_includes cruby, "\"serving\":\"holding\""
  assert_includes cruby, "\"text\":\"CRuby preview · Spinel building…\""
  spinel = run_request(indicator(IndicatorPage.new, holding, "spinel", 3, no_directives), "/__cybertrain/dev/state").response.body
  assert_includes spinel, "\"text\":\"Spinel\""
end

# serving none is written only while no child runs, so the one reader is a
# child that has just started and reads the file before the supervisor
# rewrites it: the file's generation is older than the child's, and its
# build (ready: a binary that will not be started, a change being
# pending) is not one this page waits on. The page claims only what is
# true of it: the runtime that rendered it.
test "while the state file says serving none the page shows its own runtime and nothing more" do
  none_ready = Cybertrain::Dev::StateFile.parse(Cybertrain::Dev::StateFile.format(4, "none", "ready", ""))
  assert_equal "none", none_ready.serving
  assert_equal "CRuby preview", Cybertrain::Dev::Indicator.text("cruby", 5, none_ready)
  assert_equal "CRuby preview", Cybertrain::Dev::Indicator.text("cruby", 4, none_ready)
  assert_equal "Spinel", Cybertrain::Dev::Indicator.text("spinel", 5, none_ready)
  first = Cybertrain::Dev::StateFile.parse(Cybertrain::Dev::StateFile.format(0, "none", "idle", ""))
  assert_equal "CRuby preview", Cybertrain::Dev::Indicator.text("cruby", 1, first)

  reader = state_reader("none_ready", 4, "none", "ready", "")
  app = indicator(IndicatorPage.new, reader, "cruby", 5, no_directives)
  page = run_request(app, "/").response.body
  assert_includes page, "data-runtime=\"cruby\" data-generation=\"5\">CRuby preview</div>"
  assert page.index("cybertrain-build-failed").nil?, "no build failure banner"
  # The JSON gives the file's facts; the text is for a page of this child.
  assert_equal "{\"generation\":4,\"serving\":\"none\",\"build\":\"ready\",\"text\":\"CRuby preview\"}",
               run_request(app, "/__cybertrain/dev/state").response.body
  assert_includes run_request(app, "/__cybertrain/dev/state?runtime=cruby&generation=5").response.body,
                  "\"text\":\"CRuby preview\""
  spinel = run_request(indicator(IndicatorPage.new, reader, "spinel", 5, no_directives), "/__cybertrain/dev/state").response.body
  assert_includes spinel, "\"text\":\"Spinel\""
end

test "the state path with one of runtime and generation reads the other as before" do
  reader = state_reader("one_parameter", 5, "spinel", "ready", "")
  app = indicator(IndicatorPage.new, reader, "spinel", 5, no_directives)
  assert_includes run_request(app, "/__cybertrain/dev/state?runtime=cruby").response.body, "\"text\":\"Source changed — reload\""
  assert_includes run_request(app, "/__cybertrain/dev/state?runtime=spinel").response.body, "\"text\":\"Source changed — reload\""
  assert_includes run_request(app, "/__cybertrain/dev/state?generation=5").response.body, "\"text\":\"Spinel ready — reload\""
end

test "a 304 passes through with the header and no indicator" do
  reader = state_reader("not_modified", 2, "cruby", "idle", "")
  page = IndicatorPage.new
  response = run_request(indicator(page, reader, "cruby", 2, no_directives), "/not_modified").response
  assert_equal 1, page.calls
  assert_equal 304, response.status
  assert_equal "cruby", response.header("X-Cybertrain-Runtime")
  assert_equal "", response.body
end

# A download is the file as the application wrote it: the indicator would
# change what the developer saves. The header's name and its disposition
# type are case-insensitive (RFC 6266); inline is a page like any other.
test "a response served as an attachment gets the header and no indicator" do
  reader = state_reader("download", 3, "cruby", "idle", "")
  app = indicator(IndicatorPage.new, reader, "cruby", 3, no_directives)
  ["attachment", "attachment;%20filename%3D%22export.html%22", "ATTACHMENT;filename=x.html", "%20Attachment"].each do |disposition|
    response = run_request(app, "/download?disposition=#{disposition}").response
    assert_equal "cruby", response.header("X-Cybertrain-Runtime")
    assert_equal "<!DOCTYPE html>\n<html><body><h1>Export</h1></body></html>", response.body
  end
  inline = run_request(app, "/download?disposition=inline").response.body
  assert_equal 1, count_of(inline, INDICATOR_DIV)
end

# A body the application compressed is bytes the indicator's markup would
# corrupt: it is left alone whatever the coding, the header's name and
# value matched case-insensitively. identity is no coding at all.
test "a response the application encoded gets the header and no indicator; identity is no encoding" do
  reader = state_reader("encoded", 3, "cruby", "idle", "")
  app = indicator(IndicatorPage.new, reader, "cruby", 3, no_directives)
  plain = "<!DOCTYPE html>\n<html><body><h1>Encoded</h1></body></html>"
  ["name=Content-Encoding&value=gzip", "name=content-encoding&value=br", "name=CONTENT-ENCODING&value=GZip",
   "name=Content-Encoding&value=%20gzip%20", "name=Content-Encoding&value=gzip,%20identity"].each do |query|
    response = run_request(app, "/encoded?#{query}").response
    assert_equal "cruby", response.header("X-Cybertrain-Runtime")
    assert_equal plain, response.body
  end
  ["name=Content-Encoding&value=identity", "name=content-encoding&value=IDENTITY",
   "name=Content-Encoding&value=%20Identity%20", "name=X-Other&value=gzip"].each do |query|
    response = run_request(app, "/encoded?#{query}").response
    assert_equal "cruby", response.header("X-Cybertrain-Runtime")
    assert_equal 1, count_of(response.body, INDICATOR_DIV)
  end
end

test "the script path answers the script" do
  reader = state_reader("script", 0, "cruby", "idle", "")
  page = IndicatorPage.new
  response = run_request(indicator(page, reader, "cruby", 0, no_directives), "/__cybertrain/dev/indicator.js").response
  assert_equal 0, page.calls
  assert_equal 200, response.status
  assert response.header("Content-Type").start_with?("text/javascript")
  assert_equal "cruby", response.header("X-Cybertrain-Runtime")
  assert_includes response.body, "/__cybertrain/dev/state?runtime="
  assert_includes response.body, "textContent"
  assert response.body.index("setAttribute(\"style\"").nil?, "styled through the CSSOM"
end

# The div's data- attributes are the page's runtime and generation: the
# script never takes the current server's state as the page's own (a page
# rendered by CRuby whose load spans the handover to Spinel would claim
# Spinel, and a newer generation would hide "Source changed — reload").
test "the script asks for the text with the page's own runtime and generation and never adopts the server's" do
  script = Cybertrain::Dev::Indicator::SCRIPT
  assert_includes script, "el.getAttribute(\"data-runtime\")"
  assert_includes script, "el.getAttribute(\"data-generation\")"
  assert_includes script, "\"/__cybertrain/dev/state?runtime=\" + encodeURIComponent("
  assert script.index("state.generation").nil?, "the answer's generation is not the page's"
  assert script.index("state.serving").nil?, "the answer's serving runtime is not the page's"
  assert script.index("\"/__cybertrain/dev/state\"").nil?, "the state path is never asked without the page's values"
  assert_equal 1, count_of(script, "fetch(")
end

test "the application's ETag leaves with this child's runtime and generation" do
  reader = state_reader("etag_out", 12, "cruby", "idle", "")
  app = indicator(IndicatorPage.new, reader, "cruby", 12, no_directives)
  assert_equal "W/\"abc-dev-cruby-12\"", run_request(app, "/etag").response.header("ETag")
  assert_equal "\"strong-dev-cruby-12\"", run_request(app, "/etag?tag=%22strong%22").response.header("ETag")
  # Not an entity-tag: left as it is (no request lists it with the suffix).
  assert_equal "bare", run_request(app, "/etag?tag=bare").response.header("ETag")
  assert run_request(app, "/etag?tag=none").response.header("ETag").nil?, "no ETag is made up"
  assert run_request(app, "/json").response.header("ETag").nil?, "no ETag on a response without one"
  spinel = indicator(IndicatorPage.new, reader, "spinel", 5, no_directives)
  assert_equal "W/\"abc-dev-spinel-5\"", run_request(spinel, "/etag").response.header("ETag")
end

test "If-None-Match with this child's suffix reaches the application without it, and its 304 passes through" do
  reader = state_reader("etag_match", 12, "cruby", "idle", "")
  page = IndicatorPage.new
  app = indicator(page, reader, "cruby", 12, no_directives)
  ctx = run_conditional(app, "/etag", { "if-none-match" => "W/\"abc-dev-cruby-12\"" })
  assert_equal "W/\"abc\"", page.seen_none_match
  response = ctx.response
  assert_equal 304, response.status
  assert_equal "", response.body
  assert_equal "W/\"abc-dev-cruby-12\"", response.header("ETag")
  assert_equal "cruby", response.header("X-Cybertrain-Runtime")
  # A list, a header name in any case, a comma inside a tag.
  run_conditional(app, "/etag", { "If-None-Match" => "W/\"abc-dev-cruby-12\" ,\"x,y-dev-cruby-12\", ,W/\"z-dev-cruby-12\"" })
  assert_equal "W/\"abc\", \"x,y\", W/\"z\"", page.seen_none_match
  # The strong form of this child's weak tag still matches (weak comparison).
  run_conditional(app, "/etag", { "if-none-match" => "\"abc-dev-cruby-12\"" })
  assert_equal "\"abc\"", page.seen_none_match
end

test "If-None-Match with another generation's or runtime's tag, none, or * is dropped: the page is rendered again" do
  reader = state_reader("etag_other", 12, "cruby", "idle", "")
  page = IndicatorPage.new
  app = indicator(page, reader, "cruby", 12, no_directives)
  ["W/\"abc-dev-cruby-11\"", "W/\"abc-dev-spinel-12\"", "W/\"abc\"", "*", "W/\"abc-dev-cruby-12\", *",
   "W/\"abc-dev-cruby-12\", W/\"abc-dev-cruby-11\"", "W/\"abc-dev-cruby-120\"", "", " , ", "abc-dev-cruby-12",
   "W/\"abc-dev-cruby-12", "\"a\"b-dev-cruby-12\""].each do |listed|
    ctx = run_conditional(app, "/etag", { "if-none-match" => listed })
    assert_equal "(none)", page.seen_none_match
    assert_equal 200, ctx.response.status
    assert_equal "W/\"abc-dev-cruby-12\"", ctx.response.header("ETag")
    assert_equal 1, count_of(ctx.response.body, INDICATOR_DIV)
    assert_includes ctx.response.body, "data-runtime=\"cruby\" data-generation=\"12\""
  end
  # Spinel's child does not take CRuby's tag of the same generation.
  spinel_page = IndicatorPage.new
  spinel = indicator(spinel_page, reader, "spinel", 12, no_directives)
  ctx = run_conditional(spinel, "/etag", { "IF-NONE-MATCH" => "W/\"abc-dev-cruby-12\"" })
  assert_equal "(none)", spinel_page.seen_none_match
  assert_includes ctx.response.body, "data-runtime=\"spinel\" data-generation=\"12\""
end

test "If-Modified-Since never reaches the application under supervision" do
  reader = state_reader("modified_since", 3, "cruby", "idle", "")
  page = IndicatorPage.new
  app = indicator(page, reader, "cruby", 3, no_directives)
  date = "Sat, 01 Jan 2000 00:00:00 GMT"
  ["If-Modified-Since", "if-modified-since", "IF-MODIFIED-SINCE"].each do |name|
    ctx = run_conditional(app, "/etag", { name => date })
    assert_equal "(none)", page.seen_modified_since
    assert_equal 200, ctx.response.status
  end
  run_conditional(app, "/etag", { "if-modified-since" => date, "if-none-match" => "W/\"abc-dev-cruby-3\"" })
  assert_equal "(none)", page.seen_modified_since
  assert_equal "W/\"abc\"", page.seen_none_match
end

# The Indicator is only in the supervised stack (Roles::ServerRunner#front_app):
# without it the application sees its validators as sent and its ETag
# leaves as it set it.
test "without the Indicator the validators and the ETag are the application's own" do
  page = IndicatorPage.new
  date = "Sat, 01 Jan 2000 00:00:00 GMT"
  ctx = run_conditional(page, "/etag", { "if-none-match" => "W/\"abc\"", "if-modified-since" => date })
  assert_equal "W/\"abc\"", page.seen_none_match
  assert_equal date, page.seen_modified_since
  assert_equal 304, ctx.response.status
  assert_equal "W/\"abc\"", ctx.response.header("ETag")
end

test "with a failed build the banner follows <body> and the indicator precedes </body>" do
  reader = state_reader("failed", 4, "cruby", "failed", "app/models/post.rb:4: syntax error\n")
  status = Cybertrain::Dev::BuildStatus.new(reader)
  app = Cybertrain::Dev::Indicator.new(Cybertrain::Dev::ErrorPage.new(IndicatorPage.new, nil, status), reader, status,
                                       "cruby", 4, no_directives)
  body = run_request(app, "/").response.body
  assert_includes body, "<body class=\"app\"><div id=\"cybertrain-build-failed\""
  assert_includes body, "app/models/post.rb:4: syntax error"
  assert_includes body, "<h1>Posts</h1><div id=\"cybertrain-dev-indicator\" data-runtime=\"cruby\" data-generation=\"4\">" \
                        "CRuby preview &#183; Spinel build failed</div>"
  assert body.index("cybertrain-build-failed").to_i < body.index("cybertrain-dev-indicator").to_i
end

# The markup is ASCII (the texts' characters past ASCII as numeric
# references, which the browser shows as the same text), so that it joins a
# body in any encoding: under CRuby a binary body with a byte past 0x7F and
# UTF-8 markup raised Encoding::CompatibilityError, a bare 500 in the
# preview only.
test "a page sent as bytes gets the indicator, in ASCII markup, byte for byte" do
  reader = state_reader("bytes", 3, "cruby", "building", "")
  response = run_request(indicator(IndicatorPage.new, reader, "cruby", 3, no_directives), "/bytes").response
  expected = ("<html><body>caf\xE9<div id=\"cybertrain-dev-indicator\" data-runtime=\"cruby\" data-generation=\"3\">CRuby preview &#183; " \
              "Spinel building&#8230;</div><script src=\"/__cybertrain/dev/indicator.js\"></script></body></html>").b
  assert_equal expected, response.body.b
end

test "ascii_html writes the characters past ASCII as numeric references" do
  assert_equal "Spinel ready &#8212; reload", Cybertrain::Dev::Indicator.ascii_html("Spinel ready — reload")
  assert_equal "&#183;a&#8230;", Cybertrain::Dev::Indicator.ascii_html("·a…")
  assert_equal "caf&#233; &#128512;", Cybertrain::Dev::Indicator.ascii_html("café 😀")
  assert_equal "CRuby preview", Cybertrain::Dev::Indicator.ascii_html("CRuby preview")
  assert_equal "", Cybertrain::Dev::Indicator.ascii_html("")
end

test "the state follows the state file as it changes" do
  path = "#{ROOT}/moving"
  File.write(path, Cybertrain::Dev::StateFile.format(2, "cruby", "building", ""))
  reader = Cybertrain::Dev::StateFile::Reader.new(path)
  app = indicator(IndicatorPage.new, reader, "cruby", 2, no_directives)
  assert_includes run_request(app, "/__cybertrain/dev/state?runtime=cruby&generation=2").response.body, "\"build\":\"building\""
  File.write(path, Cybertrain::Dev::StateFile.format(2, "spinel", "ready", "") + "\n")
  body = run_request(app, "/__cybertrain/dev/state?runtime=cruby&generation=2").response.body
  assert_equal "{\"generation\":2,\"serving\":\"spinel\",\"build\":\"ready\",\"text\":\"Spinel ready — reload\"}", body
end

Cybertrain::Test.run!
