require "stringio"
require "cybertrain/test"
require "cybertrain/controller"
require "cybertrain/router"
require "cybertrain/app"
require "cybertrain/test/client"
require_relative "support/log_capture"

# cybertrain/controller pulls in cybertrain/model and the SQLite FFI bindings
# (through the template helpers), so this program no longer runs under CRuby:
# take its snapshot from the compiled binary, never `spin test --regen`
# (spikes/NOTES.md rule 23).

# A client fault answered from an action logs a "rejected request" line
# (Controller#rescue_with_handler); keep it out of the snapshot except in the
# tests that read it.
Cybertrain.logger = Cybertrain::Logger.new(StringIO.new)

# What the callbacks and actions did, in order; cleared by each dispatch.
TRAIL = []

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

module Billing
  class Invalid < StandardError
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

  def require_post
    params.require(:post)
    render plain: "unreachable"
  end

  # An action that parses a request body itself past Query's limit, and one
  # that raises an app class sharing a bare name with a framework one.
  def parse_body
    Cybertrain::Query.parse("&" * 4097)
    render plain: "unreachable"
  end

  # Dirties the response the way a before_action and an action might (a
  # cookie, CORS and Cache-Control headers, a redirect, an attachment
  # header) and then raises a client fault: the 400 keeps the deliberate
  # ones and drops only Location and Content-Disposition.
  def dirty_then_parse
    response.add_cookie("sid=abc; Path=/")
    response.set_header("access-control-allow-origin", "https://app.example")
    response.set_header("Cache-Control", "no-store")
    response.set_header("content-disposition", "attachment")
    response.set_header("Content-Disposition", "attachment")
    redirect_to "/elsewhere"
    Cybertrain::Query.parse("&" * 4097)
    render plain: "unreachable"
  end

  def bill
    raise Billing::Invalid, "card declined"
  end

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
    render html: Cybertrain::SafeString.new("<b>hi</b>")
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
# skip_before_action: a base class requiring sign-in everywhere, a subclass
# opening two actions, and a grandchild inheriting that skip. SKIPPED
# records what ran; `skip_before_action` is not scanned into run_callback,
# so the case table below lists the callbacks only.
SKIPPED = []

class SecureController < Cybertrain::Controller
  before_action :require_login
  before_action :track

  def require_login
    SKIPPED << "require_login"
    head :forbidden
  end

  def track
    SKIPPED << "track"
  end

  def run_callback(name)
    case name
    when :require_login then require_login
    when :track then track
    else super
    end
  end
end

class SessionsController < SecureController
  skip_before_action :require_login, only: [:new, :create]
  skip_before_action :track, except: [:destroy]

  def new_action
    render plain: "sign in"
  end

  def create
    render plain: "signed in"
  end

  def destroy
    render plain: "signed out"
  end
end

class GuestSessionsController < SessionsController
  def new_action
    render plain: "guest sign in"
  end
end

def secure(klass, action)
  SKIPPED.clear
  ctx = build_ctx(false)
  c = case klass
      when "sessions" then SessionsController.new(ctx)
      when "guest" then GuestSessionsController.new(ctx)
      else SecureController.new(ctx)
      end
  case action
  when :new then c.process(:new) { |x| x.new_action }
  when :create then c.process(:create) { |x| x.create }
  when :destroy then c.process(:destroy) { |x| x.destroy }
  else raise ArgumentError, "no route for #{action}"
  end
  c
end

# allow_unauthenticated_access (plan D14): the Controller class method the
# generated controllers call in their class bodies. It is
# skip_before_action(:require_authentication, only:, except:), so a base
# class requiring sign-in keeps it for every action the call does not open.
class AuthBaseController < Cybertrain::Controller
  before_action :require_authentication

  def require_authentication
    SKIPPED << "require_authentication"
    head :forbidden
  end

  def run_callback(name)
    case name
    when :require_authentication then require_authentication
    else super
    end
  end
end

class PasswordsController < AuthBaseController
  allow_unauthenticated_access only: [:new, :create]

  def new_action
    render plain: "forgot"
  end

  def create
    render plain: "sent"
  end

  def destroy
    render plain: "gone"
  end
end

class SignupsController < AuthBaseController
  allow_unauthenticated_access

  def new_action
    render plain: "sign up"
  end

  def create
    render plain: "signed up"
  end

  def destroy
    render plain: "cancelled"
  end
end

class AccountsController < AuthBaseController
  allow_unauthenticated_access except: [:destroy]

  def new_action
    render plain: "account"
  end

  def create
    render plain: "created"
  end

  def destroy
    render plain: "closed"
  end
end

# A class whose only skip a test adds, to read the call's return value.
class LaterOpenedController < AuthBaseController
end

def open_auth(klass, action)
  SKIPPED.clear
  ctx = build_ctx(false)
  c = case klass
      when "passwords" then PasswordsController.new(ctx)
      when "signups" then SignupsController.new(ctx)
      else AccountsController.new(ctx)
      end
  case action
  when :new then c.process(:new) { |x| x.new_action }
  when :create then c.process(:create) { |x| x.create }
  when :destroy then c.process(:destroy) { |x| x.destroy }
  else raise ArgumentError, "no route for #{action}"
  end
  c
end

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

test "skip_before_action leaves out a parent's callback for only: the listed actions" do
  c = secure("sessions", :new)
  assert_equal 200, c.response.status
  assert_equal "sign in", c.response.body
  assert_equal [], SKIPPED
  c = secure("sessions", :create)
  assert_equal "signed in", c.response.body
  assert_equal [], SKIPPED
end

test "an action a skip does not list still runs the callback" do
  c = secure("sessions", :destroy)
  assert_equal 403, c.response.status
  assert_equal "", c.response.body
  assert_equal ["require_login"], SKIPPED
end

test "a skip with except: keeps the callback for the listed actions only" do
  skips = Cybertrain::Controller.skips_for(SessionsController)
  assert_equal 2, skips.size
  assert_equal "track", skips[1].name.to_s
  assert skips[1].applies?(:new)
  refute skips[1].applies?(:destroy)
end

test "a subclass inherits its parent's skips" do
  c = secure("guest", :new)
  assert_equal "guest sign in", c.response.body
  assert_equal [], SKIPPED
  assert_equal 2, Cybertrain::Controller.skips_for(GuestSessionsController).size
  assert_equal 0, Cybertrain::Controller.skips_for(SecureController).size
  assert_equal 0, Cybertrain::Controller.skips_for(PostsController).size
end

test "skipped? matches by name and action, never a block callback" do
  skips = Cybertrain::Controller.skips_for(SessionsController)
  named = Cybertrain::Callback.new(:before, :require_login, nil, [], [])
  assert Cybertrain::Controller.skipped?(skips, named, :new)
  refute Cybertrain::Controller.skipped?(skips, named, :destroy)
  other = Cybertrain::Callback.new(:before, :set_post, nil, [], [])
  refute Cybertrain::Controller.skipped?(skips, other, :new)
  block = Cybertrain::Callback.new(:before, nil, nil, [], [])
  refute Cybertrain::Controller.skipped?(skips, block, :new)
  assert_equal 0, Cybertrain::Controller::NO_SKIPS.size
end

test "allow_unauthenticated_access skips require_authentication for the listed actions" do
  c = open_auth("passwords", :new)
  assert_equal 200, c.response.status
  assert_equal "forgot", c.response.body
  assert_equal [], SKIPPED
  c = open_auth("passwords", :create)
  assert_equal 200, c.response.status
  assert_equal "sent", c.response.body
  assert_equal [], SKIPPED
  c = open_auth("passwords", :destroy)
  assert_equal 403, c.response.status
  assert_equal "", c.response.body
  assert_equal ["require_authentication"], SKIPPED
  skips = Cybertrain::Controller.skips_for(PasswordsController)
  assert_equal 1, skips.size
  assert_equal "require_authentication", skips[0].name.to_s
  assert skips[0].applies?(:new)
  assert skips[0].applies?(:create)
  refute skips[0].applies?(:destroy)
  assert_equal 0, Cybertrain::Controller.skips_for(AuthBaseController).size
end

test "allow_unauthenticated_access with no actions opens all of them; except: keeps the listed ones" do
  [:new, :create, :destroy].each do |action|
    c = open_auth("signups", action)
    assert_equal 200, c.response.status
    assert_equal [], SKIPPED
  end
  assert_equal "cancelled", open_auth("signups", :destroy).response.body
  c = open_auth("accounts", :new)
  assert_equal "account", c.response.body
  assert_equal [], SKIPPED
  c = open_auth("accounts", :create)
  assert_equal "created", c.response.body
  assert_equal [], SKIPPED
  c = open_auth("accounts", :destroy)
  assert_equal 403, c.response.status
  assert_equal ["require_authentication"], SKIPPED
end

test "allow_unauthenticated_access answers nil and records one skip on the calling class" do
  assert_equal 0, Cybertrain::Controller.skips_for(LaterOpenedController).size
  assert_nil LaterOpenedController.allow_unauthenticated_access(only: [:show])
  skips = Cybertrain::Controller.skips_for(LaterOpenedController)
  assert_equal 1, skips.size
  assert_equal "require_authentication", skips[0].name.to_s
  assert skips[0].applies?(:show)
  refute skips[0].applies?(:index)
  assert_equal 0, Cybertrain::Controller.skips_for(AuthBaseController).size
end

test "status_code maps symbols and passes integers through" do
  assert_equal 404, Cybertrain::Controller.status_code(:not_found)
  assert_equal 422, Cybertrain::Controller.status_code(:unprocessable_entity)
  assert_equal 418, Cybertrain::Controller.status_code(418)
  assert_raises("ArgumentError") { Cybertrain::Controller.status_code(:teapot) }
end

test "a missing required param answers 400 Bad Request" do
  ctx = build_ctx(false)
  ctx.params.set_value("other", "1")
  controller = PostsController.new(ctx)
  controller.process(:require_post) { |c| c.require_post }
  assert_equal 400, ctx.response.status
  assert_includes ctx.response.body, "param is missing or the value is empty: post"
end

test "a client fault raised in an action answers 400 with its message, like a missing param" do
  ctx = build_ctx(false)
  controller = PostsController.new(ctx)
  controller.process(:parse_body) { |c| c.parse_body }
  assert_equal 400, ctx.response.status
  assert_equal "too many parameters (limit 4096)", ctx.response.body
end

test "a client fault after the action redirected drops only Location and Content-Disposition" do
  ctx = build_ctx(false)
  controller = PostsController.new(ctx)
  controller.process(:dirty_then_parse) { |c| c.dirty_then_parse }
  assert_equal 400, ctx.response.status
  assert_equal "too many parameters (limit 4096)", ctx.response.body
  assert_equal "text/plain; charset=utf-8", ctx.response.header("Content-Type")
  assert_nil ctx.response.header("Location")
  assert_nil ctx.response.header("Content-Disposition")
  assert_equal 1, ctx.response.cookies.length
  assert_equal "sid=abc; Path=/", ctx.response.cookies[0]
  assert_equal "https://app.example", ctx.response.header("Access-Control-Allow-Origin")
  assert_equal "no-store", ctx.response.header("Cache-Control")
  assert controller.performed?
end

# The 400 answered inside the action is logged like the same fault one layer
# up (ErrorPages, Dev::ErrorPage): one info line through Cybertrain.logger.
# An exception the controller does not answer (the 500 path) logs nothing
# here: ErrorPages classifies and logs it once, as the error.
test "a client fault answered from an action logs one rejected-request line" do
  previous = Cybertrain.logger
  log = StringIO.new
  Cybertrain.logger = Cybertrain::Logger.new(log, :info)
  ctx = build_ctx(false)
  controller = PostsController.new(ctx)
  controller.process(:parse_body) { |c| c.parse_body }
  assert_equal 400, ctx.response.status
  assert_equal ["INFO rejected request (400 Bad Request): too many parameters (limit 4096)"], LogCapture.entries(log.string)
  ctx2 = build_ctx(false)
  ctx2.params.set_value("other", "1")
  PostsController.new(ctx2).process(:require_post) { |c| c.require_post }
  assert_equal 400, ctx2.response.status
  assert_equal 2, log.string.lines.size
  assert_logged log.string, "INFO", "rejected request (400 Bad Request): param is missing or the value is empty: post"
  Cybertrain.logger = previous
end

test "an exception the controller re-raises is not logged by it (ErrorPages logs it once)" do
  previous = Cybertrain.logger
  log = StringIO.new
  Cybertrain.logger = Cybertrain::Logger.new(log, :info)
  controller = PostsController.new(build_ctx(false))
  assert_raises("Invalid") { controller.process(:bill) { |c| c.bill } }
  assert_equal "", log.string
  Cybertrain.logger = previous
end

test "an app exception sharing a bare name with a framework one is still raised (500 path)" do
  ctx = build_ctx(false)
  controller = PostsController.new(ctx)
  msg = assert_raises("Invalid") { controller.process(:bill) { |c| c.bill } }
  assert_equal "card declined", msg
end

test "local_path? and safe_redirect_path accept only an ordinary local path" do
  controller = PostsController.new(build_ctx(false))
  ["/", "/posts", "/posts/1?tab=details#title", "/posts//1", "/caf%C3%A9", "/" + "a" * 2047].each do |good|
    assert controller.local_path?(good), good
    assert_equal good, controller.safe_redirect_path(good, "/home")
  end
  unsafe = ["", "posts", "https://evil.example/", "//evil.example/", "///evil.example/",
            "/\\evil.example/", "/posts\\evil", " /posts", "/記事", "/café", "/" + "a" * 2048,
            "/a b", "/\t", "/x\x7f"]
  unsafe.each do |bad|
    refute controller.local_path?(bad), bad
    assert_equal "/home", controller.safe_redirect_path(bad, "/home")
  end
  refute controller.local_path?(nil)
  assert_equal "/home", controller.safe_redirect_path(nil, "/home")
end

# The per-request locale (plan R4, Task 4): a before_action or an action
# sets I18n.locale on the connection's thread; the next request on that
# thread (a keep-alive connection) starts at the default locale again.
class LocaleController < Cybertrain::Controller
  before_action(only: [:switch]) { |c| I18n.locale = c.params["to"].to_s }

  def switch
    render plain: "#{I18n.locale} #{I18n.t("errors.messages.blank")}"
  end

  def set_in_action
    I18n.locale = :ja
    raise "after setting ja"
  end

  def show
    render plain: "#{I18n.locale} #{I18n.t("errors.messages.blank")}"
  end
end

def locale_app
  router = Cybertrain::Router.new
  router.get("/switch") { |c| LocaleController.new(c).process(:switch) { |x| x.switch } }
  router.get("/raise") { |c| LocaleController.new(c).process(:set_in_action) { |x| x.set_in_action } }
  router.get("/show") { |c| LocaleController.new(c).process(:show) { |x| x.show } }
  Cybertrain::App.new(router, public_root: "test/no_such_public_dir", logging: false)
end

test "the locale is reset per action: a keep-alive pair, the first sets ja" do
  I18n.available_locales = [:en, :ja]
  client = Cybertrain::Test::Client.new(locale_app)
  assert_equal "ja を入力してください", client.get("/switch?to=ja").body
  # The in-process client serves every request on this one thread, as a
  # keep-alive connection does: the locale is still :ja after the request,
  # and the next request starts at :en.
  assert_equal :ja, I18n.locale
  assert_equal "en can't be blank", client.get("/show").body
  assert_equal :en, I18n.locale
  # A locale set in an action that then raises (no ErrorPages here, so the
  # exception reaches the client) does not leak either.
  assert_equal "after setting ja", assert_raises("RuntimeError") { client.get("/raise") }
  assert_equal :ja, I18n.locale
  assert_equal "en can't be blank", client.get("/show").body
  # An unavailable locale from the request is refused before the action.
  message = assert_raises("I18n::InvalidLocale") { client.get("/switch?to=xx") }
  assert_equal "\"xx\" is not an available locale", message
  assert_equal :en, I18n.locale
  assert_equal "en can't be blank", client.get("/show").body
end

# The jobs page's controller as ControllersEmitter writes it for three
# jobs_page forms (test/gen_controllers.rb pins those lines), under an
# ApplicationController shaped like `generate authentication`'s:
# resume_session then require_authentication (303 to sign in), and
# require_admin (404 unless the user is an admin). The x-user header plays
# the session: "" a visitor, "ann" a user, "admin" an admin.
JOBS_CHAIN = []

class JobsAppController < Cybertrain::Controller
  before_action :resume_session
  before_action :require_authentication

  def resume_session
    JOBS_CHAIN << "resume_session"
    @user = request.header("x-user").to_s
    nil
  end

  def require_authentication
    JOBS_CHAIN << "require_authentication"
    redirect_to "/session/new", status: :see_other if @user.empty?
    nil
  end

  def require_admin
    JOBS_CHAIN << "require_admin"
    render plain: "Not Found", status: :not_found unless @user == "admin"
    nil
  end

  # A guard that only restricts a user who exists (N2's shape).
  def check_staff
    JOBS_CHAIN << "check_staff"
    head :forbidden if @user == "ann"
    nil
  end

  def run_callback(name)
    case name
    when :resume_session then resume_session
    when :require_authentication then require_authentication
    when :require_admin then require_admin
    when :check_staff then check_staff
    else super
    end
  end

  def index
    render plain: "JOBS"
  end
end

# jobs_page "/admin/jobs", before_action: :require_authentication
class JobsByAuthenticationController < JobsAppController
  before_action :require_authentication
end

# jobs_page "/admin/jobs", before_action: :check_staff
class JobsByStaffController < JobsAppController
  before_action :check_staff
end

# jobs_page "/admin/jobs", before_action: :require_admin, skip_before_action: :require_authentication
class JobsByAdminController < JobsAppController
  skip_before_action :require_authentication
  before_action :require_admin
end

def jobs_get(klass, user)
  JOBS_CHAIN.clear
  ctx = Cybertrain::Context.new(Cybertrain::Request.new("GET", "/admin/jobs", { "host" => "example.test", "x-user" => user }, ""))
  c = case klass
      when "authentication" then JobsByAuthenticationController.new(ctx)
      when "staff" then JobsByStaffController.new(ctx)
      else JobsByAdminController.new(ctx)
      end
  c.process(:index) { |x| x.index }
  "#{c.response.status} #{c.response.body} #{JOBS_CHAIN.join(",")}"
end

test "a jobs page guarded by require_authentication alone does not let a visitor in" do
  assert_equal "303  resume_session,require_authentication", jobs_get("authentication", "")
  assert_equal "200 JOBS resume_session,require_authentication,require_authentication", jobs_get("authentication", "ann")
end

test "a jobs page guarded by another method keeps authentication in front of it" do
  assert_equal "303  resume_session,require_authentication", jobs_get("staff", "")
  assert_equal "403  resume_session,require_authentication,check_staff", jobs_get("staff", "ann")
  assert_equal "200 JOBS resume_session,require_authentication,check_staff", jobs_get("staff", "admin")
end

test "with skip_before_action: :require_authentication, require_admin alone answers: 404 to a visitor" do
  assert_equal "404 Not Found resume_session,require_admin", jobs_get("admin", "")
  assert_equal "404 Not Found resume_session,require_admin", jobs_get("admin", "ann")
  assert_equal "200 JOBS resume_session,require_admin", jobs_get("admin", "admin")
end

Cybertrain::Test.run!
