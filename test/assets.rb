# The asset helpers (spec sections 7.2 and 7.3): asset_path,
# stylesheet_link_tag, javascript_include_tag, image_tag and
# javascript_importmap_tags (with this request's CSP nonce, spec C-5), an
# unknown name in test and in production, and the immutable caching of
# digested files under /assets (7.4) through a booted Application, which
# reads public/assets/.manifest at boot. The asset table is a hand-written
# resolver and import map installed as gen/assets.rb would install them.
#
# It links SQLite through FFI, so it cannot run under CRuby: its snapshot
# comes from the compiled binary (spikes/NOTES.md rule 23).
require "stringio"
require "tmpdir"
require "cybertrain"
require "cybertrain/application"
require "cybertrain/test"
require "cybertrain/test/client"

LOG = StringIO.new
Cybertrain.logger = Cybertrain::Logger.new(LOG)

# What gen/assets.rb would hold for these assets.
module TestAssets
  def self.digest_path(logical)
    case logical
    when "application.css" then "/assets/application-1a2b3c4d.css"
    when "legacy.js" then "/assets/legacy-2b3c4d5e.js"
    when "logo.svg" then "/assets/logo-3c4d5e6f.svg"
    when "application.js" then "/assets/application-4d5e6f70.js"
    else ""
    end
  end

  def self.resolver = ->(name) { digest_path(name) }

  def self.importmap_json
    "{\"imports\":{\"application\":\"/assets/application-4d5e6f70.js\"," \
      "\"@hotwired/turbo\":\"https://cdn.jsdelivr.net/npm/@hotwired/turbo@8.0.12/dist/turbo.es2017-esm.js\"}}"
  end

  def self.preload_paths
    ["/assets/application-4d5e6f70.js", "https://cdn.jsdelivr.net/npm/@hotwired/turbo@8.0.12/dist/turbo.es2017-esm.js"]
  end
end

Cybertrain::Assets.install(TestAssets.resolver, TestAssets.importmap_json, TestAssets.preload_paths)

PUBLIC = Dir.mktmpdir("cybertrain-assets")
Dir.mkdir("#{PUBLIC}/assets")
File.write("#{PUBLIC}/assets/logo-3c4d5e6f.svg", "<svg/>")
File.write("#{PUBLIC}/assets/logo-0badf00d.svg", "<svg>old</svg>")
File.write("#{PUBLIC}/assets/.manifest", "logo.svg 3c4d5e6f 0badf00d\n")

at_exit do
  File.delete("#{PUBLIC}/assets/logo-3c4d5e6f.svg")
  File.delete("#{PUBLIC}/assets/logo-0badf00d.svg")
  File.delete("#{PUBLIC}/assets/.manifest")
  Dir.rmdir("#{PUBLIC}/assets")
  Dir.rmdir(PUBLIC)
end

def build_config(nonces)
  c = Cybertrain::Config.new
  c.env = "test"
  c.database_path = ":memory:"
  c.pool_size = 1
  c.secret_key_base = "assets-test-secret"
  c.log_level = :none
  c.views_root = "test/fixtures/views"
  c.public_root = PUBLIC
  if nonces
    c.content_security_policy do |p|
      p.default_src :self
      p.script_src :self
      p.style_src :self
    end
    c.content_security_policy_nonce_directives = %w[script-src style-src]
  end
  c
end

CONFIG = build_config(true)
Cybertrain.config = CONFIG

class AssetsController < Cybertrain::Controller
  def controller_path = "assets"

  def tags
    render :tags, layout: false
  end

  def importmap
    render :importmap, layout: false
  end

  def unknown
    render :unknown, layout: false
  end
end

ROUTER = Cybertrain::Router.new
ROUTER.get("/tags", "tags") { |ctx| AssetsController.new(ctx).process(:tags) { |c| c.tags } }
ROUTER.get("/importmap", "importmap") { |ctx| AssetsController.new(ctx).process(:importmap) { |c| c.importmap } }
ROUTER.get("/unknown", "unknown") { |ctx| AssetsController.new(ctx).process(:unknown) { |c| c.unknown } }

def build_app(config)
  Cybertrain::Application.new(router: ROUTER, url_resolver: ->(name, args, options) { "/" }, config: config)
end

APP = build_app(CONFIG)
APP.boot
CLIENT = Cybertrain::Test::Client.new(APP)

BARE_CONFIG = build_config(false)
Cybertrain.config = BARE_CONFIG
BARE_APP = build_app(BARE_CONFIG)
BARE_APP.boot
BARE_CLIENT = Cybertrain::Test::Client.new(BARE_APP)
Cybertrain.config = CONFIG

# A request to the application without a policy (the policy is read from
# Cybertrain.config while the request runs, as in test/csp.rb).
def bare_get(path)
  Cybertrain.config = BARE_CONFIG
  res = BARE_CLIENT.get(path)
  Cybertrain.config = CONFIG
  res
end

# The nonce in a Content-Security-Policy value, "" when there is none.
def nonce_of(header)
  text = header.to_s
  at = text.index("'nonce-")
  return "" if at.nil?

  stop = text.index("'", at + 7)
  text[at + 7, stop - at - 7].to_s
end

# What tags.html.erb renders; nonce "" for a page without a policy.
def tags_html(nonce)
  n = nonce.empty? ? "" : " nonce=\"#{nonce}\""
  "/assets/logo-3c4d5e6f.svg\n" \
    "<link rel=\"stylesheet\" href=\"/assets/application-1a2b3c4d.css\">\n" \
    "<link rel=\"stylesheet\" href=\"/assets/application-1a2b3c4d.css\" media=\"print\">\n" \
    "<link rel=\"stylesheet\" href=\"/assets/application-1a2b3c4d.css\"#{n}>\n" \
    "<link rel=\"stylesheet\" href=\"https://cdn.example/x.css\">\n" \
    "<script src=\"/assets/legacy-2b3c4d5e.js\"></script>\n" \
    "<script src=\"/assets/legacy-2b3c4d5e.js\"#{n}></script>\n" \
    "<img src=\"/assets/logo-3c4d5e6f.svg\" alt=\"Logo\" width=\"16\" height=\"16\" class=\"x\">\n" \
    "<img src=\"/assets/logo-3c4d5e6f.svg\" width=\"16\" height=\"16\">\n" \
    "<img src=\"/icons/a.png\">\n" \
    "<img src=\"https://example.com/a.png\" alt=\"A &amp; B\">\n" \
    "<img src=\"data:image/gif;base64,R0lGOD\">\n"
end

def importmap_html(nonce, entry)
  n = nonce.empty? ? "" : " nonce=\"#{nonce}\""
  "<script type=\"importmap\" data-turbo-track=\"reload\"#{n}>#{TestAssets.importmap_json}</script>\n" \
    "<link rel=\"modulepreload\" href=\"/assets/application-4d5e6f70.js\"#{n}>\n" \
    "<link rel=\"modulepreload\" href=\"https://cdn.jsdelivr.net/npm/@hotwired/turbo@8.0.12/dist/turbo.es2017-esm.js\"#{n}>\n" \
    "<script type=\"module\"#{n}>import \"#{entry}\"</script>"
end

# Assets.path raising inside a helper method (NOTES rule 32).
def path_error(name)
  Cybertrain::Assets.path(name)
  "none"
rescue Cybertrain::Assets::UnknownAsset => e
  message = e.message
  message
end

test "asset_path and the tag helpers" do
  assert_equal "/assets/logo-3c4d5e6f.svg", Cybertrain::Assets.path("logo.svg")
  assert_equal "/assets/application-1a2b3c4d.css", Cybertrain::Assets.path("application.css")
  res = CLIENT.get("/tags")
  assert_equal 200, res.status
  n = nonce_of(res.header("Content-Security-Policy"))
  assert_equal 24, n.size
  assert_equal tags_html(n), res.body
  # nonce: true without a policy writes no nonce
  assert_equal tags_html(""), bare_get("/tags").body
end

test "javascript_importmap_tags with and without a nonce" do
  res = CLIENT.get("/importmap")
  n = nonce_of(res.header("Content-Security-Policy"))
  assert_equal 24, n.size
  assert_equal "#{importmap_html(n, "application")}\n#{importmap_html(n, "admin")}\n", res.body
  bare = bare_get("/importmap")
  assert_equal "#{importmap_html("", "application")}\n#{importmap_html("", "admin")}\n", bare.body
end

test "an unknown asset raises in test and logs once in production, then emits the undigested path" do
  assert_equal "asset \"logo.png\" is not in app/assets, app/javascript or vendor/javascript (run spin run gen)", path_error("logo.png")
  assert_equal "", LOG.string
  # log_level :none left the logger at :error; production logs at :info
  Cybertrain.logger.level = :info
  Cybertrain::Assets.raise_on_unknown = false
  assert_equal "/assets/logo.png", Cybertrain::Assets.path("logo.png")
  assert_equal "/assets/logo.png", Cybertrain::Assets.path("logo.png")
  assert_equal "/assets/other.css", Cybertrain::Assets.path("other.css")
  logged = LOG.string
  assert_equal 1, logged.scan("asset \"logo.png\" is not in app/assets, app/javascript or vendor/javascript (run spin run gen)").size
  assert_equal 1, logged.scan("asset \"other.css\" is not in").size
  # the name a request supplied is escaped where the page writes it
  res = CLIENT.get("/unknown?name=%22%3E%3Cscript%3Ex%3C%2Fscript%3E")
  assert_equal 200, res.status
  assert_equal "/assets/&quot;&gt;&lt;script&gt;x&lt;/script&gt;\n" \
               "<img src=\"/assets/&quot;&gt;&lt;script&gt;x&lt;/script&gt;\">\n", res.body
  # a javascript: name is not a URL to write as given, but an asset name
  js = CLIENT.get("/unknown?name=javascript%3Aalert(1)")
  assert_equal "/assets/javascript:alert(1)\n<img src=\"/assets/javascript:alert(1)\">\n", js.body
  Cybertrain::Assets.raise_on_unknown = true
  assert_equal "asset \"logo.png\" is not in app/assets, app/javascript or vendor/javascript (run spin run gen)", path_error("logo.png")
end

test "boot reads public/assets/.manifest: current and kept digests are served immutable" do
  assert Cybertrain::Assets.kept_file?("logo-3c4d5e6f.svg")
  assert Cybertrain::Assets.kept_file?("logo-0badf00d.svg")
  refute Cybertrain::Assets.kept_file?("logo-12345678.svg")
  refute Cybertrain::Assets.kept_file?("logo.svg")
  ["logo-3c4d5e6f.svg", "logo-0badf00d.svg"].each do |name|
    res = CLIENT.get("/assets/#{name}")
    assert_equal 200, res.status
    assert_equal "public, max-age=31536000, immutable", res.header("Cache-Control").to_s
  end
end

Cybertrain::Test.run!
