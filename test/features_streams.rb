require "tmpdir"
require "stringio"
require "cybertrain/core"
require "cybertrain/streams"
require "cybertrain/test"
require "cybertrain/test/client"

# The core and cybertrain/streams alone (the optional-subsystems design,
# docs/superpowers/specs/2026-11-13-optional-subsystems-design.md, section
# 3): it compiles without jobs, feeds, the mailer, the cache or rate
# limiting; StreamsFeature is the one registered feature; the stack mounts
# the stream endpoint where `require "cybertrain"` does, and it answers
# (503: no server role started the poller); turbo_stream_from and the
# template's turbo_stream builder render; a controller's turbo_stream
# builds an element for `render turbo_stream:`. Runs from a fresh temp
# directory. It links SQLite through FFI, so its snapshot comes from the
# compiled binary (spikes/NOTES.md rule 23).
TMP = Dir.mktmpdir("cybertrain-features-streams")
Dir.chdir(TMP)
Dir.mkdir("public")
ENV["CYBERTRAIN_ENV"] = "test"

def rm_tree(path)
  if File.directory?(path)
    Dir.children(path).each { |child| rm_tree(File.join(path, child)) }
    Dir.rmdir(path)
  else
    File.delete(path)
  end
end

at_exit do
  Dir.chdir("/")
  rm_tree(TMP)
end

LOG = StringIO.new
Cybertrain.logger = Cybertrain::Logger.new(LOG)

class PagesController < Cybertrain::Controller
  def remove
    render turbo_stream: turbo_stream.remove("notice")
  end
end

CONFIG = Cybertrain.config
CONFIG.database_path = ":memory:"
CONFIG.pool_size = 1
CONFIG.public_root = "public"
CONFIG.secret_key_base = "features-streams-secret"
CONFIG.log_level = :info

ROUTER = Cybertrain::Router.new
ROUTER.get("/remove", "remove") { |ctx| PagesController.new(ctx).process(:remove) { |c| c.remove } }

APP = Cybertrain::Application.new(router: ROUTER, url_resolver: ->(name, args, options) { "/" })
APP.boot
CLIENT = Cybertrain::Test::Client.new(APP)

def render_inline(src)
  template = Cybertrain::Template::Template.parse(src, "pages/inline")
  env = { "__template_dir" => [nil, 0, 0.0, "", true][3] }
  env["__template_dir"] = "pages"
  Cybertrain::Template::Interpreter.new(Cybertrain::Template::Helpers.new(nil)).render(template, env)
end

test "streams is the one registered feature" do
  assert_equal "streams", Cybertrain::Features.feature_names.join(",")
  refute Cybertrain::Features.periodic_scheduler?
end

test "the stack mounts the stream endpoint after the health check" do
  names = Array.new(0) { "" }
  node = APP.stack
  until node.nil?
    names << node.class.name
    node = node.app
  end
  assert_equal "Cybertrain::RequestId,Cybertrain::RequestLogger,Cybertrain::Stream::Endpoint,Cybertrain::HealthCheck,Cybertrain::Static," \
               "Cybertrain::MethodOverride,Cybertrain::SessionStore,Cybertrain::CsrfProtection,Cybertrain::Router", names.join(",")
end

test "the endpoint answers: no server role started the poller" do
  res = CLIENT.get("/cybertrain/stream?s=x")
  assert_equal 503, res.status
  assert_equal "stream poller is not running", res.body
end

test "turbo_stream_from renders a stream source with a token that verifies" do
  html = render_inline("<%= turbo_stream_from \"alerts\" %>")
  prefix = "<turbo-stream-source src=\"/cybertrain/stream?s="
  assert html.start_with?(prefix)
  assert html.end_with?("\"></turbo-stream-source>")
  token = html[prefix.size, html.size - prefix.size - "\"></turbo-stream-source>".size].to_s
  assert_equal "alerts", Cybertrain::Stream.verified_names(token).join(",")
end

test "the template's turbo_stream builder renders an element" do
  assert_equal "<turbo-stream action=\"remove\" target=\"notice\"></turbo-stream>", render_inline("<%= turbo_stream.remove \"notice\" %>")
end

test "a controller's turbo_stream answers render turbo_stream:" do
  res = CLIENT.get("/remove")
  assert_equal 200, res.status
  assert_equal "<turbo-stream action=\"remove\" target=\"notice\"></turbo-stream>", res.body
end

Cybertrain::Test.run!
