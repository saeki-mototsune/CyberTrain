require "tmpdir"
require "cybertrain/cli"
require "cybertrain/test"

# `cybertrain generate authentication` on a fresh `cybertrain new` tree: the
# files it writes, the three edits it makes, and that a second run changes
# nothing. What the generated app does when compiled is CI's end-to-end
# step (ci.yml: sign up, sign in, the app's own test/authentication.rb).
TMP = Dir.mktmpdir("cybertrain-cli-authentication")
Dir.chdir(TMP)

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

ENV["CYBERTRAIN_TIMESTAMP"] = "20260925120000"
Cybertrain::CLI::NewApp.create("shop", "{ path = \"../cybertrain\" }")

def read(path)
  File.read(path)
end

AUTH_FILES = [
  "db/migrate/20260925120000_create_users.rb",
  "db/migrate/20260925120001_create_sessions.rb",
  "app/models/user.rb",
  "app/models/session.rb",
  "app/controllers/sessions_controller.rb",
  "app/controllers/registrations_controller.rb",
  "app/views/sessions/new.html.erb",
  "app/views/sessions/_nav.html.erb",
  "app/views/registrations/new.html.erb",
  "test/support/app_test.rb",
  "test/authentication.rb"
]

test "generate authentication writes the migrations, models, controllers, views and tests" do
  created = Cybertrain::CLI::Authentication.generate("shop")
  assert_equal AUTH_FILES, created
  AUTH_FILES.each { |f| assert(File.exist?("shop/#{f}"), "missing #{f}") }
end

test "the users migration has the two NOT NULL columns and a unique index" do
  assert_equal <<~RUBY, read("shop/db/migrate/20260925120000_create_users.rb")
    class CreateUsers < Cybertrain::Migration::Base
      def change
        create_table "users" do |t|
          t.string "email_address", null: false
          t.string "password_digest", null: false
          t.timestamps
        end
        add_index "users", ["email_address"], unique: true
      end
    end
  RUBY
  sessions = read("shop/db/migrate/20260925120001_create_sessions.rb")
  assert_includes sessions, "create_table \"sessions\" do |t|"
  assert_includes sessions, "      t.references :user\n"
  assert_includes sessions, "      t.string \"ip_address\"\n"
  assert_includes sessions, "      t.string \"user_agent\"\n"
end

test "the User model hashes with Cybertrain::Password and validates in before_validation" do
  model = read("shop/app/models/user.rb")
  assert_includes model, "class User\n"
  assert_includes model, "validates :email_address, presence: true"
  assert_includes model, "before_validation do |user|"
  assert_includes model, "def self.authenticate_by(email_address:, password:)"
  assert_includes model, "def password=(plain)"
  assert_includes model, "Cybertrain::Password.hash(text)"
  assert_includes model, "def authenticate(plain)"
  assert_includes model, "Cybertrain::Password.verify_serialized(plain.to_s, password_digest)"
  # An unknown address still costs one verification, against the dummy digest.
  assert_includes model, "Cybertrain::Password.verify_serialized(password.to_s, Cybertrain::Password.dummy_digest)"
  assert_includes model, "Cybertrain::Password.needs_rehash?(password_digest)"
  assert_includes model, "errors.add(:email_address, \"has already been taken\") if taken"
  assert_includes model, "errors.add(:password, \"can't be blank\")"
  assert_includes model, "is too short (minimum is \#{MIN_PASSWORD_LENGTH} characters)"
  assert_includes read("shop/app/models/session.rb"), "class Session\nend\n"
end

test "ApplicationController gets the before_actions and the sign-in helpers after its class line" do
  controller = read("shop/app/controllers/application_controller.rb")
  assert controller.start_with?("class ApplicationController < Cybertrain::Controller\n  # ---- Authentication"), controller
  assert_includes controller, "  before_action :resume_session\n  before_action :require_authentication\n"
  assert_includes controller, "  def self.allow_unauthenticated_access(only: [], except: [])\n    skip_before_action(:require_authentication, only: only, except: except)\n"
  ["authenticated?", "resume_session", "require_authentication", "start_new_session_for(user)",
   "terminate_session", "after_authentication_url"].each do |name|
    assert_includes controller, "  def #{name}\n"
  end
  assert_includes controller, "redirect_to new_session_path, status: :see_other"
  # The framework's primitives instead of hand-written checks: the safe
  # return path, the password key that ends older sessions on a password
  # change, the absolute lifetime restarted at sign-in.
  assert_includes controller, "    safe_redirect_path(session.delete(:return_to_after_authenticating), \"/\")\n"
  assert_includes controller, "session[:password_key] = Cybertrain::Password.session_key(user.password_digest)"
  assert_includes controller, "Cybertrain::Password.session_key_matches?(session[:password_key], user.password_digest)"
  assert_includes controller, "    session.restart_lifetime!\n"
  assert_includes controller, "lifetime = Cybertrain.config.session_absolute_max_age"

  # The address recorded is the client's, behind a trusted proxy too.
  assert_includes controller, "Session.create(user_id: user.id, ip_address: request.client_ip,"
  # The original body is intact below the inserted block.
  assert_includes controller, "  # ---- end of authentication"
  assert_includes controller, "\n  rescue_from Cybertrain::RecordNotFound, with: :record_not_found\n"
  assert_includes controller, "  def record_not_found\n"
  assert controller.end_with?("end\n")
  # One `private` only, the original one, after the public helpers.
  assert_equal 1, controller.scan("\nprivate\n").size + controller.scan("\n  private\n").size
end

test "the controllers open their sign-in actions and the views post to the routes" do
  sessions = read("shop/app/controllers/sessions_controller.rb")
  assert_includes sessions, "class SessionsController < ApplicationController\n  allow_unauthenticated_access only: [:new, :create]\n"
  assert_includes sessions, "def new_action\n"
  # Sign-in attempts are rate limited, as Rails' generator does.
  assert_includes sessions, "  rate_limit to: 10, within: 3 * 60, only: [:create],\n             redirect_to: \"/session/new\", alert: \"Try again later.\"\n"
  assert_includes sessions, "User.authenticate_by(email_address: params[:email_address].to_s, password: params[:password].to_s)"
  assert_includes sessions, "start_new_session_for(user)"
  assert_includes sessions, "terminate_session"
  registrations = read("shop/app/controllers/registrations_controller.rb")
  assert_includes registrations, "class RegistrationsController < ApplicationController\n  allow_unauthenticated_access only: [:new, :create]\n"
  assert_includes registrations, "@user = User.new(fields.permit(:email_address))"
  assert_includes registrations, "@user.password = fields[:password].to_s"
  assert_includes registrations, "render :new, status: :unprocessable_entity"

  sign_in = read("shop/app/views/sessions/new.html.erb")
  assert_includes sign_in, "<%= form_with(url: session_path) do |f| %>"
  assert_includes sign_in, "<%= f.email_field :email_address, autocomplete: \"username\", autofocus: true %>"
  assert_includes sign_in, "<%= f.password_field :password, autocomplete: \"current-password\" %>"
  assert_includes sign_in, "<%= link_to \"Sign up\", sign_up_path %>"
  sign_up = read("shop/app/views/registrations/new.html.erb")
  assert_includes sign_up, "<%= form_with(model: @user, url: sign_up_path) do |f| %>"
  assert_includes sign_up, "<% if @user.errors.any? %>"
  assert_includes sign_up, "<%= f.password_field :password_confirmation, autocomplete: \"new-password\" %>"
  nav = read("shop/app/views/sessions/_nav.html.erb")
  assert nav.start_with?("<%# locals: () %>\n")
  assert_includes nav, "<% if @current_user %>"
  assert_includes nav, "<%= button_to \"Sign out\", session_path, method: :delete %>"
end

test "the routes and the layout's nav are inserted" do
  assert_equal <<~RUBY, read("shop/config/routes.rb")
    Cybertrain::Routes.draw do
      resource :session, only: [:new, :create, :destroy]
      get "/sign_up", to: "registrations#new", as: "sign_up"
      post "/sign_up", to: "registrations#create"
    end
  RUBY
  layout = read("shop/app/views/layouts/application.html.erb")
  assert_includes layout, "    <main>\n      <%= render \"sessions/nav\" %>\n      <% if flash[:notice] %>"
end

test "the app's test boots the app and drives the sign-in flow" do
  support = read("shop/test/support/app_test.rb")
  assert_includes support, "ENV[\"CYBERTRAIN_ENV\"] = \"test\""
  assert_includes support, "module AppTest\n"
  assert_includes support, "APP = AppTest.boot\n"
  assert_includes support, "def self.sign_in(client"
  assert_includes support, "Cybertrain::RateLimit.reset_all!\n"
  spec = read("shop/test/authentication.rb")
  assert_includes spec, "require_relative \"support/app_test\""
  assert_includes spec, "client.post(\"/sign_up\""
  assert_includes spec, "test \"POST /session past ten attempts is refused for a while\" do\n"
  assert_includes spec, "Cybertrain::Test.run!\n"
end

test "running the generator again writes and edits nothing" do
  before = {}
  (AUTH_FILES + ["config/routes.rb", "app/controllers/application_controller.rb", "app/views/layouts/application.html.erb"]).each do |f|
    before[f] = read("shop/#{f}")
  end
  status = Dir.chdir("shop") { Cybertrain::CLI.run(["generate", "authentication"]) }
  assert_equal 0, status
  before.each { |f, content| assert_equal content, read("shop/#{f}") }
  assert_equal 2, Dir.children("shop/db/migrate").select { |f| f.end_with?(".rb") }.size
end

test "the generator runs after a scaffold, with migration versions that follow" do
  Cybertrain::CLI::NewApp.create("store", "{ path = \"../cybertrain\" }")
  Cybertrain::CLI::Scaffold.generate("store", "product", ["name:string"])
  created = Cybertrain::CLI::Authentication.generate("store")
  assert_includes created, "db/migrate/20260925120001_create_users.rb"
  assert_includes created, "db/migrate/20260925120002_create_sessions.rb"
  assert_equal <<~RUBY, read("store/config/routes.rb")
    Cybertrain::Routes.draw do
      resource :session, only: [:new, :create, :destroy]
      get "/sign_up", to: "registrations#new", as: "sign_up"
      post "/sign_up", to: "registrations#create"
      resources :products
    end
  RUBY
end

test "insert_after_line keeps the rest of the file" do
  out = Cybertrain::CLI::Authentication.insert_after_line("a\nb\nc\n", "b", "  x\n  y\n")
  assert_equal "a\nb\n  x\n  y\nc\n", out
  out = Cybertrain::CLI::Authentication.insert_after_line("a\nb", "b", "  x\n")
  assert_equal "a\nb\n  x\n", out
  message = assert_raises("InvalidArgument") { Cybertrain::CLI::Authentication.insert_after_line("a\n", "z", "x\n") }
  assert_includes message, "no `z` line"
end

test "a tree that is not an app, or whose ApplicationController was rewritten, is refused before anything is written" do
  assert_equal 1, Cybertrain::CLI.run(["generate", "authentication"])
  assert_equal 1, Cybertrain::CLI.run(["generate", "authentication", "extra"])
  assert_equal 1, Cybertrain::CLI.run(["generate", "passwords"])
  Cybertrain::CLI::NewApp.create("broken", "{ path = \"../cybertrain\" }")
  File.write("broken/app/controllers/application_controller.rb", "class ApplicationController < Base\nend\n")
  status = Dir.chdir("broken") { Cybertrain::CLI.run(["generate", "authentication"]) }
  assert_equal 1, status
  refute File.exist?("broken/app/models/user.rb")
  assert_equal ["db/migrate/.keep"].size, Dir.children("broken/db/migrate").size
  assert_equal "Cybertrain::Routes.draw do\nend\n", read("broken/config/routes.rb")
end

Cybertrain::Test.run!
