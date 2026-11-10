# Phase 4a spike, item 3 (spec section 12): a controller concern written
# the Rails way (`extend ActiveSupport::Concern`, `included do ... end`,
# `class_methods do ... end`), with the no-op ActiveSupport::Concern of
# plan decision 11, followed by what gen/concerns.rb would write (plan
# decisions 8 and 12): the `included` body spliced into a reopening of the
# including class, and the class method as `def self.per_page` on the
# concern plus a forwarder in the class. An action reads
# `self.class.per_page`. A record, not a test.
#
# Run (Spinel 2026.11.04.7026, from spikes/phase4/; cybertrain/controller
# links SQLite through FFI, so compiled only):
#   spinel $(spin flags) concern_class_methods.rb -o /tmp/concern_class_methods && /tmp/concern_class_methods
# Output (68 s to compile):
#   index without admin: 403
#   index as admin: 200 index per_page=50 admin?=true
#   show raises: 422 bad: no such page
#   ArticlesController.per_page: 50
#   AdminGate.per_page: 50   (this spike's generated `def self.per_page` on
#                              the concern, line ~115; Rails' class_methods
#                              gives only the including class a class method)
#   included: true
#
# Without the three declaration stubs in ActiveSupport::Concern below, the
# program is refused (the `included` block never runs, but Spinel compiles
# its implicit-self calls against AdminGate, which has no `before_action`;
# the by-design ahead-of-time NoMethodError of spikes/NOTES.md rule 84):
#   spinel: concern_class_methods.rb:42: unsupported call: node 144544 (CallNode `before_action`) recv=-/ty-1 argc=2 arg0ty8
#   spinel: 1 refusal, nothing written
# (line 42 was, before this header grew, the `before_action` line of the
# `included` block). With them it builds and runs as above
# (spikes/NOTES.md rule 92).
#
# The `def per_page` inside the never-called `class_methods` block is
# compiled as an instance method of AdminGate (so of every including
# controller), which CRuby never defines (spikes/NOTES.md rule 93). Reduced,
# with `class C; include Gate; end`: `C.new.respond_to?(:per_page)` is false
# under CRuby 3.3.6 and true compiled.
require "cybertrain"
require "cybertrain/test/client"

module ActiveSupport
  module Concern
    def included(base = nil, &block) = nil
    def class_methods(&block) = nil

    # The declarations an `included` block makes, as no-ops on the concern
    # (the block never runs; it only has to compile).
    def before_action(name = nil, only: [], except: [], &block) = nil
    def helper_method(*names) = nil
    def rescue_from(klass, with: nil, &block) = nil
  end
end

module Cybertrain
  class Controller
    # Stand-in for Task 5's helper_method (helper names are data for gen).
    def self.helper_method(*names)
      nil
    end
  end
end

class ApplicationController < Cybertrain::Controller
end

# app/controllers/concerns/admin_gate.rb, as written by the application.
module AdminGate
  extend ActiveSupport::Concern

  included do
    before_action :require_admin, only: [:index]
    helper_method :admin?
    rescue_from ArgumentError, with: :bad
  end

  class_methods do
    def per_page = 50
  end

  def admin?
    request.header("x-admin") == "1"
  end

  def require_admin
    head :forbidden unless admin?
  end

  def bad
    render plain: "bad: #{rescued_exception.message}", status: :unprocessable_entity
  end
end

class ArticlesController < ApplicationController
  include AdminGate

  def index
    render plain: "index per_page=#{self.class.per_page} admin?=#{admin?}"
  end

  def show
    raise ArgumentError, "no such page"
  end

  def run_callback(name)
    case name
    when :require_admin then require_admin
    when :bad then bad
    else super
    end
  end
end

# gen/concerns.rb (required last): class_methods as singleton methods of the
# concern, a forwarder in each including class, and the included body
# spliced verbatim.
module AdminGate
  def self.per_page = 50
end

class ArticlesController
  def self.per_page(...) = AdminGate.per_page(...)

  before_action :require_admin, only: [:index]
  helper_method :admin?
  rescue_from ArgumentError, with: :bad
end

module Gen
  module Routes
    def self.build(router)
      router.add("GET", "/articles", "") { |ctx| ArticlesController.new(ctx).process(:index) { |c| c.index } }
      router.add("GET", "/articles/1", "") { |ctx| ArticlesController.new(ctx).process(:show) { |c| c.show } }
      router
    end
  end
end

Cybertrain.logger = Cybertrain::Logger.new(nil, :error)
client = Cybertrain::Test::Client.new(Cybertrain::App.new(Gen::Routes.build(Cybertrain::Router.new), logging: false))
res = client.get("/articles")
puts "index without admin: #{res.status}"
res = client.get("/articles", { "X-Admin" => "1" })
puts "index as admin: #{res.status} #{res.body}"
res = client.get("/articles/1")
puts "show raises: #{res.status} #{res.body}"
puts "ArticlesController.per_page: #{ArticlesController.per_page}"
puts "AdminGate.per_page: #{AdminGate.per_page}"
puts "included: #{ArticlesController.include?(AdminGate)}"
