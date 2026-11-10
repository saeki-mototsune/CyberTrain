require "cybertrain/test"
require "cybertrain/test/client"
require "cybertrain/router"
require "cybertrain/controller"
require "cybertrain/model"
require "cybertrain/job"
require "cybertrain/generator"
require_relative "fixtures/gen_app/config/routes"
# Controller concerns (spec 4.1, plan decisions 8, 11 and 12), on the
# fixture app loaded through its checked-in gen/app.rb: the concerns of
# app/controllers/concerns first, the application's classes, then
# gen/concerns.rb, which splices each concern's `included` body into the
# classes that include it and forwards its class_methods.
# GatedController: before_action :set_post, include AdminGate, include
# Auditing (which includes Stamped), before_action :log_visit;
# ApplicationController includes Stamped. Like test/gen_routes_compiles.rb,
# this program links SQLite through FFI: its snapshot comes from the
# compiled binary (script/regen-snapshot).
require_relative "fixtures/gen_app/gen/app"

FIXTURE = "test/fixtures/gen_app"

def client
  Cybertrain::Test::Client.new(Gen::Routes.build(Cybertrain::Router.new))
end

def concerns
  Cybertrain::Gen::ConcernScan.scan_dir("#{FIXTURE}/app/controllers")
end

def callback_names(klass)
  Cybertrain::Controller.chain_for(klass).map { |cb| cb.name.to_s }
end

def occurrences(text, part)
  n = 0
  pos = text.index(part)
  until pos.nil?
    n += 1
    pos = text.index(part, pos + part.size)
  end
  n
end

# A stale file is rewritten so that the next build (and run) picks it up.
test "the checked-in gen/concerns.rb is fresh" do
  source = Cybertrain::Gen::ConcernsEmitter.emit(Cybertrain::Gen::ControllerScan.scan_dir("#{FIXTURE}/app/controllers"), concerns)
  path = "#{FIXTURE}/gen/concerns.rb"
  current = File.exist?(path) ? File.read(path) : ""
  unless current == source
    File.write(path, source)
    flunk("fixture stale: #{path} (rewritten; rebuild and rerun)")
  end
end

test "before_action from a concern runs at the include's position" do
  assert_equal ["load_viewer", "stamp_response", "set_post", "require_admin", "audit", "log_visit"], callback_names(GatedController)
  res = client.get("/gated/1")
  assert_response res, :not_found
  assert_equal "Not Found", res.body
  assert_nil res.header("X-Visit")
  res = client.get("/gated/1", { "x-admin" => "1" })
  assert_response res, :ok
  assert_equal "gated 1 per_page=50 admin?=true audited_at=now", res.body
  assert_equal "logged", res.header("X-Visit")
  assert_equal "1", res.header("X-Stamped")
end

test "a concern's method overrides the superclass's of the same name" do
  # ApplicationController#require_admin (the jobs page's guard) redirects;
  # AdminGate's, included by GatedController, answers 404. The jobs page
  # keeps ApplicationController's.
  assert_redirected_to client.get("/admin/jobs"), "/"
  assert_response client.get("/gated/1"), :not_found
end

test "class_methods are callable through self.class" do
  assert_equal 50, GatedController.per_page
  assert_equal 50, AdminGate.per_page
  assert_includes client.get("/gated/7", { "x-admin" => "1" }).body, "per_page=50"
end

test "nested concerns expand depth first; a cycle is refused by name" do
  infos = concerns
  assert_equal ["AdminGate", "Auditing", "Stamped"], infos.map { |c| c.concern_name }
  assert_equal ["Stamped", "Auditing"], Cybertrain::Gen::ConcernScan.expand(["Auditing"], infos).map { |c| c.concern_name }
  assert_equal ["AdminGate", "Stamped", "Auditing"], Cybertrain::Gen::ConcernScan.expand(["AdminGate", "Auditing", "Stamped"], infos).map { |c| c.concern_name }
  a = Cybertrain::Gen::ConcernScan.scan_source("app/controllers/concerns/a.rb", "module A\n  extend ActiveSupport::Concern\n  include B\nend\n")
  b = Cybertrain::Gen::ConcernScan.scan_source("app/controllers/concerns/b.rb", "module B\n  extend ActiveSupport::Concern\n  include A\nend\n")
  msg = assert_raises("ArgumentError") { Cybertrain::Gen::ConcernScan.expand(["A"], [a, b]) }
  assert_equal "concern cycle: A includes B includes A", msg
end

test "a concern included by an ancestor and again is expanded once" do
  # ApplicationController includes Stamped; GatedController includes it
  # again through Auditing: the callback list holds it once, in
  # ApplicationController's position.
  names = callback_names(GatedController)
  assert_equal 1, names.select { |n| n == "stamp_response" }.size
  assert_equal ["load_viewer", "stamp_response", "set_post", "stamp"], callback_names(PostsController)
  generated = File.read("#{FIXTURE}/gen/concerns.rb")
  assert_equal 1, occurrences(generated, "after_action :stamp_response")
  # Posts, which include nothing, still get Stamped through their parent.
  assert_equal "1", client.get("/posts/5").header("X-Stamped")
end

test "@x in a concern method is a view assign of the includer" do
  ctx = Cybertrain::Context.new(Cybertrain::Request.new("GET", "/gated/1", {}, ""))
  assert_equal ["viewer", "post", "audited_at"], GatedController.new(ctx).view_assigns.keys
end

Cybertrain::Test.run!
