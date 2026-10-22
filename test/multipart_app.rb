# A multipart/form-data upload through the full Application stack
# (ErrorPages -> MethodOverride -> SessionStore -> CsrfProtection -> Router),
# CSRF and sessions on, the way a browser form with a file field reaches an
# action: the token and `_method` are read out of the multipart body before
# routing (Request#form_or_query_value), the Router fills the controller's
# params from the same parse (Multipart.fill), and every fault in the body is
# a 400 from the stack.
#
# Production env, so ErrorPages is in the stack and turns the Multipart*
# faults into the 400 a client gets. It links SQLite through FFI
# (Application#boot connects the database), so it cannot run under CRuby: the
# snapshot comes from the compiled binary (spikes/NOTES.md rule 23).
require "digest"
require "cybertrain"
require "cybertrain/application"
require "cybertrain/test"
require "cybertrain/test/client"

# ---- the application ---------------------------------------------------------

class PostsController < Cybertrain::Controller
  # The form page: only its layout matters, it carries the CSRF token.
  def index
  end

  def create
    render plain: "created #{describe_post(params.require(:post))}", status: :created
  end

  # nested, as the generated attachment code reads it: a form whose only
  # field is a file input left empty sends no post[...] key at all.
  def update
    render plain: "updated #{params[:id]} #{describe_post(params.nested(:post))}"
  end

  # Everything an action sees of a post: the text field and the file, as
  # bytes (size and digest), never as a String comparison on binary data.
  def describe_post(post)
    cover = post.upload(:cover)
    line = "title=#{post[:title]}"
    return "#{line} cover=none" if cover.nil?

    "#{line} cover=#{cover.original_filename} #{cover.byte_size} #{cover.sha256_hex} #{cover.detected_content_type}"
  end
end

router = Cybertrain::Router.new
router.get("/", "root") { |ctx| PostsController.new(ctx).process(:index) { |c| c.index } }
router.post("/posts", "posts") { |ctx| PostsController.new(ctx).process(:create) { |c| c.create } }
router.patch("/posts/:id", "post") { |ctx| PostsController.new(ctx).process(:update) { |c| c.update } }

def embedded_views
  views = {}
  views["layouts/application.html.erb"] = "<%= csrf_meta_tags %>\n<%= yield %>\n"
  views["posts/index.html.erb"] = "<p>form</p>\n"
  views
end

UPLOAD_ROOT = "tmp/multipart_app_test/uploads"

config = Cybertrain::Config.new
config.env = "production"
config.database_path = ":memory:"
config.pool_size = 1
config.secret_key_base = "multipart-secret"
config.log_level = :none
config.static_files = false
config.max_upload_bytes = 65_536
config.max_multipart_parts = 16
config.upload_root = UPLOAD_ROOT

APP = Cybertrain::Application.new(router: router, url_resolver: ->(n, a) { "/" }, views: embedded_views, config: config)
APP.boot

# The token csrf_meta_tags rendered into the last page.
def page_token(body)
  marker = "name=\"csrf-token\" content=\""
  start = body.index(marker)
  return "" if start.nil?

  from = start + marker.length
  body[from, body.index("\"", from).to_i - from].to_s
end

# A client that has a session and its token, the way a browser has loaded the
# form page.
def form_client
  client = Cybertrain::Test::Client.new(APP)
  token = page_token(client.get("/").body)
  [client, token]
end

# Every byte value, then CR LF and a dash run that look like a delimiter, a
# NUL and 0xFF at the end: a PNG signature first so the content sniffs as one.
def cover_bytes
  ints = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
  n = 0
  while n < 256
    ints << n
    n += 1
  end
  ints.concat([0x0D, 0x0A, 0x2D, 0x2D, 0x58, 0x0D, 0x0A, 0x00, 0xFF])
  Cybertrain::Test.binary(ints)
end

def cover_upload(data)
  field = "post[cover]"
  filename = "cover.png"
  type = "image/png"
  Cybertrain::Test::Upload.new(field, filename, type, data)
end

test "the boot validates and applies the upload settings" do
  assert_equal "", config.upload_limits_error
  assert_equal 65_536, Cybertrain::Multipart.max_upload_bytes
  assert_equal 16, Cybertrain::Multipart.max_parts
  assert_equal UPLOAD_ROOT, Cybertrain::BlobStore.root
  refute File.exist?(UPLOAD_ROOT), "the upload directory is made by the first write, not at boot"
  assert_equal ["Cybertrain::ErrorPages", "Cybertrain::MethodOverride", "Cybertrain::SessionStore",
                "Cybertrain::CsrfProtection", "Cybertrain::Router"], stack_names(APP)
end

def stack_names(app)
  names = []
  node = app.stack
  until node.nil?
    names << node.class.name
    node = node.app
  end
  names
end

test "a multipart POST with the token reaches the action with its text and file intact" do
  client, token = form_client
  assert_equal 64, token.length
  data = cover_bytes
  expected = Digest::SHA256.hexdigest(data)
  fields = { "authenticity_token" => token, "post[title]" => "Héllo" }
  res = client.post_multipart("/posts", fields, [cover_upload(data)])
  assert_response res, :created
  puts res.body
  assert_equal "created title=Héllo cover=cover.png #{data.bytesize} #{expected} image/png", res.body
  assert_equal 273, data.bytesize
end

test "a multipart PATCH through _method reaches the update route" do
  client, token = form_client
  data = cover_bytes
  expected = Digest::SHA256.hexdigest(data)
  res = client.patch_multipart("/posts/7", { "authenticity_token" => token, "post[title]" => "Edited" }, [cover_upload(data)])
  assert_response res, :ok
  puts res.body
  assert_equal "updated 7 title=Edited cover=cover.png #{data.bytesize} #{expected} image/png", res.body
end

test "an edit form without a chosen file sends an empty filename and the action gets no upload" do
  client, token = form_client
  empty = Cybertrain::Test::Upload.new("post[cover]", "", "application/octet-stream", "")
  res = client.patch_multipart("/posts/3", { "authenticity_token" => token, "post[title]" => "Keep" }, [empty])
  assert_response res, :ok
  assert_equal "updated 3 title=Keep cover=none", res.body
end

# The parser drops the empty input, so nothing is left under post: require
# (create) refuses that with a 400, nested (update) reads it as no file.
test "a form whose only field is a file input left empty has no post key" do
  client, token = form_client
  empty = Cybertrain::Test::Upload.new("post[cover]", "", "application/octet-stream", "")
  res = client.patch_multipart("/posts/4", { "authenticity_token" => token }, [empty])
  assert_response res, :ok
  assert_equal "updated 4 title= cover=none", res.body
  client, token = form_client
  res = client.post_multipart("/posts", { "authenticity_token" => token }, [empty])
  assert_response res, :bad_request
end

test "a text-only multipart form works too" do
  client, token = form_client
  res = client.post_multipart("/posts", { "authenticity_token" => token, "post[title]" => "Plain" })
  assert_response res, :created
  assert_equal "created title=Plain cover=none", res.body
end

test "a multipart POST without the token is forbidden, with or without a file" do
  client, token = form_client
  res = client.post_multipart("/posts", { "post[title]" => "No token" }, [cover_upload(cover_bytes)])
  assert_response res, :forbidden
  res = client.post_multipart("/posts", { "authenticity_token" => "wrong", "post[title]" => "Bad token" })
  assert_response res, :forbidden
  # A text part named like the token inside another name does not count.
  res = client.post_multipart("/posts", { "post[authenticity_token]" => token, "post[title]" => "Nested" })
  assert_response res, :forbidden
  # A file part is never a text field: the token cannot arrive as a file.
  as_file = Cybertrain::Test::Upload.new("authenticity_token", "token.txt", "text/plain", token)
  res = client.post_multipart("/posts", { "post[title]" => "As file" }, [as_file])
  assert_response res, :forbidden
end

test "the token may also come in the query string or the header, beside a multipart body" do
  client, token = form_client
  res = client.post_multipart("/posts?authenticity_token=#{token}", { "post[title]" => "Query" })
  assert_response res, :created
  res = client.post_multipart("/posts", { "post[title]" => "Header" }, [], { "X-CSRF-Token" => token })
  assert_response res, :created
end

test "a malformed multipart body is a 400" do
  client, token = form_client
  type = { "content-type" => "multipart/form-data; boundary=XyZ" }
  res = client.request("POST", "/posts", "this is not multipart", type)
  assert_response res, :bad_request
  puts res.body
  truncated = "--XyZ\r\nContent-Disposition: form-data; name=\"authenticity_token\"\r\n\r\n#{token}\r\n--XyZ\r\nContent-Dis"
  assert_response client.request("POST", "/posts", truncated, type), :bad_request
  no_boundary = { "content-type" => "multipart/form-data" }
  assert_response client.request("POST", "/posts", "--XyZ--\r\n", no_boundary), :bad_request
  puts client.response.body
end

test "a file over max_upload_bytes is a 400" do
  client, token = form_client
  big = Cybertrain::Test.binary([0, 1, 2, 255] * 16_385)
  assert_equal 65_540, big.bytesize
  res = client.post_multipart("/posts", { "authenticity_token" => token, "post[title]" => "Big" }, [cover_upload(big)])
  assert_response res, :bad_request
  puts res.body
  just_fits = Cybertrain::Test.binary([0, 1, 2, 255] * 16_384)
  assert_equal 65_536, just_fits.bytesize
  res = client.post_multipart("/posts", { "authenticity_token" => token, "post[title]" => "Fits" }, [cover_upload(just_fits)])
  assert_response res, :created
end

test "more parts than max_multipart_parts is a 400" do
  client, token = form_client
  fields = { "authenticity_token" => token }
  n = 0
  while n < 16
    fields["post[f#{n}]"] = "x"
    n += 1
  end
  res = client.post_multipart("/posts", fields)
  assert_response res, :bad_request
  puts res.body
end

test "a multipart body with a Content-Encoding is a 400" do
  client, token = form_client
  encoded = { "content-encoding" => "gzip" }
  res = client.post_multipart("/posts", { "authenticity_token" => token, "post[title]" => "Gz" }, [], encoded)
  assert_response res, :bad_request
  puts res.body
  res = client.post_multipart("/posts", { "authenticity_token" => token, "post[title]" => "Id" }, [], { "content-encoding" => "identity" })
  assert_response res, :created
end

test "a urlencoded form still works beside it" do
  client, token = form_client
  res = client.post("/posts", { "authenticity_token" => token, "post[title]" => "Old way" })
  assert_response res, :created
  assert_equal "created title=Old way cover=none", res.body
  res = client.patch("/posts/9", { "authenticity_token" => token, "post[title]" => "Old patch" })
  assert_response res, :ok
  assert_equal "updated 9 title=Old patch cover=none", res.body
end

test "nothing is written to the upload root by receiving a file" do
  refute File.exist?(UPLOAD_ROOT)
end

Cybertrain::Test.run!
