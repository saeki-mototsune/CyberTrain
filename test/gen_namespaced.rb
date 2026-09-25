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

FIXTURE = "test/fixtures/gen_namespaced"

def fixture_outputs
  {
    "gen/routes.rb" => Cybertrain::Gen::RoutesEmitter.emit(Cybertrain::Routes.specs),
    "gen/controllers.rb" => Cybertrain::Gen::ControllersEmitter.emit(Cybertrain::Gen::ControllerScan.scan_dir("#{FIXTURE}/app/controllers")),
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

Cybertrain::Test.run!
