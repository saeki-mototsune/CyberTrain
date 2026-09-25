require "cybertrain/test"
require "cybertrain/controller"

# cybertrain/controller pulls in cybertrain/model and the SQLite FFI bindings
# (through the template helpers), so this program no longer runs under CRuby:
# take its snapshot from the compiled binary, never `spin test --regen`
# (spikes/NOTES.md rule 23).

# What the callbacks and actions did, in order; cleared by each dispatch.
TRAIL = []

# Kept in a constant on purpose: a SafeString that only ever travels as a
# keyword argument (`render html: SafeString.new(...)`) is laid out as an
# unboxed value type by Spinel 2026.09.12, and SafeString#+ then fails to
# compile. Any positional use (or a constant) keeps it a heap object, which a
# real app with templates always has. Remove this workaround once the
# html.rb fix for SafeString#+ under the value-type layout lands.
TRUSTED_MARKUP = Cybertrain::SafeString.new("<b>hi</b>")

class ApplicationController < Cybertrain::Controller
  before_action :authenticate
  rescue_from(RuntimeError, with: :boom_handler)
  rescue_from(KeyError) { |c, e| c.render plain: "missing #{e.message}", status: :not_found }

  def authenticate
    TRAIL << "authenticate"
    redirect_to "/login" if request.header("x-deny") == "1"
  end

  def boom_handler
    TRAIL << "boom_handler"
    render plain: "boom: #{rescued_exception.message}", status: 500
  end

  # What gen/controllers.rb emits for this class.
  def run_callback(name)
    case name
    when :authenticate then authenticate
    when :boom_handler then boom_handler
    else super
    end
  end
end

class PostsController < ApplicationController
  before_action :set_post, only: [:show, :edit]
  before_action(except: [:index]) do |c|
    TRAIL << "block"
    c.response.set_header("X-Block", "1")
  end
  after_action :stamp
  before_action(only: [:edit]) { |c| c.extra }

  def index
    TRAIL << "index"
    render plain: "all posts"
  end

  def show
    TRAIL << "show #{@post_id}"
    render plain: "post #{@post_id}"
  end

  def edit
    TRAIL << "edit #{@post_id}"
    render plain: "edit #{@post_id}"
  end

  def data
    render json: { "a" => 1 }
  end

  def list
    render json: [1, 2]
  end

  def raw_json
    render json: "{\"b\":2}", status: :created
  end

  def unsafe
    render html: "<b>hi</b>"
  end

  def trusted
    render html: TRUSTED_MARKUP
  end

  def csv
    render plain: "a,b", content_type: "text/csv"
  end

  def templated
    render :show
  end

  def double
    render plain: "a", json: "b"
  end

  def destroy
    head :no_content
  end

  def moved
    redirect_to "/x", status: :see_other
  end

  def explode
    raise "kaboom"
  end

  def missing_key
    raise KeyError, "slug"
  end

  def bad
    raise ArgumentError, "bad arg"
  end

  def silent
    TRAIL << "silent"
  end

  def extra
    TRAIL << "extra"
  end

  def set_post
    TRAIL << "set_post"
    @post_id = params["id"].to_s
  end

  def stamp
    TRAIL << "stamp"
    response.set_header("X-Stamp", "1")
  end

  def run_callback(name)
    case name
    when :set_post then set_post
    when :stamp then stamp
    else super
    end
  end
end

# No run_callback of its own: the symbol reaches the base implementation.
class GhostController < Cybertrain::Controller
  before_action :not_generated

  def index
    render plain: "ghost"
  end
end

# Symbolic statuses handed to head/redirect_to from stored blocks. Spinel
# does not widen a parameter from calls inside stored Procs, so these only
# worked by accident while other direct call sites passed Symbols; the
# block-only case lives in test/controller_status.rb.
class Gone < StandardError
end

class GuardController < Cybertrain::Controller
  before_action(only: [:locked]) { |c| c.head :forbidden }
  before_action(only: [:login]) { |c| c.redirect_to "/login", status: :see_other }
  rescue_from(Gone) { |c, e| c.head :not_found }

  def locked
  end

  def login
  end

  def lost
    raise Gone, "gone"
  end
end

def guard(action)
  c = GuardController.new(build_ctx(false))
  case action
  when :locked then c.process(:locked) { |x| x.locked }
  when :login then c.process(:login) { |x| x.login }
  when :lost then c.process(:lost) { |x| x.lost }
  else raise ArgumentError, "no route for #{action}"
  end
  c
end

def build_ctx(deny)
  headers = { "host" => "example.test" }
  headers["x-deny"] = "1" if deny
  ctx = Cybertrain::Context.new(Cybertrain::Request.new("GET", "/posts", headers, ""))
  ctx.params.set_value("id", "7")
  ctx
end

# Plays the part of gen/routes.rb: literal action names, literal bodies.
def dispatch(action, deny = false)
  TRAIL.clear
  c = PostsController.new(build_ctx(deny))
  case action
  when :index then c.process(:index) { |x| x.index }
  when :show then c.process(:show) { |x| x.show }
  when :edit then c.process(:edit) { |x| x.edit }
  when :data then c.process(:data) { |x| x.data }
  when :list then c.process(:list) { |x| x.list }
  when :raw_json then c.process(:raw_json) { |x| x.raw_json }
  when :unsafe then c.process(:unsafe) { |x| x.unsafe }
  when :trusted then c.process(:trusted) { |x| x.trusted }
  when :csv then c.process(:csv) { |x| x.csv }
  when :templated then c.process(:templated) { |x| x.templated }
  when :double then c.process(:double) { |x| x.double }
  when :destroy then c.process(:destroy) { |x| x.destroy }
  when :moved then c.process(:moved) { |x| x.moved }
  when :explode then c.process(:explode) { |x| x.explode }
  when :missing_key then c.process(:missing_key) { |x| x.missing_key }
  when :bad then c.process(:bad) { |x| x.bad }
  when :silent then c.process(:silent) { |x| x.silent }
  else raise ArgumentError, "no route for #{action}"
  end
  c
end

test "callbacks run base class first, then subclass, then the action, then after callbacks" do
  c = dispatch(:show)
  assert_equal ["authenticate", "set_post", "block", "show 7", "stamp"], TRAIL
  assert_equal "show", c.action_name
  assert_equal "post 7", c.response.body
  assert_equal "1", c.response.header("X-Block")
end

test "only: limits a callback to the listed actions" do
  dispatch(:edit)
  assert_equal ["authenticate", "set_post", "block", "extra", "edit 7", "stamp"], TRAIL
  dispatch(:data)
  refute TRAIL.include?("set_post")
end

test "except: skips a callback for the listed actions" do
  c = dispatch(:index)
  assert_equal ["authenticate", "index", "stamp"], TRAIL
  assert_nil c.response.header("X-Block")
end

test "a before callback that redirects halts the chain" do
  c = dispatch(:show, true)
  assert_equal ["authenticate"], TRAIL
  assert_equal 302, c.response.status
  assert_equal "/login", c.response.header("Location")
  assert_nil c.response.header("X-Stamp")
  assert c.performed?
end

test "after callbacks run after the action" do
  c = dispatch(:index)
  assert_equal "stamp", TRAIL.last
  assert_equal "1", c.response.header("X-Stamp")
end

test "render plain: sends text/plain" do
  c = dispatch(:index)
  assert_equal 200, c.response.status
  assert_equal "all posts", c.response.body
  assert_equal "text/plain; charset=utf-8", c.response.header("Content-Type")
  assert c.performed?
end

test "render json: generates JSON with application/json" do
  c = dispatch(:data)
  assert_equal "{\"a\":1}", c.response.body
  assert_equal "application/json; charset=utf-8", c.response.header("Content-Type")
  assert_equal "[1,2]", dispatch(:list).response.body
  raw = dispatch(:raw_json)
  assert_equal "{\"b\":2}", raw.response.body
  assert_equal 201, raw.response.status
end

test "render html: escapes a String but not a SafeString" do
  c = dispatch(:unsafe)
  assert_equal "&lt;b&gt;hi&lt;/b&gt;", c.response.body
  assert_equal "text/html; charset=utf-8", c.response.header("Content-Type")
  assert_equal "<b>hi</b>", dispatch(:trusted).response.body
end

test "render content_type: overrides the default" do
  assert_equal "text/csv", dispatch(:csv).response.header("Content-Type")
end

test "render with a template name goes through render_template" do
  msg = assert_raises("MissingTemplate") { dispatch(:templated) }
  assert_equal "no template show for PostsController", msg
end

test "render with two bodies is an ArgumentError" do
  assert_raises("ArgumentError") { dispatch(:double) }
end

test "head :no_content sends an empty body" do
  c = dispatch(:destroy)
  assert_equal 204, c.response.status
  assert_equal "", c.response.body
  assert c.performed?
end

test "redirect_to with a symbolic status" do
  c = dispatch(:moved)
  assert_equal 303, c.response.status
  assert_equal "/x", c.response.header("Location")
end

test "before_action { |c| c.head :forbidden } sends 403" do
  c = guard(:locked)
  assert_equal 403, c.response.status
  assert_equal "", c.response.body
end

test "before_action { |c| c.redirect_to ..., status: :see_other } sends 303" do
  c = guard(:login)
  assert_equal 303, c.response.status
  assert_equal "/login", c.response.header("Location")
end

test "rescue_from(X) { |c, e| c.head :not_found } sends 404" do
  assert_equal 404, guard(:lost).response.status
end

test "rescue_from with: handles the exception through run_callback" do
  c = dispatch(:explode)
  assert_equal 500, c.response.status
  assert_equal "boom: kaboom", c.response.body
  assert_equal "boom_handler", TRAIL.last
end

test "rescue_from with a block receives the controller and the exception" do
  c = dispatch(:missing_key)
  assert_equal 404, c.response.status
  assert_equal "missing slug", c.response.body
end

test "an exception without a handler propagates out of process" do
  msg = assert_raises("ArgumentError") { dispatch(:bad) }
  assert_equal "bad arg", msg
end

test "an action that renders nothing raises MissingTemplate" do
  msg = assert_raises("MissingTemplate") { dispatch(:silent) }
  assert_includes msg, "PostsController#silent"
end

test "an unknown callback name raises UnknownCallback" do
  c = GhostController.new(build_ctx(false))
  msg = assert_raises("UnknownCallback") { c.process(:index) { |x| x.index } }
  assert_equal "unknown callback :not_generated in GhostController (run `spin run gen`)", msg
end

# gen/routes.rb registers Router handlers as blocks, so process usually runs
# inside a stored Proc.
HANDLERS = []

def route(&handler)
  HANDLERS << handler
end

route { |ctx| PostsController.new(ctx).process(:show) { |c| c.show } }

test "process runs from a stored route handler" do
  ctx = build_ctx(false)
  TRAIL.clear
  HANDLERS[0].call(ctx)
  assert_equal "post 7", ctx.response.body
  assert_equal "stamp", TRAIL.last
end

test "chain_for and rescues_for walk the class hierarchy" do
  names = Cybertrain::Controller.chain_for(PostsController).map { |cb| cb.name.to_s }
  assert_equal ["authenticate", "set_post", "", "stamp", ""], names
  kinds = Cybertrain::Controller.chain_for(PostsController).map { |cb| cb.kind.to_s }
  assert_equal ["before", "before", "before", "after", "before"], kinds
  assert_equal 0, Cybertrain::Controller.chain_for(Cybertrain::Controller).size
  handlers = Cybertrain::Controller.rescues_for(PostsController).map { |h| h.class_name }
  assert_equal ["RuntimeError", "KeyError"], handlers
end

test "Callback#applies? honours only and except" do
  cb = Cybertrain::Callback.new(:before, :x, nil, [:show], [])
  assert cb.applies?(:show)
  refute cb.applies?(:index)
  cb2 = Cybertrain::Callback.new(:before, :x, nil, [], [:index])
  assert cb2.applies?(:show)
  refute cb2.applies?(:index)
end

test "status_code maps symbols and passes integers through" do
  assert_equal 404, Cybertrain::Controller.status_code(:not_found)
  assert_equal 422, Cybertrain::Controller.status_code(:unprocessable_entity)
  assert_equal 418, Cybertrain::Controller.status_code(418)
  assert_raises("ArgumentError") { Cybertrain::Controller.status_code(:teapot) }
end

Cybertrain::Test.run!
