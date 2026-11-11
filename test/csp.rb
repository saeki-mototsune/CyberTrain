# The Content Security Policy (spec C-5): Config#content_security_policy,
# ContentSecurityPolicyHeader with a fresh nonce per response, the
# report-only header, a controller's own policy, and the template helpers
# csp_meta_tag, javascript_tag(nonce: true) and content_security_policy_nonce
# (test/fixtures/views/csp). Through a booted Application and
# Cybertrain::Test::Client.
#
# It links SQLite through FFI, so it cannot run under CRuby: its snapshot
# comes from the compiled binary (spikes/NOTES.md rule 23).
require "stringio"
require "cybertrain"
require "cybertrain/application"
require "cybertrain/test"
require "cybertrain/test/client"

Cybertrain.logger = Cybertrain::Logger.new(StringIO.new)

def build_config(report_only)
  c = Cybertrain::Config.new
  c.env = "test"
  c.database_path = ":memory:"
  c.pool_size = 1
  c.secret_key_base = "csp-test-secret"
  c.log_level = :none
  c.views_root = "test/fixtures/views"
  c.content_security_policy do |p|
    p.default_src :self
    p.script_src :self, "https://cdn.jsdelivr.net"
    p.style_src :self
  end
  c.content_security_policy_nonce_directives = %w[script-src style-src]
  c.content_security_policy_report_only = report_only
  c
end

# The application's config, set before the controllers below copy its
# policy (config/app.rb loads before gen/app.rb in an application).
CONFIG = build_config(false)
Cybertrain.config = CONFIG

class CspController < Cybertrain::Controller
  def controller_path = "csp"

  def show
    render :show, layout: false
  end

  def plain
    render :plain, layout: false
  end

  def cached
    fresh_when etag: "v1"
    render :show, layout: false unless response.performed?
  end

  def blob
    send_blob "GIF89a", filename: "a.gif", content_type: "image/gif"
  end
end

class EmbedController < CspController
  content_security_policy do |p|
    p.frame_ancestors "https://a.example"
  end
end

class DeepEmbedController < EmbedController
end

ROUTER = Cybertrain::Router.new
ROUTER.get("/show", "show") { |ctx| CspController.new(ctx).process(:show) { |c| c.show } }
ROUTER.get("/plain", "plain") { |ctx| CspController.new(ctx).process(:plain) { |c| c.plain } }
ROUTER.get("/cached", "cached") { |ctx| CspController.new(ctx).process(:cached) { |c| c.cached } }
ROUTER.get("/blob", "blob") { |ctx| CspController.new(ctx).process(:blob) { |c| c.blob } }
ROUTER.get("/embed", "embed") { |ctx| EmbedController.new(ctx).process(:show) { |c| c.show } }
ROUTER.get("/deep", "deep") { |ctx| DeepEmbedController.new(ctx).process(:show) { |c| c.show } }

def build_app(config)
  Cybertrain::Application.new(router: ROUTER, url_resolver: ->(name, args, options) { "/" }, config: config)
end

APP = build_app(CONFIG)
APP.boot
CLIENT = Cybertrain::Test::Client.new(APP)

# The application's header with the nonce n.
def policy_with(n)
  "default-src 'self'; script-src 'self' https://cdn.jsdelivr.net 'nonce-#{n}'; style-src 'self' 'nonce-#{n}'"
end

# The nonce in a header value, "" when there is none.
def nonce_of(header)
  text = header.to_s
  at = text.index("'nonce-")
  return "" if at.nil?

  stop = text.index("'", at + 7)
  text[at + 7, stop - at - 7].to_s
end

def stack_names(app)
  names = Array.new(0) { "" }
  node = app.stack
  until node.nil?
    names << node.class.name
    node = node.app
  end
  names
end

test "the header sits inside RequestLogger's place, outside the stream endpoint" do
  assert_equal ["Cybertrain::ContentSecurityPolicyHeader", "Cybertrain::Stream::Endpoint", "Cybertrain::HealthCheck",
                "Cybertrain::Static", "Cybertrain::MethodOverride", "Cybertrain::SessionStore",
                "Cybertrain::CsrfProtection", "Cybertrain::Router"], stack_names(APP)
end

test "the policy is written per response with a fresh nonce" do
  first = CLIENT.get("/show")
  second = CLIENT.get("/show")
  assert_equal 200, first.status
  one = nonce_of(first.header("Content-Security-Policy"))
  two = nonce_of(second.header("Content-Security-Policy"))
  # 16 random bytes in strict Base64: 24 characters ending "=="
  assert_equal 24, one.size
  assert one.end_with?("==")
  refute one == two
  assert_equal policy_with(one), first.header("Content-Security-Policy").to_s
  assert_equal policy_with(two), second.header("Content-Security-Policy").to_s
  assert_nil first.header("Content-Security-Policy-Report-Only")
  # the page carries the header's nonce
  assert_equal "<meta name=\"csp-nonce\" content=\"#{one}\">\n<script nonce=\"#{one}\">x</script>\n#{one}\n", first.body
  assert_equal "<meta name=\"csp-nonce\" content=\"#{two}\">\n<script nonce=\"#{two}\">x</script>\n#{two}\n", second.body
end

test "a nonce is made for a page that writes none, and for every other response" do
  res = CLIENT.get("/plain")
  assert_equal "<script>plain</script>\n<script id=\"boot\">y</script>\n", res.body
  assert_equal 24, nonce_of(res.header("Content-Security-Policy")).size
  # a 404, the health check and HEAD carry the policy too
  missing = CLIENT.get("/nowhere")
  assert_equal 404, missing.status
  assert_includes missing.header("Content-Security-Policy").to_s, "default-src 'self'"
  assert_includes CLIENT.get("/up").header("Content-Security-Policy").to_s, "default-src 'self'"
  head = CLIENT.request("HEAD", "/show")
  assert_includes head.header("Content-Security-Policy").to_s, "script-src"
end

test "send_blob keeps its own policy" do
  res = CLIENT.get("/blob")
  assert_equal "default-src 'none'; sandbox", res.header("Content-Security-Policy").to_s
end

test "a 304 carries no policy, so the cached page keeps its nonce; the 200 does" do
  full = CLIENT.get("/cached")
  assert_equal 200, full.status
  n = nonce_of(full.header("Content-Security-Policy"))
  assert_equal policy_with(n), full.header("Content-Security-Policy").to_s
  etag = full.header("ETag").to_s
  refute etag.empty?
  unchanged = CLIENT.get("/cached", { "if-none-match" => etag })
  assert_equal 304, unchanged.status
  assert_nil unchanged.header("Content-Security-Policy")
  assert_nil unchanged.header("Content-Security-Policy-Report-Only")
end

test "report-only, off by default, and a controller's own policy" do
  embed = CLIENT.get("/embed")
  n = nonce_of(embed.header("Content-Security-Policy"))
  assert_equal "#{policy_with(n)}; frame-ancestors https://a.example", embed.header("Content-Security-Policy").to_s
  assert_includes embed.body, "content=\"#{n}\""
  # a subclass inherits it; its parent's other actions keep the application's
  deep = CLIENT.get("/deep")
  assert_includes deep.header("Content-Security-Policy").to_s, "; frame-ancestors https://a.example"
  refute CLIENT.get("/show").header("Content-Security-Policy").to_s.include?("frame-ancestors")
  # the controller's copy left the application's policy alone
  assert_equal "default-src 'self'; script-src 'self' https://cdn.jsdelivr.net; style-src 'self'",
               CONFIG.content_security_policy_value.header_value("", Array.new(0) { "" })

  report_config = build_config(true)
  Cybertrain.config = report_config
  report = Cybertrain::Test::Client.new(build_app(report_config)).get("/show")
  Cybertrain.config = CONFIG
  assert_nil report.header("Content-Security-Policy")
  value = report.header("Content-Security-Policy-Report-Only").to_s
  rn = nonce_of(value)
  assert_equal policy_with(rn), value
  assert_includes report.body, "<script nonce=\"#{rn}\">x</script>"

  bare_config = Cybertrain::Config.new
  bare_config.env = "test"
  bare_config.database_path = ":memory:"
  bare_config.secret_key_base = "csp-test-secret"
  bare_config.log_level = :none
  Cybertrain.config = bare_config
  bare_client = Cybertrain::Test::Client.new(build_app(bare_config))
  bare = bare_client.get("/show")
  bare_embed = bare_client.get("/embed")
  Cybertrain.config = CONFIG
  assert_nil bare.header("Content-Security-Policy")
  assert_nil bare.header("Content-Security-Policy-Report-Only")
  assert_equal "\n<script>x</script>\n\n", bare.body
  # the controller declared its policy while the application had one: it keeps it
  assert_includes bare_embed.header("Content-Security-Policy").to_s, "frame-ancestors https://a.example"
end

test "sources: keywords, schemes, Strings, replacing and removing a directive" do
  p = Cybertrain::ContentSecurityPolicy.new
  assert_equal "", p.header_value("abc", ["script-src"])
  p.default_src :self, :none, :unsafe_inline, :unsafe_eval, :strict_dynamic, :report_sample
  p.img_src :data, :https, :blob, :ws, :wss, "https://img.example", "'sha256-abc='"
  p.script_src :self
  assert_equal "default-src 'self' 'none' 'unsafe-inline' 'unsafe-eval' 'strict-dynamic' 'report-sample'; " \
               "img-src data: https: blob: ws: wss: https://img.example 'sha256-abc='; script-src 'self' 'nonce-abc'",
               p.header_value("abc", ["script-src", "style-src"])
  p.img_src :self
  p.default_src
  assert_equal "img-src 'self'; script-src 'self'", p.header_value("", ["script-src"])
  p.font_src :self
  p.connect_src :self
  p.media_src :self
  p.object_src :none
  p.frame_src :self
  p.child_src :self
  p.worker_src :self
  p.manifest_src :self
  p.base_uri :self
  p.form_action :self
  p.report_uri "/csp-report"
  assert_equal "img-src 'self'; script-src 'self'; font-src 'self'; connect-src 'self'; media-src 'self'; " \
               "object-src 'none'; frame-src 'self'; child-src 'self'; worker-src 'self'; manifest-src 'self'; " \
               "base-uri 'self'; form-action 'self'; report-uri /csp-report", p.header_value("", Array.new(0) { "" })
  copy = p.dup_policy
  copy.img_src :none
  assert_includes copy.header_value("", Array.new(0) { "" }), "img-src 'none'"
  assert_includes p.header_value("", Array.new(0) { "" }), "img-src 'self'"
end

test "a source that could break the header is refused" do
  p = Cybertrain::ContentSecurityPolicy.new
  msg = assert_raises("ArgumentError") { p.script_src :self, "https://x\r\nSet-Cookie: a=1" }
  assert_equal "content_security_policy script-src: \"https://x\\r\\nSet-Cookie: a=1\" is not a source (no spaces, ';', ',' or control characters)", msg
  assert_includes assert_raises("ArgumentError") { p.script_src "https://x; script-src *" }, "is not a source"
  assert_includes assert_raises("ArgumentError") { p.script_src "a,b" }, "is not a source"
  assert_includes assert_raises("ArgumentError") { p.script_src "" }, "is not a source"
  assert_includes assert_raises("ArgumentError") { p.script_src "café.example" }, "is not a source"
  assert_equal "content_security_policy img-src: unknown source :selfie", assert_raises("ArgumentError") { p.img_src :selfie }
  assert_equal "", p.header_value("", Array.new(0) { "" })
end

Cybertrain::Test.run!
