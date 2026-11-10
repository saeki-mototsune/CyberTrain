require "cybertrain/test"
require "cybertrain/test/client"
require "cybertrain/router"
require "cybertrain/controller"
require "cybertrain/generator"
require_relative "fixtures/gen_namespaced/config/routes"
# A fixture app whose only controller is namespaced (Admin::UsersController),
# loaded through its checked-in gen/app.rb: gen/controllers.rb has to open
# `module Admin` itself, because it loads before app/controllers.
require_relative "fixtures/gen_namespaced/gen/app"

# cybertrain/controller pulls in cybertrain/model and the SQLite FFI bindings
# (through the template helpers), so this program no longer runs under CRuby:
# take its snapshot from the compiled binary, never `spin test --regen`
# (spikes/NOTES.md rule 23).

FIXTURE = "test/fixtures/gen_namespaced"

def fixture_outputs
  {
    "gen/routes.rb" => Cybertrain::Gen::RoutesEmitter.emit(Cybertrain::Routes.specs),
    "gen/controllers.rb" => Cybertrain::Gen::ControllersEmitter.emit(Cybertrain::Gen::ControllerScan.scan_dir("#{FIXTURE}/app/controllers")),
    "gen/helpers.rb" => Cybertrain::Gen::HelpersEmitter.emit(Cybertrain::Gen::HelperScan.scan_dir("#{FIXTURE}/app/helpers")),
    "gen/components.rb" => Cybertrain::Gen::ComponentsEmitter.emit(Cybertrain::Gen::ComponentScan.scan_dir("#{FIXTURE}/app/components")),
    "gen/console.rb" => Cybertrain::Gen::ConsoleEmitter.emit(Array.new(0) { "" }),
    "gen/jobs.rb" => Cybertrain::Gen::JobsEmitter.emit(Cybertrain::Gen::JobScan.scan_dir("#{FIXTURE}/app/jobs")),
    "gen/app.rb" => Cybertrain::Gen::Manifest.emit(FIXTURE)
  }
end

# A stale file is rewritten so that the next build (and run) picks it up.
test "the checked-in fixture output is fresh" do
  fixture_outputs.each do |rel, source|
    path = "#{FIXTURE}/#{rel}"
    next if File.read(path) == source

    File.write(path, source)
    flunk("fixture stale: #{path} (rewritten; rebuild and rerun)")
  end
end

test "gen/controllers.rb nests the namespaced class in its module" do
  assert_includes File.read("#{FIXTURE}/gen/controllers.rb"), "module Admin\n  class UsersController < ::ApplicationController\n"
end

test "a namespaced controller dispatches with its callbacks and ivars" do
  client = Cybertrain::Test::Client.new(Gen::Routes.build(Cybertrain::Router.new))
  res = client.get("/admin/users", { "x-viewer" => "root" })
  assert_response res, :ok
  assert_equal "admin users for root (admin) /admin/users", res.body
  ctx = Cybertrain::Context.new(Cybertrain::Request.new("GET", "/admin/users", {}, ""))
  controller = Admin::UsersController.new(ctx)
  assert_equal ["viewer", "role"], controller.view_assigns.keys
  assert_equal "Admin::UsersController", controller.class.name
end

test "namespace :admin with param: :login routes the member by login" do
  client = Cybertrain::Test::Client.new(Gen::Routes.build(Cybertrain::Router.new))
  res = client.get("/admin/users/ann")
  assert_response res, :ok
  assert_equal "admin user ann (admin) /admin/users/ann", res.body
  assert_equal "/admin/users/ann", Gen::Routes.path_for("admin_user_path", ["ann"])
  assert_equal "/admin/users/ann.json?tab=keys", Gen::Routes.path_for("admin_user_path", ["ann"], { "tab" => "keys", "format" => "json" })
  assert_includes File.read("#{FIXTURE}/gen/routes.rb"), "    def admin_user_path(user, options = {})\n"
end

Cybertrain::Test.run!
