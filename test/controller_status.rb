require "cybertrain/test"
require "cybertrain/controller"

# cybertrain/controller pulls in cybertrain/model and the SQLite FFI bindings
# (through the template helpers), so this program no longer runs under CRuby:
# take its snapshot from the compiled binary, never `spin test --regen`
# (spikes/NOTES.md rule 23).

# Regression test for symbolic statuses passed from stored blocks.
#
# Spinel 2026.09.12 types a method parameter from the direct call sites only:
# calls made inside stored Procs (before_action / rescue_from blocks) do not
# widen it. In this program head, redirect_to and render are called ONLY from
# such blocks, never directly, so before the fix a Symbol status reached
# status_code typed as sp_int and came out as the Symbol's internal id
# (e.g. `head :forbidden` gave 101). Keep it that way: do not add direct
# calls to head/redirect_to/render here, or the test stops testing anything.

class ForbidController < Cybertrain::Controller
  before_action { |c| c.head :forbidden }

  def index
  end
end

class LoginController < Cybertrain::Controller
  before_action { |c| c.redirect_to "/login", status: :see_other }

  def index
  end
end

class DenyController < Cybertrain::Controller
  before_action { |c| c.render plain: "no", status: :forbidden }

  def index
  end
end

class LostController < Cybertrain::Controller
  rescue_from(KeyError) { |c, e| c.head :not_found }

  def index
    raise KeyError, "gone"
  end
end

class CreatedController < Cybertrain::Controller
  before_action { |c| c.head 201 }

  def index
  end
end

class TempController < Cybertrain::Controller
  before_action { |c| c.redirect_to "/tmp", status: 307 }

  def index
  end
end

class PlainRedirectController < Cybertrain::Controller
  before_action { |c| c.redirect_to "/home" }

  def index
  end
end

class TeapotController < Cybertrain::Controller
  before_action { |c| c.head :teapot }

  def index
  end
end

def build_ctx
  Cybertrain::Context.new(Cybertrain::Request.new("GET", "/", { "host" => "example.test" }, ""))
end

def forbid = ForbidController.new(build_ctx).tap { |c| c.process(:index) { |x| x.index } }
def login = LoginController.new(build_ctx).tap { |c| c.process(:index) { |x| x.index } }
def deny = DenyController.new(build_ctx).tap { |c| c.process(:index) { |x| x.index } }
def lost = LostController.new(build_ctx).tap { |c| c.process(:index) { |x| x.index } }
def created = CreatedController.new(build_ctx).tap { |c| c.process(:index) { |x| x.index } }
def temp = TempController.new(build_ctx).tap { |c| c.process(:index) { |x| x.index } }
def plain_redirect = PlainRedirectController.new(build_ctx).tap { |c| c.process(:index) { |x| x.index } }
def teapot = TeapotController.new(build_ctx).tap { |c| c.process(:index) { |x| x.index } }

test "before_action { |c| c.head :forbidden } sends 403" do
  c = forbid
  assert_equal 403, c.response.status
  assert_equal "", c.response.body
end

test "before_action { |c| c.redirect_to ..., status: :see_other } sends 303" do
  c = login
  assert_equal 303, c.response.status
  assert_equal "/login", c.response.header("Location")
end

test "before_action { |c| c.render plain:, status: :forbidden } sends 403" do
  c = deny
  assert_equal 403, c.response.status
  assert_equal "no", c.response.body
end

test "rescue_from(X) { |c, e| c.head :not_found } sends 404" do
  assert_equal 404, lost.response.status
end

test "an Integer status from a block passes through" do
  assert_equal 201, created.response.status
  assert_equal 307, temp.response.status
end

test "redirect_to from a block defaults to 302" do
  assert_equal 302, plain_redirect.response.status
end

test "an unknown status Symbol from a block is an ArgumentError" do
  msg = assert_raises("ArgumentError") { teapot }
  assert_equal "unknown status :teapot", msg
end

test "every Rack symbol, old aliases included" do
  assert_equal 100, Cybertrain::Controller.status_code(:continue)
  assert_equal 402, Cybertrain::Controller.status_code(:payment_required)
  assert_equal 413, Cybertrain::Controller.status_code(:content_too_large)
  assert_equal 413, Cybertrain::Controller.status_code(:payload_too_large)
  assert_equal 413, Cybertrain::Controller.status_code(:request_entity_too_large)
  assert_equal 414, Cybertrain::Controller.status_code(:uri_too_long)
  assert_equal 414, Cybertrain::Controller.status_code(:request_uri_too_long)
  assert_equal 416, Cybertrain::Controller.status_code(:range_not_satisfiable)
  assert_equal 416, Cybertrain::Controller.status_code(:requested_range_not_satisfiable)
  assert_equal 422, Cybertrain::Controller.status_code(:unprocessable_content)
  assert_equal 422, Cybertrain::Controller.status_code(:unprocessable_entity)
  assert_equal 451, Cybertrain::Controller.status_code(:unavailable_for_legal_reasons)
  assert_equal 511, Cybertrain::Controller.status_code(:network_authentication_required)
  assert_equal "Unprocessable Content", Cybertrain::Response.status_text(422)
  assert_equal "Content Too Large", Cybertrain::Response.status_text(413)
end

test "every symbol has a reason phrase" do
  Cybertrain::Controller::STATUS_SYMBOLS.each do |name, code|
    assert Cybertrain::Response::STATUS_TEXT.key?(code), "no phrase for #{name} (#{code})"
  end
  assert_equal 61, Cybertrain::Response::STATUS_TEXT.size
end

Cybertrain::Test.run!
