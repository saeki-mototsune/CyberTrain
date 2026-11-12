require "cybertrain/test"
require "cybertrain/controller"

# The order Controller#process runs things in (docs/design.md D70): the
# before callbacks, the action, the implicit render, the after callbacks,
# then `Vary: Accept`; an exception anywhere in that goes to the rescue_from
# handler, skips whatever had not run yet, and still gets its Vary.
# test/controller.rb covers the callbacks' own order (base class first,
# only:/except:, skips) and what each rescue_from form answers; this program
# pins what happens between the steps.
#
# cybertrain/controller pulls in cybertrain/model and the SQLite FFI
# bindings, so the snapshot comes from the compiled binary, never `spin test
# --regen` (spikes/NOTES.md rule 23).

# What ran, in order; cleared by each dispatch.
TRAIL = []

class Boom < StandardError
end

class Hush < StandardError
end

class OrderController < Cybertrain::Controller
  before_action :first
  before_action { |c| c.second }
  after_action :third
  after_action { |c| c.fourth }
  rescue_from(Boom) do |c, e|
    TRAIL << "rescue #{e.message} performed=#{c.performed?}"
    c.render plain: "rescued #{e.message}", status: 500
  end
  rescue_from(Hush, with: :hush)

  # Renders nothing: quiet.html.erb is the implicit render.
  def quiet
    TRAIL << "quiet performed=#{performed?}"
  end

  def loud
    TRAIL << "loud"
    render plain: "loud"
  end

  # No template: the implicit render raises.
  def ghost
    TRAIL << "ghost"
  end

  def explode
    TRAIL << "explode"
    raise Boom, "in action"
  end

  def rendered_then_explode
    render plain: "half done", status: :created
    response.set_header("X-Half", "1")
    raise Boom, "after render"
  end

  def whisper
    TRAIL << "whisper"
    raise Hush, "quietly"
  end

  def unhandled
    TRAIL << "unhandled"
    raise ArgumentError, "nobody rescues this"
  end

  def first
    TRAIL << "first"
    raise Boom, "in before" if request.header("x-raise") == "before"

    render plain: "halted", status: :forbidden if request.header("x-halt") == "1"
  end

  def second
    TRAIL << "second"
  end

  # The implicit render has happened by now: the body is the template's.
  def third
    TRAIL << "third performed=#{performed?} body=#{response.body.to_s.strip}"
    raise Boom, "in after" if request.header("x-raise") == "after"
  end

  def fourth
    TRAIL << "fourth"
  end

  # A handler that answers nothing: no implicit render follows it.
  def hush
    TRAIL << "hush #{rescued_exception.message}"
  end

  # What gen/controllers.rb emits for this class.
  def run_callback(name)
    case name
    when :first then first
    when :third then third
    when :hush then hush
    else super
    end
  end
end

Cybertrain::Views.configure("test/fixtures/views", cache: true)
Cybertrain::Views.layout_name = "layouts/none"

# `accept` makes the format come from the Accept header, so the response
# gets `Vary: Accept` when (and only when) process reaches that step.
def build_ctx(extra_name, extra_value)
  headers = { "host" => "example.test", "accept" => "text/html" }
  headers[extra_name] = extra_value unless extra_name.empty?
  Cybertrain::Context.new(Cybertrain::Request.new("GET", "/order", headers, ""))
end

# Plays the part of gen/routes.rb: literal action names, literal bodies.
def dispatch(action, extra_name = "", extra_value = "")
  TRAIL.clear
  c = OrderController.new(build_ctx(extra_name, extra_value))
  case action
  when :quiet then c.process(:quiet) { |x| x.quiet }
  when :loud then c.process(:loud) { |x| x.loud }
  when :ghost then c.process(:ghost) { |x| x.ghost }
  when :explode then c.process(:explode) { |x| x.explode }
  when :rendered_then_explode then c.process(:rendered_then_explode) { |x| x.rendered_then_explode }
  when :whisper then c.process(:whisper) { |x| x.whisper }
  when :unhandled then c.process(:unhandled) { |x| x.unhandled }
  else raise ArgumentError, "no route for #{action}"
  end
  c
end

test "before callbacks, the action, the implicit render, the after callbacks, then Vary" do
  c = dispatch(:quiet)
  assert_equal ["first", "second", "quiet performed=false", "third performed=true body=quiet page", "fourth"], TRAIL
  assert_equal "quiet page\n", c.response.body
  assert_equal 200, c.response.status
  assert_equal "Accept", c.response.header("Vary")
end

test "an action that rendered is not rendered again before the after callbacks" do
  c = dispatch(:loud)
  assert_equal ["first", "second", "loud", "third performed=true body=loud", "fourth"], TRAIL
  assert_equal "loud", c.response.body
  assert_equal "text/plain; charset=utf-8", c.response.header("Content-Type")
end

test "a before callback that renders stops the later callbacks, the action, the implicit render and the after callbacks" do
  c = dispatch(:quiet, "x-halt", "1")
  assert_equal ["first"], TRAIL
  assert_equal 403, c.response.status
  assert_equal "halted", c.response.body
  # Vary is still added: it describes the response, whoever answered.
  assert_equal "Accept", c.response.header("Vary")
end

test "an exception in the action goes to rescue_from: no implicit render, no after callbacks" do
  c = dispatch(:explode)
  assert_equal ["first", "second", "explode", "rescue in action performed=false"], TRAIL
  assert_equal 500, c.response.status
  assert_equal "rescued in action", c.response.body
  assert_equal "Accept", c.response.header("Vary")
end

test "an exception in a before callback goes to rescue_from: nothing after it runs" do
  c = dispatch(:quiet, "x-raise", "before")
  assert_equal ["first", "rescue in before performed=false"], TRAIL
  assert_equal "rescued in before", c.response.body
  assert_equal "Accept", c.response.header("Vary")
end

test "an exception in an after callback goes to rescue_from, whose render replaces the action's" do
  c = dispatch(:quiet, "x-raise", "after")
  assert_equal ["first", "second", "quiet performed=false", "third performed=true body=quiet page",
                "rescue in after performed=true"], TRAIL
  assert_equal 500, c.response.status
  assert_equal "rescued in after", c.response.body
  assert_equal "text/plain; charset=utf-8", c.response.header("Content-Type")
end

test "a handler runs on the response the action left: its headers stay, its render is replaced" do
  c = dispatch(:rendered_then_explode)
  assert_equal ["first", "second", "rescue after render performed=true"], TRAIL
  assert_equal 500, c.response.status
  assert_equal "rescued after render", c.response.body
  assert_equal "1", c.response.header("X-Half")
end

test "a handler that renders nothing leaves the response unperformed: no implicit render after it" do
  c = dispatch(:whisper)
  assert_equal ["first", "second", "whisper", "hush quietly"], TRAIL
  refute c.performed?
  assert_equal "", c.response.body.to_s
  assert_equal "Accept", c.response.header("Vary")
end

test "an exception in the implicit render skips the after callbacks and propagates" do
  msg = assert_raises("Cybertrain::Template::MissingTemplate") { dispatch(:ghost) }
  assert_equal "Missing template test/fixtures/views/order/ghost.html.erb", msg
  assert_equal ["first", "second", "ghost"], TRAIL
end

test "an exception without a handler skips the after callbacks and propagates" do
  msg = assert_raises("ArgumentError") { dispatch(:unhandled) }
  assert_equal "nobody rescues this", msg
  assert_equal ["first", "second", "unhandled"], TRAIL
end

Cybertrain::Test.run!
