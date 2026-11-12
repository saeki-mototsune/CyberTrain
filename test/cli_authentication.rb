require "tmpdir"
require "cybertrain/cli"
require "cybertrain/test"
require "cybertrain/locales/bundled"

# `cybertrain generate authentication` on a fresh `cybertrain new` tree: the
# files it writes (the Authentication concern, the user command in both
# modes, every string through t()), the edits it makes, and that a second
# run changes nothing; the same for --invite-only (/setup, the boot
# warning, config/app.rb's setting). What the generated app does when
# compiled is script/auth-e2e's (CI's "Authentication end to end" step:
# build, the app's own test/*.rb, the binary served and probed).
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

# text with n spaces before each non-empty line (a method of a class, a
# field of a form).
def indented(text, n)
  out = +""
  text.each_line { |line| out << (line.strip.empty? ? line : "#{" " * n}#{line}") }
  out
end

AUTH_FILES = [
  "db/migrate/20260925120000_create_users.rb",
  "db/migrate/20260925120001_create_sessions.rb",
  "app/models/user.rb",
  "app/models/session.rb",
  "app/controllers/concerns/authentication.rb",
  "app/controllers/sessions_controller.rb",
  "app/controllers/registrations_controller.rb",
  "app/controllers/passwords_controller.rb",
  "app/controllers/accounts_controller.rb",
  "app/mailers/passwords_mailer.rb",
  "app/commands/user_command.rb",
  "app/views/sessions/new.html.erb",
  "app/views/sessions/_nav.html.erb",
  "app/views/registrations/new.html.erb",
  "app/views/passwords/new.html.erb",
  "app/views/passwords/edit.html.erb",
  "app/views/mail/_password_reset.html.erb",
  "app/views/accounts/edit.html.erb",
  "test/support/app_test.rb",
  "test/support/authentication_helpers.rb",
  "test/authentication.rb",
  "test/admin.rb",
  "test/remember_me.rb",
  "test/lockout.rb",
  "test/passwords.rb",
  "test/accounts.rb"
]

test "generate authentication writes the migrations, models, controllers, views and tests" do
  result = Cybertrain::CLI::Authentication.generate_with_result("shop")
  assert_equal AUTH_FILES, result.created
  assert_equal [], result.forced
  assert_equal [], result.manual
  AUTH_FILES.each { |f| assert(File.exist?("shop/#{f}"), "missing #{f}") }
end

test "the users migration has the NOT NULL columns, the admin flag, the lockout columns and a unique index" do
  assert_equal <<~RUBY, read("shop/db/migrate/20260925120000_create_users.rb")
    class CreateUsers < Cybertrain::Migration::Base
      def change
        create_table "users" do |t|
          t.string "email_address", null: false
          t.string "password_digest", null: false
          t.boolean "admin", null: false, default: "false"
          t.integer "failed_attempts", null: false, default: "0"
          t.datetime "locked_until"
          t.timestamps
        end
        add_index "users", ["email_address"], unique: true
      end
    end
  RUBY
  assert_equal <<~RUBY, read("shop/db/migrate/20260925120001_create_sessions.rb")
    class CreateSessions < Cybertrain::Migration::Base
      def change
        create_table "sessions" do |t|
          t.references :user
          t.string "ip_address"
          t.string "user_agent"
          t.boolean "remember", null: false, default: "false"
          t.datetime "last_active_at"
          t.timestamps
        end
      end
    end
  RUBY
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
  # The messages come from the dictionary of the current locale.
  assert_includes model, "errors.add(:email_address, I18n.error_message(\"user\", :email_address, :taken)) if taken\n"
  assert_includes model, "errors.add(:password, I18n.error_message(\"user\", :password, :blank))\n"
  assert_includes model, "errors.add(:password, I18n.error_message(\"user\", :password, :too_short, { count: MIN_PASSWORD_LENGTH }))\n"
  assert_includes model, "attribute = I18n.human_attribute_name(\"user\", :password)\n"
  assert_includes model, "errors.add(:password_confirmation, I18n.error_message(\"user\", :password_confirmation, :confirmation, { attribute: attribute }))\n"
  assert model.index("errors.add(:password, \"").nil?
  # The admin flag, which require_admin asks for.
  assert_includes model, "  def admin? = admin\n"
  # Lockout (D17): a locked account costs the dummy verification and
  # answers nil, as a wrong password does; a wrong password is counted in
  # the database, the attempt that reaches the limit locks; the right one
  # clears the count.
  assert_includes model, indented(<<~RUBY, 2)
      def self.authenticate_by(email_address:, password:)
        user = User.find_by(email_address: User.normalize_email_address(email_address))
        if user.nil? || (Cybertrain.config.auth_lockout_attempts > 0 && user.locked?)
          Cybertrain::Password.verify_serialized(password.to_s, Cybertrain::Password.dummy_digest)
          return nil
        end
        unless user.authenticate(password)
          user.count_failed_attempt!
          return nil
        end
        user.clear_failed_attempts!
        user
      end
  RUBY
  assert_includes model, "  def locked? = !locked_until.nil? && locked_until > Time.now\n"
  # One write per failed attempt (I2): no separate increment and lock.
  assert model.index(".increment(").nil?
  assert_equal 1, model.scan("update_all_sql(").size
  assert_includes model, indented(<<~RUBY, 2)
      def count_failed_attempt!
        limit = Cybertrain.config.auth_lockout_attempts
        return nil if limit <= 0

        count = "failed_attempts = CASE WHEN failed_attempts + 1 >= ? THEN 0 ELSE failed_attempts + 1 END"
        lock = "locked_until = CASE WHEN failed_attempts + 1 >= ? THEN ? ELSE locked_until END"
        ends = Time.now + Cybertrain.config.auth_lockout_period
        User.where(id: id).update_all_sql(count + ", " + lock, [limit, limit, ends])
        nil
      end
  RUBY
  assert_includes model, indented(<<~RUBY, 2)
      def clear_failed_attempts!
        return nil if failed_attempts == 0 && locked_until.nil?

        update_columns(failed_attempts: 0, locked_until: nil)
        nil
      end
  RUBY
  assert_includes read("shop/app/models/session.rb"), "class Session\nend\n"
end

test "writes the Authentication concern and includes it" do
  assert_equal <<~RUBY, read("shop/app/controllers/concerns/authentication.rb")
    # Sign-in for the whole application (cybertrain generate authentication),
    # as Rails 8's generator writes it: ApplicationController includes it, so
    # every action needs a signed-in user unless its controller opens it with
    # `allow_unauthenticated_access only: [:new, :create]`. resume_session
    # sets @current_user (and @current_session), which templates can read;
    # require_admin guards the pages only admins may see.
    #
    # Written by the generator; it is yours to change.
    module Authentication
      extend ActiveSupport::Concern

      included do
        before_action :resume_session
        before_action :require_authentication
        helper_method :authenticated?
      end

      private

      # Whether this request has a signed-in user.
      def authenticated?
        !@current_user.nil?
      end

      # Loads the Session row the cookie names (and its user); an id with no
      # row is dropped, and an expired row is ended (destroyed, so no later
      # change of the limits revives it). Cookie Max-Age alone cannot stop
      # replay, so the row's own limits end a sign-in: session_limit(remember) seconds
      # after it started (SessionStore enforces the same on the cookie,
      # from the stamp start_new_session_for writes), and auth_idle_timeout
      # seconds (0: no limit) after its last request (last_active_at, or
      # created_at while it has none). A request touches last_active_at at
      # most once a minute. A cookie whose password key no longer matches
      # (the password changed since it signed in) ends its Session row.
      def resume_session
        @current_session = nil
        @current_user = nil
        id = session[:session_id]
        return nil if id.nil? || id.empty? || id.size > 18

        found = Session.find_by(id: id.to_i)
        if found.nil?
          session.delete(:session_id)
          return nil
        end
        created_at = found.created_at
        now = Time.now.to_i
        if created_at.nil? || created_at.to_i + session_limit(found.remember) <= now
          found.destroy
          session.delete(:session_id)
          return nil
        end
        last_active_at = found.last_active_at
        active = last_active_at.nil? ? created_at.to_i : last_active_at.to_i
        idle = Cybertrain.config.auth_idle_timeout
        if idle > 0 && active + idle <= now
          found.destroy
          session.delete(:session_id)
          return nil
        end
        user = found.user
        if user.nil? || !Cybertrain::Password.session_key_matches?(session[:password_key], user.password_digest)
          found.destroy
          session.delete(:session_id)
          return nil
        end
        found.update_columns(last_active_at: Time.now) if now - active >= 60
        @current_session = found
        @current_user = user
        nil
      end

      # Sends a visitor to the sign-in page, remembering a GET to come back to.
      def require_authentication
        return nil if authenticated?

        session[:return_to_after_authenticating] = request.path if request.method == "GET"
        redirect_to new_session_path, status: :see_other
        nil
      end

      # The before_action of the pages only admins may see: anyone but a
      # signed-in admin gets a 404, as if there were no such page. The user
      # command makes a user an admin (`user admin EMAIL`,
      # app/commands/user_command.rb). The jobs page (config/routes.rb)
      # names it with `skip_before_action: :require_authentication`, so it
      # runs alone there and a visitor gets the 404 too; in a controller
      # that declares `before_action :require_admin` itself,
      # require_authentication runs first and sends a visitor to sign in.
      def require_admin
        render plain: "Not Found", status: :not_found unless @current_user && @current_user.admin?
        nil
      end

      # Signs user in: a Session row (remembered or not, active now), its
      # id and the password key resume_session compares in the cookie, and
      # the cookie's lifetime, restarted and then stamped in that order (a
      # restart clears the stamp): session_limit(remember) seconds, with a
      # Max-Age when remembered ("keep me signed in"), else a cookie the
      # browser drops when it closes. After a password change, call
      # `session[:password_key] = Cybertrain::Password.session_key(user.password_digest)`
      # to keep the browser that changed it signed in.
      def start_new_session_for(user, remember: false)
        started = Session.create(user_id: user.id, ip_address: request.client_ip,
                                 user_agent: request.header("user-agent").to_s,
                                 remember: remember, last_active_at: Time.now)
        session.restart_lifetime!
        session.stamp_lifetime!(session_limit(remember), remember)
        session[:session_id] = started.id
        session[:password_key] = Cybertrain::Password.session_key(user.password_digest)
        @current_session = started
        @current_user = user
        nil
      end

      # How long a sign-in lasts in seconds, however often it is used:
      # auth_remember_for when remembered, else (or when that is not
      # positive) session_absolute_max_age, or with that off (0)
      # session_max_age, or two weeks when that is not positive either.
      # Never 0: a stamp of 0 would leave the cookie with no limit at all.
      def session_limit(remember)
        c = Cybertrain.config
        return c.auth_remember_for if remember && c.auth_remember_for > 0
        return c.session_absolute_max_age if c.session_absolute_max_age > 0
        return c.session_max_age if c.session_max_age > 0

        1_209_600
      end

      # Deletes the Session row and empties the cookie session (the CSRF
      # token with it, so forms rendered before no longer submit).
      def terminate_session
        current = @current_session
        current.destroy unless current.nil?
        session.clear
        @current_session = nil
        @current_user = nil
        nil
      end

      # Where to go after signing in: the page that asked for it, if it is a
      # local path (Cybertrain::Controller#safe_redirect_path), or /.
      def after_authentication_url
        safe_redirect_path(session.delete(:return_to_after_authenticating), "/")
      end

      # Where links in mails start ("https://shop.example.com"): the base_url
      # setting (SHOP_BASE_URL, config/app.rb) when set; else the address this
      # request came to, but only where the Host header is known to be
      # safe: the Host is checked (development, or CYBERTRAIN_HOSTS lists
      # the hosts the app answers to, so any other Host is refused before
      # an action runs), or the app runs its tests. In any other
      # environment (production, staging, ...) "" and an [ERROR] line: the
      # mail named `mail` is not sent, as a link built from a Host header
      # anyone can forge would carry its token to their site.
      def mail_link_base(mail)
        c = Cybertrain.config
        configured = c.string_setting(:base_url)
        return configured.delete_suffix("/") unless configured.empty?
        return request.base_url if c.host_check? || c.test?

        Cybertrain.logger.error("\#{mail} mail not sent: set SHOP_BASE_URL (or CYBERTRAIN_HOSTS)")
        ""
      end
    end
  RUBY
  # Included right after the class line; the rest of the file is as
  # `cybertrain new` wrote it.
  assert_equal <<~RUBY, read("shop/app/controllers/application_controller.rb")
    class ApplicationController < Cybertrain::Controller
      include Authentication

      rescue_from Cybertrain::RecordNotFound, with: :record_not_found

      private

      def record_not_found
        render plain: "Not Found", status: :not_found
      end
    end
  RUBY
end

test "only an include Authentication line counts, not a comment or another module" do
  Cybertrain::CLI::NewApp.create("commented", "{ path = \"../cybertrain\" }")
  controller = "commented/app/controllers/application_controller.rb"
  routes = "commented/config/routes.rb"
  original = read(controller)
  ["  # include Authentication\n", "  include AuthenticationHelpers\n"].each do |line|
    File.write(controller, original.sub("Cybertrain::Controller\n", "Cybertrain::Controller\n#{line}"))
    assert_equal false, Cybertrain::CLI::Authentication.included?(read(controller))
    assert_equal false, Cybertrain::CLI::Authentication.enable_jobs_page(routes, controller)
    assert_includes read(routes), "  # jobs_page \"/admin/jobs\""
    assert_equal true, Cybertrain::CLI::Authentication.add_to_application_controller(controller)
    assert read(controller).start_with?("class ApplicationController < Cybertrain::Controller\n  include Authentication\n\n#{line}"), read(controller)
    assert_equal true, Cybertrain::CLI::Authentication.included?(read(controller))
  end
  assert_equal true, Cybertrain::CLI::Authentication.included?("class A < B\n  include Authentication\nend\n")
  assert_equal true, Cybertrain::CLI::Authentication.included?("class A < B\n  include Authentication # here\nend\n")
  assert_equal false, Cybertrain::CLI::Authentication.included?("class A < B\n  include Authentication::X\nend\n")
end

test "ApplicationController that already defines require_authentication (0.4's block) is left alone" do
  Cybertrain::CLI::NewApp.create("legacy", "{ path = \"../cybertrain\" }")
  legacy = "class ApplicationController < Cybertrain::Controller\n  before_action :require_authentication\n\n  def require_authentication\n  end\nend\n"
  File.write("legacy/app/controllers/application_controller.rb", legacy)
  assert_equal false, Cybertrain::CLI::Authentication.add_to_application_controller("legacy/app/controllers/application_controller.rb")
  assert_equal legacy, read("legacy/app/controllers/application_controller.rb")
  # Without require_admin in ApplicationController, the jobs page stays a comment.
  assert_equal false, Cybertrain::CLI::Authentication.enable_jobs_page("legacy/config/routes.rb", "legacy/app/controllers/application_controller.rb")
  assert_equal "Cybertrain::Routes.draw do\n  # jobs_page \"/admin/jobs\", before_action: :require_admin\nend\n", read("legacy/config/routes.rb")
  # Once it includes the concern, the jobs page is drawn behind require_admin.
  File.write("legacy/app/controllers/application_controller.rb", "class ApplicationController < Cybertrain::Controller\n  include Authentication\nend\n")
  assert_equal true, Cybertrain::CLI::Authentication.enable_jobs_page("legacy/config/routes.rb", "legacy/app/controllers/application_controller.rb")
  assert_equal "Cybertrain::Routes.draw do\n  jobs_page \"/admin/jobs\", before_action: :require_admin, skip_before_action: :require_authentication\nend\n", read("legacy/config/routes.rb")
  assert_equal false, Cybertrain::CLI::Authentication.enable_jobs_page("legacy/config/routes.rb", "legacy/app/controllers/application_controller.rb")
  # The explicit line commented out is drawn the same; a line with other
  # options, or an already drawn page without the skip, is left alone.
  File.write("legacy/config/routes.rb", "Cybertrain::Routes.draw do\n    # jobs_page \"/admin/jobs\", before_action: :require_admin, skip_before_action: :require_authentication\nend\n")
  assert_equal true, Cybertrain::CLI::Authentication.enable_jobs_page("legacy/config/routes.rb", "legacy/app/controllers/application_controller.rb")
  assert_equal "Cybertrain::Routes.draw do\n    jobs_page \"/admin/jobs\", before_action: :require_admin, skip_before_action: :require_authentication\nend\n", read("legacy/config/routes.rb")
  ["  # jobs_page \"/admin/jobs\", before_action: :require_staff\n", "  jobs_page \"/admin/jobs\", before_action: :require_admin\n"].each do |line|
    File.write("legacy/config/routes.rb", "Cybertrain::Routes.draw do\n#{line}end\n")
    assert_equal false, Cybertrain::CLI::Authentication.enable_jobs_page("legacy/config/routes.rb", "legacy/app/controllers/application_controller.rb")
    assert_equal "Cybertrain::Routes.draw do\n#{line}end\n", read("legacy/config/routes.rb")
  end
end

test "the controllers open their sign-in actions and the views post to the routes" do
  sessions = read("shop/app/controllers/sessions_controller.rb")
  assert_includes sessions, "class SessionsController < ApplicationController\n  allow_unauthenticated_access only: [:new, :create]\n"
  assert_includes sessions, "def new_action\n"
  # Sign-in attempts are rate limited, as Rails' generator does; the
  # exhausted client gets rate_limited's answer.
  assert_includes sessions, "  rate_limit to: 10, within: 3 * 60, only: [:create], with: :rate_limited\n"
  assert_includes sessions, "User.authenticate_by(email_address: params[:email_address].to_s, password: params[:password].to_s)"
  # "Keep me signed in" is the box's "1".
  assert_includes sessions, "      start_new_session_for(user, remember: params[:remember_me] == \"1\")\n"
  assert_includes sessions, "terminate_session"
  assert_includes sessions, "      flash[:alert] = t(\".invalid\")\n"
  assert_includes sessions, "    flash[:notice] = t(\".signed_out\")\n"
  # A private method: its key is absolute, the action it runs in being create.
  assert_includes sessions, "  private\n\n"
  assert_includes sessions, "  def rate_limited\n    flash[:alert] = t(\"sessions.create.rate_limited\")\n    redirect_to new_session_path, status: :see_other\n    nil\n  end\n"
  registrations = read("shop/app/controllers/registrations_controller.rb")
  assert_includes registrations, "class RegistrationsController < ApplicationController\n  allow_unauthenticated_access only: [:new, :create]\n"
  assert_includes registrations, "@user = User.new(fields.permit(:email_address))"
  assert_includes registrations, "@user.password = fields[:password].to_s"
  assert_includes registrations, "render :new, status: :unprocessable_entity"
  assert_includes registrations, "      flash[:notice] = t(\".welcome\")\n"
  assert_includes registrations, "      start_new_session_for(@user)\n"

  sign_in = read("shop/app/views/sessions/new.html.erb")
  assert_includes sign_in, "<%= form_with(url: session_path) do |f| %>"
  assert_includes sign_in, "<%= f.email_field :email_address, autocomplete: \"username\", autofocus: true %>"
  assert_includes sign_in, "<%= f.password_field :password, autocomplete: \"current-password\" %>"
  assert_includes sign_in, "<h1><%= t(\".title\") %></h1>\n"
  assert_includes sign_in, "<%= f.label :email_address, t(\".email_address\") %>"
  assert_includes sign_in, "<%= f.submit t(\".submit\") %>"
  assert_includes sign_in, indented(<<~ERB, 2)
      <div class="field">
        <%= check_box_tag :remember_me %>
        <%= label_tag :remember_me, t(".remember_me") %>
      </div>

      <div class="actions">
  ERB
  assert sign_in.end_with?("<% end %>\n\n<p><%= link_to t(\".forgot_password\"), new_password_path %></p>\n" \
                           "<p><%= link_to t(\".sign_up\"), sign_up_path %></p>\n"), sign_in
  sign_up = read("shop/app/views/registrations/new.html.erb")
  assert_includes sign_up, "<%= form_with(model: @user, url: sign_up_path) do |f| %>"
  assert_includes sign_up, "<% if @user.errors.any? %>"
  # The error header is rails-i18n's errors.template.header, by count.
  assert_includes sign_up, "<h2><%= t(\"errors.template.header\", count: @user.errors.count, model: t(\".model\")) %></h2>\n"
  assert sign_up.index("pluralize").nil?
  assert_includes sign_up, "<%= f.password_field :password_confirmation, autocomplete: \"new-password\" %>"
  nav = read("shop/app/views/sessions/_nav.html.erb")
  assert nav.start_with?("<%# locals: () %>\n")
  assert_includes nav, "<% if @current_user %>"
  assert_includes nav, "<%= button_to t(\".sign_out\"), session_path, method: :delete %>"
  # The account page, for a signed-in user only.
  assert_includes nav, "    <span><%= @current_user.email_address %></span>\n    <%= link_to t(\".account\"), edit_account_path %>\n" \
                       "    <%= button_to t(\".sign_out\"), session_path, method: :delete %>\n  <% else %>\n"
  assert_includes nav, "<%= link_to t(\".sign_in\"), new_session_path %>"
end

# Every file under dir, as paths from dir ("controllers/x.rb"), sorted.
def tree_files(dir, prefix = "")
  out = Array.new(0) { "" }
  Dir.children(dir).sort.each do |name|
    path = File.join(dir, name)
    rel = prefix.empty? ? name : "#{prefix}/#{name}"
    if File.directory?(path)
      tree_files(path, rel).each { |f| out << f }
    else
      out << rel
    end
  end
  out
end

# The text of an ERB file outside its tags (`<%...%>`, then `<...>`), one
# String per run between tags, stripped; empty runs are left out.
def text_nodes(erb)
  plain = +""
  at = 0
  while at < erb.size
    open = erb.index("<%", at)
    if open.nil?
      plain << erb[at, erb.size - at].to_s
      break
    end
    plain << erb[at, open - at].to_s
    close = erb.index("%>", open)
    at = close.nil? ? erb.size : close + 2
  end
  nodes = Array.new(0) { "" }
  run = +""
  in_tag = false
  plain.each_char do |c|
    if c == "<"
      nodes << run.strip unless run.strip.empty?
      run = +""
      in_tag = true
    elsif c == ">"
      in_tag = false
    elsif !in_tag
      run << c
    end
  end
  nodes << run.strip unless run.strip.empty?
  nodes
end

# Whether text starts with a capital letter: words a person reads, which
# t() should give (keys, paths, partial names and HTML values are lower
# case).
def capitalized?(text)
  !text.empty? && text[0] >= "A" && text[0] <= "Z"
end

# The "..." and '...' literals in a piece of code, in order (a backslash
# escapes the next character).
def quoted_literals(code)
  found = Array.new(0) { "" }
  at = 0
  while at < code.size
    quote = code[at]
    if quote == "\"" || quote == "'"
      literal = +""
      at += 1
      while at < code.size && code[at] != quote
        if code[at] == "\\"
          at += 1
          literal << code[at].to_s
        else
          literal << code[at]
        end
        at += 1
      end
      found << literal
    end
    at += 1
  end
  found
end

# The Ruby code of each ERB tag (`<%= x %>`, `<% x %>`); comments
# (`<%# ... %>`) are left out.
def erb_code(erb)
  found = Array.new(0) { "" }
  at = 0
  loop do
    open = erb.index("<%", at)
    break if open.nil?

    close = erb.index("%>", open)
    break if close.nil?

    code = erb[open + 2, close - open - 2].to_s
    found << code unless code.start_with?("#")
    at = close + 2
  end
  found
end

# The HTML tags of an ERB file (`input type="hidden" name="token"`), its
# ERB tags taken out first.
def html_tags(erb)
  plain = +""
  at = 0
  while at < erb.size
    open = erb.index("<%", at)
    if open.nil?
      plain << erb[at, erb.size - at].to_s
      break
    end
    plain << erb[at, open - at].to_s
    close = erb.index("%>", open)
    at = close.nil? ? erb.size : close + 2
  end
  tags = Array.new(0) { "" }
  at = 0
  loop do
    open = plain.index("<", at)
    break if open.nil?

    close = plain.index(">", open)
    break if close.nil?

    tags << plain[open + 1, close - open - 1].to_s
    at = close + 1
  end
  tags
end

# What a view shows that does not come from t(): a text node, a string
# literal inside an ERB tag (`f.submit "Sign in"`, `link_to 'Sign up', x`,
# `f.label :x, "Email"`) or an attribute value (`placeholder="Email"`,
# `title=`, `alt=`, `aria-label=`) that starts with a capital letter.
def erb_problems(erb)
  found = Array.new(0) { "" }
  text_nodes(erb).each { |node| found << "text #{node}" if capitalized?(node) }
  erb_code(erb).each do |code|
    quoted_literals(code).each { |literal| found << "literal #{literal}" if capitalized?(literal) }
  end
  html_tags(erb).each do |tag|
    quoted_literals(tag).each { |value| found << "attribute #{value}" if capitalized?(value) }
  end
  found
end

# What a controller or mailer says that does not come from t(): a
# `notice:`, `alert:` or `subject:` literal, or a literal stored into the
# flash (`flash[:x] = "..."`, `flash.now[:x] = '...'`). Comment lines are
# left out.
def ruby_problems(source)
  found = Array.new(0) { "" }
  source.each_line do |line|
    code = line.strip
    next if code.start_with?("#")

    ["notice: ", "alert: ", "subject: "].each do |key|
      ["\"", "'"].each do |quote|
        found << "#{key}#{quote}" unless code.index("#{key}#{quote}").nil?
      end
    end
    next if code.index("flash").nil?

    ["] = \"", "] = '"].each do |assign|
      found << "flash#{assign}" unless code.index(assign).nil?
    end
  end
  found
end

# Every view (layouts aside) and every controller, concern and mailer of
# the app, with what erb_problems / ruby_problems find in it.
def untranslated(app)
  found = Array.new(0) { "" }
  tree_files("#{app}/app/views").each do |f|
    next if f.start_with?("layouts/") || !f.end_with?(".erb")

    erb_problems(read("#{app}/app/views/#{f}")).each { |problem| found << "#{f}: #{problem}" }
  end
  ["controllers", "mailers"].each do |dir|
    next unless File.directory?("#{app}/app/#{dir}")

    tree_files("#{app}/app/#{dir}").each do |f|
      next unless f.end_with?(".rb")

      ruby_problems(read("#{app}/app/#{dir}/#{f}")).each { |problem| found << "#{dir}/#{f}: #{problem}" }
    end
  end
  found
end

test "every view and flash string goes through t" do
  assert_equal [], untranslated("shop")
  # The scanner sees what it is meant to: text nodes...
  assert_equal ["Sign in", "Hi"], text_nodes("<%# locals: () %>\n<h1>Sign in</h1>\n<p class=\"x\"><%= t(\".a\") %> Hi</p><input value=\"<%= x %>\">")
  # ...English passed to helpers inside ERB tags, double or single quoted...
  assert_equal ["literal Sign in"], erb_problems("<div class=\"actions\">\n  <%= f.submit \"Sign in\" %>\n</div>\n")
  assert_equal ["literal Sign up"], erb_problems("<p><%= link_to 'Sign up', sign_up_path %></p>")
  assert_equal ["literal Email"], erb_problems("<%= f.label :email_address, \"Email\" %>")
  assert_equal ["literal Don't"], erb_problems("<%= button_to \"Don\\'t\", x %>")
  # ...English attribute values...
  assert_equal ["attribute Email", "attribute Close", "attribute A cat", "attribute Menu"],
               erb_problems("<input placeholder=\"Email\" title='Close'><img alt=\"A cat\" src=\"/c.png\"><nav aria-label=\"Menu\">")
  # ...but not keys, options, paths, comments or values from ERB.
  assert_equal [], erb_problems("<%# Sign in %>\n<h1><%= t(\".title\") %></h1>\n<%= f.email_field :email_address, autocomplete: \"username\" %>\n" \
                                "<%= render \"sessions/nav\" %><input type=\"hidden\" name=\"token\" value=\"<%= @setup_token %>\">")
  # Controllers and mailers: notice:, alert:, subject: and flash literals.
  assert_equal ["notice: '"], ruby_problems("    redirect_to x, notice: 'Saved'\n")
  assert_equal ["alert: \""], ruby_problems("    redirect_to x, alert: \"No\"\n")
  assert_equal ["subject: \""], ruby_problems("    Cybertrain::MailMessage.new(to: a, subject: \"Reset your password\", body: b)\n")
  assert_equal ["flash] = \"", "flash] = '"], ruby_problems("  flash[:notice] = \"Hi\"\n  flash.now[:alert] = 'No'\n")
  assert_equal [], ruby_problems("  # flash[:notice] = \"Hi\"\n  flash[:notice] = t(\".welcome\")\n  subject: I18n.t(\"x.subject\")\n")
  # A whole app with one such view fails the check.
  Dir.mkdir("shop/app/views/probes")
  File.write("shop/app/views/probes/new.html.erb", "<%= form_with(url: x) do |f| %>\n  <%= f.submit \"Sign in\" %>\n<% end %>\n")
  assert_equal ["probes/new.html.erb: literal Sign in"], untranslated("shop")
  File.delete("shop/app/views/probes/new.html.erb")
  Dir.rmdir("shop/app/views/probes")
  assert_equal [], untranslated("shop")
end

# Where a lazy key ("." first) of a view resolves (D8): the template's
# path, a partial's leading "_" dropped (sessions/_nav.html.erb ->
# sessions.nav).
def view_scope(path)
  slash = path.rindex("/")
  dir = path[0, slash].to_s.tr("/", ".")
  base = path[slash + 1, path.size - slash - 1].to_s
  base = base[1, base.size - 1].to_s if base.start_with?("_")
  dot = base.index(".")
  base = base[0, dot].to_s unless dot.nil?
  "#{dir}.#{base}"
end

# Every `t("...")` in source, in order, as "<offset>:<key as written>".
def t_calls(source)
  calls = Array.new(0) { "" }
  at = 0
  loop do
    found = source.index("t(\"", at)
    break if found.nil?

    before = found > 0 ? source[found - 1] : " "
    stop = source.index("\"", found + 3)
    break if stop.nil?

    word = (before >= "a" && before <= "z") || (before >= "A" && before <= "Z") || (before >= "0" && before <= "9") || before == "_"
    calls << "#{found}:#{source[found + 3, stop - found - 3]}" unless word
    at = stop + 1
  end
  calls
end

# Every key the generated app/** looks up, lazy keys resolved: a view's
# by its path; a controller's by the action whose `def` encloses the call
# (new_action is the new action), and refused after `private`, where no
# action name holds (F12: those use absolute keys).
def used_keys(app)
  keys = Array.new(0) { "" }
  tree_files("#{app}/app/views").each do |f|
    t_calls(read("#{app}/app/views/#{f}")).each do |call|
      colon = call.index(":")
      key = call[colon + 1, call.size - colon - 1].to_s
      keys << (key.start_with?(".") ? "#{view_scope(f)}#{key}" : key)
    end
  end
  tree_files("#{app}/app").each do |f|
    next unless f.end_with?(".rb") && !f.start_with?("views/")

    source = read("#{app}/app/#{f}")
    controller = f.start_with?("controllers/") && f.end_with?("_controller.rb") ? f.delete_prefix("controllers/").delete_suffix("_controller.rb").tr("/", ".") : ""
    t_calls(source).each do |call|
      colon = call.index(":")
      offset = call[0, colon].to_i
      key = call[colon + 1, call.size - colon - 1].to_s
      unless key.start_with?(".")
        keys << key
        next
      end
      head = source[0, offset].to_s
      def_at = head.rindex("\n  def ")
      private_at = head.rindex("\n  private\n")
      if controller.empty? || def_at.nil? || !private_at.nil?
        keys << "lazy key outside an action in #{f}: #{key}"
        next
      end
      name_end = head.index("\n", def_at + 1)
      name = head[def_at + 7, name_end - def_at - 7].to_s
      paren = name.index("(")
      name = name[0, paren].to_s unless paren.nil?
      keys << "#{controller}.#{name.delete_suffix("_action")}#{key}"
    end
  end
  keys.uniq.sort
end

# A bundled text at key, or the `other` form of a plural one
# (errors.template.header is one/other in en).
def bundled(locale, key)
  text = Cybertrain::BundledLocales.lookup("#{locale}.#{key}")
  text = Cybertrain::BundledLocales.lookup("#{locale}.#{key}.other") if text.nil?
  text
end

# The password reset's keys (Task 13), in both modes: its form labels are
# the User model's attribute names.
RESET_KEYS = ["activerecord.attributes.user.email_address", "activerecord.attributes.user.password",
              "activerecord.attributes.user.password_confirmation"]
RESET_TAIL_KEYS = ["mail.password_reset.greeting", "mail.password_reset.ignore", "mail.password_reset.intro",
                   "mail.password_reset.link",
                   "passwords.create.rate_limited", "passwords.create.sent", "passwords.edit.invalid",
                   "passwords.edit.submit", "passwords.edit.title", "passwords.new.sign_in", "passwords.new.submit",
                   "passwords.new.title", "passwords.update.updated", "passwords_mailer.reset.subject"]
# The account page's keys (Task 14), in both modes.
ACCOUNT_KEYS = ["accounts.destroy.deleted", "accounts.destroy.wrong_password", "accounts.edit.delete",
                "accounts.edit.delete_intro", "accounts.edit.delete_title", "accounts.edit.model",
                "accounts.edit.new_password", "accounts.edit.password_hint", "accounts.edit.submit",
                "accounts.edit.title", "accounts.update.rate_limited", "accounts.update.updated",
                "accounts.update.wrong_password", "activerecord.attributes.user.current_password"]
SHOP_KEYS = (ACCOUNT_KEYS + RESET_KEYS).sort + ["errors.template.header"] + RESET_TAIL_KEYS +
            ["registrations.create.welcome", "registrations.new.model", "registrations.new.sign_in",
             "registrations.new.submit", "registrations.new.title",
             "sessions.create.invalid", "sessions.create.rate_limited", "sessions.destroy.signed_out",
             "sessions.nav.account", "sessions.nav.sign_in", "sessions.nav.sign_out",
             "sessions.new.email_address", "sessions.new.forgot_password", "sessions.new.password", "sessions.new.remember_me",
             "sessions.new.sign_up", "sessions.new.submit", "sessions.new.title"]

test "every key the generated files use exists in the bundled en and ja dictionaries" do
  assert_equal SHOP_KEYS, used_keys("shop")
  SHOP_KEYS.each do |key|
    refute bundled("en", key).nil?, "en.#{key}"
    refute bundled("ja", key).nil?, "ja.#{key}"
  end
  assert_equal "Sign in", bundled("en", "sessions.new.title")
  assert_equal "ログイン", bundled("ja", "sessions.new.title")
  assert_equal "Try another email address or password.", bundled("en", "sessions.create.invalid")
  assert_equal "Try again later.", bundled("en", "sessions.create.rate_limited")
  assert_equal "Keep me signed in", bundled("en", "sessions.new.remember_me")
  assert_equal "ログインしたままにする", bundled("ja", "sessions.new.remember_me")
  assert_equal "You have been signed out.", bundled("en", "sessions.destroy.signed_out")
  assert_equal "Welcome! You have signed up.", bundled("en", "registrations.create.welcome")
  # The reset's texts (D16's answer is the same for any address).
  assert_equal "If that address is registered, a link to reset the password was sent to it.", bundled("en", "passwords.create.sent")
  assert_equal "そのメールアドレスが登録されていれば、パスワードを再設定するリンクを送りました。", bundled("ja", "passwords.create.sent")
  assert_equal "Reset your password", bundled("en", "passwords_mailer.reset.subject")
  assert_equal "パスワードの再設定", bundled("ja", "passwords_mailer.reset.subject")
  assert_equal "Forgot your password?", bundled("en", "sessions.new.forgot_password")
  assert_equal "That password reset link is invalid or has expired.", bundled("en", "passwords.edit.invalid")
  assert_equal "Your password has been reset. Sign in with the new one.", bundled("en", "passwords.update.updated")
  assert_equal "Hello %{email_address},", bundled("en", "mail.password_reset.greeting")
  assert_equal "Try again later.", bundled("en", "passwords.create.rate_limited")
  # The form labels of User come from activerecord.attributes.user.
  assert_equal "Email address", bundled("en", "activerecord.attributes.user.email_address")
  assert_equal "メールアドレス", bundled("ja", "activerecord.attributes.user.email_address")
  assert_equal "パスワード（確認用）", bundled("ja", "activerecord.attributes.user.password_confirmation")
  # The account page's texts.
  assert_equal "Account", bundled("en", "accounts.edit.title")
  assert_equal "アカウント", bundled("ja", "accounts.edit.title")
  assert_equal "Account", bundled("en", "sessions.nav.account")
  assert_equal "アカウント", bundled("ja", "sessions.nav.account")
  assert_equal "Current password", bundled("en", "activerecord.attributes.user.current_password")
  assert_equal "現在のパスワード", bundled("ja", "activerecord.attributes.user.current_password")
  assert_equal "That is not your current password.", bundled("en", "accounts.update.wrong_password")
  assert_equal "現在のパスワードが違います。", bundled("ja", "accounts.update.wrong_password")
  assert_equal bundled("en", "accounts.update.wrong_password"), bundled("en", "accounts.destroy.wrong_password")
  assert_equal bundled("ja", "accounts.update.wrong_password"), bundled("ja", "accounts.destroy.wrong_password")
  assert_equal "Your account has been updated.", bundled("en", "accounts.update.updated")
  assert_equal "アカウントを更新しました。", bundled("ja", "accounts.update.updated")
  assert_equal "Your account has been deleted.", bundled("en", "accounts.destroy.deleted")
  assert_equal "アカウントを削除しました。", bundled("ja", "accounts.destroy.deleted")
  assert_equal "Try again later.", bundled("en", "accounts.update.rate_limited")
  assert_equal "Delete account", bundled("en", "accounts.edit.delete")
  assert_equal "アカウントを削除する", bundled("ja", "accounts.edit.delete")
  # The scanner resolves lazy keys as D8 and Controller#t do, and refuses
  # one in a private method.
  assert_equal "sessions.nav", view_scope("sessions/_nav.html.erb")
  assert_equal "admin.posts.index", view_scope("admin/posts/index.html.erb")
  assert_equal ["4:.a", "18:b"], t_calls("  x(t(\".a\"), I18n.t(\"b\"), at(\"c\")")
end

test "the routes and the layout's nav are inserted" do
  assert_equal <<~RUBY, read("shop/config/routes.rb")
    Cybertrain::Routes.draw do
      resource :session, only: [:new, :create, :destroy]
      resources :passwords, param: :token, only: [:new, :create, :edit, :update]
      resource :account, only: [:edit, :update, :destroy]
      get "/sign_up", to: "registrations#new", as: "sign_up"
      post "/sign_up", to: "registrations#create"
      jobs_page "/admin/jobs", before_action: :require_admin, skip_before_action: :require_authentication
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
  assert_includes support, "\"cybertrain/test/http_receiver\""
  spec = read("shop/test/authentication.rb")
  assert_includes spec, "require_relative \"support/app_test\""
  assert_includes spec, "client.post(\"/sign_up\""
  assert_includes spec, "test \"POST /session past ten attempts is refused for a while\" do\n"
  # Its ten attempts go to an address no user has: the per-IP limit counts
  # them, and lockout (left on) has no account to lock.
  assert_includes spec, "                       \"email_address\" => \"nobody@example.com\", \"password\" => \"wrong-password\" }\n"
  assert spec.index("auth_lockout_attempts").nil?
  assert_includes spec, "Cybertrain::Test.run!\n"
  # after_authentication_url is private now: a subclass made for the test reads it.
  assert_includes spec, "class ReturnPathProbeController < ApplicationController\n  def probe_after_authentication_url\n    after_authentication_url\n  end\nend\n"
  assert spec.index("controller.after_authentication_url").nil?
  admin = read("shop/test/admin.rb")
  assert_includes admin, "require_relative \"support/app_test\"\nrequire_relative \"../app/commands/user_command\"\n"
  assert_includes admin, "class AdminProbeController < ApplicationController\n  def probe_require_admin\n    require_admin\n  end\nend\n"
  assert_includes admin, "test \"require_admin answers 404 to a visitor and a non-admin and 200 to an admin\" do\n"
  assert_includes admin, "test \"user.admin? is false for a new user\" do\n"
  assert_includes admin, "  assert_equal 404, ctx.response.status\n"
  assert_includes admin, "  res = client.get(\"/admin/jobs\")\n  assert_response res, :not_found\n"
  # A visitor gets the same 404 through the stack: the jobs page runs
  # require_admin alone.
  assert_includes admin, "  client = new_client\n  res = client.get(\"/admin/jobs\")\n  assert_response res, :not_found\n  assert_equal \"Not Found\", res.body\n"
  assert admin.index("assert_redirected_to res, \"/session/new\"").nil?
  # The command's printed lines, not only its status.
  assert_includes admin, "  assert_equal \"admin ann@example.com\", UserCommand.admin_change(\"Ann@Example.com\", true)\n"
  assert_includes admin, "  assert_equal \"error: no user bob@example.com\", UserCommand.admin_change(\"bob@example.com\", true)\n"
  assert_includes admin, "  assert_equal false, user.admin?\n"
  assert_includes admin, "  assert_equal 0, UserCommand.run([\"admin\", \"Ann@Example.com\"])\n"
  assert_includes admin, "Cybertrain::Test.run!\n"
  # Remember me and the idle limit: Session rows moved back in time.
  remember = read("shop/test/remember_me.rb")
  assert_includes remember, "require_relative \"support/app_test\"\n"
  ["a remembered session is alive on day 15 and ended after day 30", "an unremembered session ends after day 14",
   "an unremembered session still ends with session_absolute_max_age off", "both end after 7 idle days",
   "last_active_at is touched at most once a minute", "an unremembered sign-in sets a cookie without Max-Age"].each do |name|
    assert_includes remember, "test \"#{name}\" do\n"
  end
  assert_includes remember, "  fields[\"remember_me\"] = \"1\" if remember\n"
  assert_includes remember, "  Session.first.update_columns(created_at: Time.at(now - started).utc, last_active_at: Time.at(now - idle).utc)\n"
  assert_includes remember, "  backdate(15 * DAY, 0)\n  assert signed_in?(client)\n  backdate(30 * DAY - 60, 0)\n  assert signed_in?(client)\n  cookie = cookie_header(client)\n  backdate(30 * DAY, 0)\n  refute signed_in?(client)\n"
  # An expired row is ended, and raising the limit later does not revive it.
  assert_includes remember, "  assert_equal 0, Session.count\n"
  assert_includes remember, "    refute replayed_signed_in?(client, cookie)\n"
  assert_includes remember, "  backdate(14 * DAY - 60, 0)\n  assert signed_in?(client)\n  backdate(14 * DAY, 0)\n  refute signed_in?(client)\n"
  assert_includes remember, "    backdate(8 * DAY, 7 * DAY - 60)\n    assert signed_in?(client)\n    cookie = cookie_header(client)\n    backdate(8 * DAY, 7 * DAY)\n    refute signed_in?(client)\n"
  assert_includes remember, "  assert session_cookie(res).end_with?(\"; Max-Age=2592000\"), session_cookie(res)\n"
  assert_includes remember, "  refute cookie.include?(\"Max-Age\")\n"
  assert_includes remember, "    assert_equal 1_209_600, stamped.lifetime_limit\n    assert stamped.browser_session?\n"
  assert_includes remember, "Cybertrain::Test.run!\n"
  # Lockout: every attempt forgets the rate limit's counts (AppTest.sign_in),
  # so the eleventh is answered by the lock, not the rate limit (F8).
  lockout = read("shop/test/lockout.rb")
  ["10 failures lock the account for an hour with the wrong-password message",
   "a locked account refuses the right password until locked_until passes",
   "a successful sign-in clears the count", "auth_lockout_attempts 0 never locks"].each do |name|
    assert_includes lockout, "test \"#{name}\" do\n"
  end
  assert_includes lockout, "  res = AppTest.sign_in(client, \"ann@example.com\", password)\n"
  assert_includes lockout, "WRONG = \"<p class=\\\"alert\\\">Try another email address or password.</p>\"\n"
  assert_includes lockout, "  refute page.body.include?(\"Try again later.\")\n"
  assert_includes lockout, "  assert locked.locked_until.to_i >= before + 3600\n  assert locked.locked_until.to_i <= after + 3600\n"
  assert_includes lockout, "Cybertrain::Test.run!\n"
end

test "running the generator again writes and edits nothing" do
  before = {}
  (AUTH_FILES + ["config/routes.rb", "app/controllers/application_controller.rb", "app/views/layouts/application.html.erb",
                 "bin/shop.rb", "config/app.rb"]).each do |f|
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
      resources :passwords, param: :token, only: [:new, :create, :edit, :update]
      resource :account, only: [:edit, :update, :destroy]
      get "/sign_up", to: "registrations#new", as: "sign_up"
      post "/sign_up", to: "registrations#create"
      resources :products
      jobs_page "/admin/jobs", before_action: :require_admin, skip_before_action: :require_authentication
    end
  RUBY
end

INVITE_FILES = [
  "db/migrate/20260925120000_create_users.rb",
  "db/migrate/20260925120001_create_sessions.rb",
  "app/models/user.rb",
  "app/models/session.rb",
  "app/controllers/concerns/authentication.rb",
  "app/controllers/sessions_controller.rb",
  "app/controllers/setup_controller.rb",
  "app/controllers/passwords_controller.rb",
  "app/controllers/accounts_controller.rb",
  "app/mailers/passwords_mailer.rb",
  "app/commands/user_command.rb",
  "app/views/sessions/new.html.erb",
  "app/views/sessions/_nav.html.erb",
  "app/views/setup/new.html.erb",
  "app/views/passwords/new.html.erb",
  "app/views/passwords/edit.html.erb",
  "app/views/mail/_password_reset.html.erb",
  "app/views/accounts/edit.html.erb",
  "test/support/app_test.rb",
  "test/support/authentication_helpers.rb",
  "test/authentication.rb",
  "test/admin.rb",
  "test/remember_me.rb",
  "test/lockout.rb",
  "test/passwords.rb",
  "test/accounts.rb"
]

test "--invite-only writes the user command and /setup instead of the sign-up page" do
  Cybertrain::CLI::NewApp.create("club", "{ path = \"../cybertrain\" }")
  status = Dir.chdir("club") { Cybertrain::CLI.run(["generate", "authentication", "--invite-only"]) }
  assert_equal 0, status
  INVITE_FILES.each { |f| assert(File.exist?("club/#{f}"), "missing #{f}") }
  assert_equal INVITE_FILES.size, INVITE_FILES.select { |f| File.exist?("club/#{f}") }.size
  # The same concern, whichever the mode; only the base URL's variable is
  # named after the app.
  club_concern = read("club/app/controllers/concerns/authentication.rb")
  assert_includes club_concern, "set CLUB_BASE_URL (or CYBERTRAIN_HOSTS)"
  assert_equal read("shop/app/controllers/concerns/authentication.rb").gsub("SHOP_BASE_URL", "CLUB_BASE_URL"), club_concern
  refute File.exist?("club/app/controllers/registrations_controller.rb")
  refute File.exist?("club/app/views/registrations/new.html.erb")
  # No link to a sign-up page that does not exist.
  sign_in_view = read("club/app/views/sessions/new.html.erb")
  assert sign_in_view.end_with?("  </div>\n<% end %>\n\n<p><%= link_to t(\".forgot_password\"), new_password_path %></p>\n"), sign_in_view
  assert sign_in_view.index("sign_up").nil?
  assert_equal <<~RUBY, read("club/config/routes.rb")
    Cybertrain::Routes.draw do
      resource :session, only: [:new, :create, :destroy]
      resources :passwords, param: :token, only: [:new, :create, :edit, :update]
      resource :account, only: [:edit, :update, :destroy]
      get "/setup", to: "setup#new", as: "setup"
      post "/setup", to: "setup#create"
      jobs_page "/admin/jobs", before_action: :require_admin, skip_before_action: :require_authentication
    end
  RUBY
end

test "--invite-only's screens go through t, with keys the bundled dictionaries have" do
  assert_equal [], untranslated("club")
  keys = (ACCOUNT_KEYS + RESET_KEYS).sort + ["errors.template.header"] + RESET_TAIL_KEYS +
         ["sessions.create.invalid", "sessions.create.rate_limited", "sessions.destroy.signed_out",
          "sessions.nav.account", "sessions.nav.sign_in", "sessions.nav.sign_out",
          "sessions.new.email_address", "sessions.new.forgot_password", "sessions.new.password", "sessions.new.remember_me",
          "sessions.new.submit", "sessions.new.title",
          "setup.create.welcome", "setup.new.intro", "setup.new.model", "setup.new.submit", "setup.new.title"]
  assert_equal keys, used_keys("club")
  keys.each do |key|
    refute bundled("en", key).nil?, "en.#{key}"
    refute bundled("ja", key).nil?, "ja.#{key}"
  end
  assert_equal "Set up", bundled("en", "setup.new.title")
  assert_equal "Welcome! Your account has been created.", bundled("en", "setup.create.welcome")
end

test "--invite-only requires the command in bin/<app>.rb and declares setup_open" do
  club_bin = read("club/bin/club.rb")
  assert_includes club_bin, <<~RUBY
    #   end

    # `./club user EMAIL [PASSWORD]`, `./club user admin EMAIL` and
    # `./club user unadmin EMAIL`, and a [WARN] at boot while no user exists
    # (cybertrain generate authentication --invite-only).
    require_relative "../app/commands/user_command"
    UserCommand.warn_if_no_user if Cybertrain::Main.server?(ARGV)

    exit(Cybertrain::Main.run("club", ARGV,
  RUBY
  club_config = read("club/config/app.rb")
  assert_includes club_config, "Cybertrain.configure do |c|\n  # /setup (the first user's page)"
  assert_includes club_config, "  c.setting_bool :setup_open, env: \"CLUB_SETUP_OPEN\", default: false\n\n  # Links in mails"
  assert_includes club_config, "  c.setting_string :base_url, env: \"CLUB_BASE_URL\", default: \"\"\n\n  # c.port = 3000\n"
end

test "--invite-only's /setup answers only to loopback with the one-time token while no user exists" do
  setup = read("club/app/controllers/setup_controller.rb")
  assert_includes setup, "class SetupController < ApplicationController\n  allow_unauthenticated_access only: [:new, :create]\n  before_action :require_first_run\n"
  assert_includes setup, "  SETUP_TOKEN = Cybertrain::Crypto.random_token(16)\n"
  assert_includes setup, "  def self.setup_token\n    SETUP_TOKEN\n  end\n"
  assert_includes setup, "    @setup_token = params[:token].to_s\n"
  assert_includes setup, "    head :not_found unless setup_open? && Cybertrain::Crypto.secure_compare(@setup_token, SetupController.setup_token)\n"
  # The no-user check and the insert are one BEGIN IMMEDIATE transaction.
  assert_includes setup, "    User.transaction(immediate: true) do |c|\n      saved = @user.save unless User.all.exists?\n    end\n"
  assert_includes setup, "    return false if User.all.exists?\n"
  assert_includes setup, "    return true if Cybertrain.config.bool_setting(:setup_open)\n"
  assert_includes setup, "    request.loopback? && request.header(\"x-forwarded-for\").nil?\n"
  assert_includes setup, "      start_new_session_for(@user)\n"
  assert_includes setup, "CLUB_SETUP_OPEN=1"
  setup_view = read("club/app/views/setup/new.html.erb")
  assert_includes setup_view, "<%= form_with(model: @user, url: setup_path) do |f| %>\n  <input type=\"hidden\" name=\"token\" value=\"<%= @setup_token %>\">\n"
  assert_includes setup_view, "<%= f.password_field :password_confirmation, autocomplete: \"new-password\" %>"
end

test "--invite-only's user command reads the password from stdin when not given" do
  command = read("club/app/commands/user_command.rb")
  assert_includes command, "Cybertrain::Main.command(\"user\", \"EMAIL [PASSWORD] | admin EMAIL | unadmin EMAIL: create a user or set its password, or grant or revoke admin\") do |argv|\n  UserCommand.run(argv)\nend\n"
  assert_includes command, "    password = argv.size == 2 ? argv[1] : UserCommand.read_password\n"
  assert_includes command, "    line = STDIN.gets\n"
  assert_includes command, "      puts \"error: the password is empty\"\n"
  assert_includes command, "    puts created ? \"created \#{address}\" : \"updated \#{address}\"\n"
  assert_includes command, "usage: ./club user EMAIL [PASSWORD]"
  assert_includes command, "Cybertrain.logger.warn(\"no user exists yet: run ./club user EMAIL, or open /setup?token=\#{SetupController.setup_token} from this machine\") if UserCommand.no_user?"
  assert_includes command, "    rescue Cybertrain::DB::Error\n"
  club_spec = read("club/test/authentication.rb")
  assert_includes club_spec, "require_relative \"support/app_test\"\nrequire_relative \"../app/commands/user_command\"\n\n"
  assert_includes club_spec, "  client.peer_address = \"203.0.113.7\"\n"
  assert_includes club_spec, "test \"CLUB_SETUP_OPEN opens /setup to any address with the token until a user exists\" do\n"
  assert_includes club_spec, "test \"/setup without the token, or with a wrong one, is a 404\" do\n"
  assert_includes club_spec, "    \"token\" => SetupController.setup_token,\n"
  assert_includes club_spec, "Cybertrain::Main.run(\"club\", argv, "
  assert_includes club_spec, "test \"POST /session past ten attempts is refused for a while\" do\n"
  assert club_spec.index("client.post(\"/sign_up\"").nil?
end

test "the user command clears a lock when it sets a password" do
  command = read("shop/app/commands/user_command.rb")
  assert_includes command, "    unless user.save\n"
  assert_includes command, "    user.clear_failed_attempts!\n    puts created ?"
  lockout = read("shop/test/lockout.rb")
  assert_includes lockout, "require_relative \"../app/commands/user_command\"\n"
  assert_includes lockout, "test \"./APP user EMAIL PASSWORD clears a lock\" do\n"
  assert_includes lockout, "test \"with auth_lockout_attempts 0 an existing lock is not enforced\" do\n"
end

test "the user command is written in both modes with admin and unadmin" do
  ["shop", "club"].each do |app|
    command = read("#{app}/app/commands/user_command.rb")
    assert_includes command, "  USAGE = \"usage: ./#{app} user EMAIL [PASSWORD] (without PASSWORD, it is read from standard input) | ./#{app} user admin EMAIL | ./#{app} user unadmin EMAIL\"\n"
    assert_includes command, "    if !argv.empty? && (argv[0] == \"admin\" || argv[0] == \"unadmin\")\n" \
                             "      if argv.size != 2\n        puts USAGE\n        return 1\n      end\n" \
                             "      return UserCommand.grant_admin(argv[1], argv[0] == \"admin\")\n    end\n"
    assert_includes command, "  def self.grant_admin(email, granted)\n    line = UserCommand.admin_change(email, granted)\n    puts line\n    line.start_with?(\"error: \") ? 1 : 0\n  end\n"
    assert_includes command, "    found = User.find_by(email_address: address)\n    return \"error: no user \#{address}\" if found.nil?\n"
    assert_includes command, "    found.admin = granted\n"
    assert_includes command, "    granted ? \"admin \#{address}\" : \"unadmin \#{address}\"\n"
    assert_includes command, "    puts created ? \"created \#{address}\" : \"updated \#{address}\"\n"
    assert_includes command, "Cybertrain::Main.command(\"user\", \"EMAIL [PASSWORD] | admin EMAIL | unadmin EMAIL: create a user or set its password, or grant or revoke admin\") do |argv|\n"
  end
  # Sign-up mode has no /setup: no boot warning, no SetupController.
  shop = read("shop/app/commands/user_command.rb")
  assert shop.index("SetupController").nil?
  assert shop.index("warn_if_no_user").nil?
  assert_includes read("club/app/commands/user_command.rb"), "  def self.warn_if_no_user\n"
  shop_bin = read("shop/bin/shop.rb")
  assert_includes shop_bin, <<~RUBY
    #   end

    # `./shop user EMAIL [PASSWORD]`, `./shop user admin EMAIL` and
    # `./shop user unadmin EMAIL` (cybertrain generate authentication).
    require_relative "../app/commands/user_command"

    exit(Cybertrain::Main.run("shop", ARGV,
  RUBY
  assert shop_bin.index("warn_if_no_user").nil?
end

test "--confirmable and --force are refused until they do something" do
  Cybertrain::CLI::NewApp.create("flags", "{ path = \"../cybertrain\" }")
  assert_equal 1, Dir.chdir("flags") { Cybertrain::CLI.run(["generate", "authentication", "--confirmable"]) }
  assert_equal 1, Dir.chdir("flags") { Cybertrain::CLI.run(["generate", "authentication", "--force"]) }
  assert_equal 1, Dir.chdir("flags") { Cybertrain::CLI.run(["generate", "authentication", "--invite-only", "--force"]) }
  refute File.exist?("flags/app/models/user.rb")
end

test "--invite-only run again writes and edits nothing" do
  club_before = {}
  (INVITE_FILES + ["config/routes.rb", "config/app.rb", "bin/club.rb", "app/controllers/application_controller.rb"]).each do |f|
    club_before[f] = read("club/#{f}")
  end
  status = Dir.chdir("club") { Cybertrain::CLI.run(["generate", "authentication", "--invite-only"]) }
  assert_equal 0, status
  club_before.each { |f, content| assert_equal content, read("club/#{f}") }
end

test "either mode refuses an app whose bin/<app>.rb has no Main.run line, before writing" do
  Cybertrain::CLI::NewApp.create("bare", "{ path = \"../cybertrain\" }")
  File.write("bare/bin/bare.rb", "require \"cybertrain\"\n# exit(Cybertrain::Main.run(\"bare\", ARGV))\n")
  status = Dir.chdir("bare") { Cybertrain::CLI.run(["generate", "authentication", "--invite-only"]) }
  assert_equal 1, status
  refute File.exist?("bare/app/models/user.rb")
  status = Dir.chdir("bare") { Cybertrain::CLI.run(["generate", "authentication", "--invite"]) }
  assert_equal 1, status
  # Sign-up mode edits bin/<app>.rb too (the user command), so it checks it.
  status = Dir.chdir("bare") { Cybertrain::CLI.run(["generate", "authentication"]) }
  assert_equal 1, status
  refute File.exist?("bare/app/models/user.rb")
  File.delete("bare/bin/bare.rb")
  status = Dir.chdir("bare") { Cybertrain::CLI.run(["generate", "authentication"]) }
  assert_equal 1, status
  refute File.exist?("bare/app/controllers/concerns/authentication.rb")
end

PASSWORDS_CONTROLLER = <<~RUBY
  # Password reset (cybertrain generate authentication): the form that asks
  # for an address, the mail with a link (PasswordsMailer.reset), and the
  # form behind the link that sets a new password. The link's token
  # (User#password_reset_token) is signed, lasts 15 minutes and is bound to
  # the password, so it stops working once the password changes, and every
  # link sent before with it. The address form answers the same whether or
  # not the address is registered.
  class PasswordsController < ApplicationController
    allow_unauthenticated_access
    # Ten requests per client address every three minutes, as for signing in.
    rate_limit to: 10, within: 3 * 60, only: [:create], with: :rate_limited
    # The link's page carries the token in its address: no Referer for it.
    before_action :no_referrer, only: [:edit, :update]

    # GET /passwords/new
    def new_action
    end

    # POST /passwords
    # An address no user has gets the same answer after the same work (a
    # token, the mail rendered), short of queueing the mail.
    def create
      address = User.normalize_email_address(params[:email_address].to_s)
      user = User.find_by(email_address: address)
      token = user.nil? ? Cybertrain::Token.issue("password_reset", 1, 15 * 60, Cybertrain::Password.dummy_digest) : user.password_reset_token
      url = edit_password_url_for(token)
      unless url.empty?
        mail = PasswordsMailer.reset(user.nil? ? User.new(email_address: address) : user, url)
        queue_reset_mail(mail) unless user.nil?
      end
      flash[:notice] = t(".sent")
      redirect_to new_session_path, status: :see_other
    end

    # GET /passwords/:token/edit
    def edit
      @token = params[:token].to_s
      invalid_link if User.find_by_password_reset_token(@token).nil?
    end

    # PUT /passwords/:token
    # Sets the password, clears a lockout and ends every session of the
    # user (their Session rows): each browser signs in again, with the new
    # password.
    def update
      token = params[:token].to_s
      user = User.find_by_password_reset_token(token)
      if user.nil?
        invalid_link
      else
        user.password = params[:password].to_s
        user.password_confirmation = params[:password_confirmation].to_s
        if user.save
          user.clear_failed_attempts!
          Session.where(user_id: user.id).delete_all
          flash[:notice] = t(".updated")
          redirect_to new_session_path, status: :see_other
        else
          flash[:alert] = user.errors.full_messages.join(" ")
          redirect_to edit_password_path(token), status: :see_other
        end
      end
    end

    private

    # The link in the mail: mail_link_base (the Authentication concern's)
    # and the form's path; "" when there is no safe base, and then no mail
    # is sent.
    def edit_password_url_for(token)
      base = mail_link_base("password reset")
      return "" if base.empty?

      path = edit_password_path(token)
      base + path
    end

    # Queues the mail. An address the mailer refuses (a space or a
    # non-ASCII byte: Cybertrain::Mailer.check_address) is logged, and
    # the answer stays the one every other address gets.
    def queue_reset_mail(mail)
      mail.deliver_later
      nil
    rescue ArgumentError => e
      Cybertrain.logger.error("password reset mail not sent: \#{e.message}")
      nil
    end

    # Browsers send no Referer from the link's page, whose address holds
    # the token.
    def no_referrer
      response.set_header("Referrer-Policy", "no-referrer")
      nil
    end

    # A token that is wrong, expired or spent: back to the address form.
    # Not an action, so its key is written in full (edit's).
    def invalid_link
      flash[:alert] = t("passwords.edit.invalid")
      redirect_to new_password_path, status: :see_other
      nil
    end

    # What a client past the rate limit gets (the key is create's).
    def rate_limited
      flash[:alert] = t("passwords.create.rate_limited")
      redirect_to new_password_path, status: :see_other
      nil
    end
  end
RUBY

PASSWORDS_MAILER = <<~RUBY
  # The password reset mail (cybertrain generate authentication): its HTML is
  # app/views/mail/_password_reset.html.erb, its subject and text come from
  # the dictionary (passwords_mailer.reset.subject, mail.password_reset.*),
  # in the locale of the request that asked for it.
  #
  # Written by the generator; it is yours to change.
  module PasswordsMailer
    # The mail to user with url, the link PasswordsController#create built (a
    # mailer has no request to take the site's address from). Its sender is
    # Config#smtp_from (CYBERTRAIN_SMTP_FROM).
    def self.reset(user, url)
      address = user.email_address.to_s
      html = Cybertrain::Views.render_mail("mail/password_reset", user: user, url: url)
      greeting = I18n.t("mail.password_reset.greeting", { email_address: address })
      text = +""
      text << greeting << "\\n\\n"
      text << I18n.t("mail.password_reset.intro") << "\\n" << url << "\\n\\n"
      text << I18n.t("mail.password_reset.ignore") << "\\n"
      subject = I18n.t("passwords_mailer.reset.subject")
      Cybertrain::MailMessage.new(to: address, subject: subject, body: text, html: html)
    end
  end
RUBY

PASSWORDS_NEW_VIEW = <<~ERB
  <h1><%= t(".title") %></h1>

  <%= form_with(url: passwords_path) do |f| %>
    <div class="field">
      <%= f.label :email_address, t("activerecord.attributes.user.email_address") %>
      <%= f.email_field :email_address, autocomplete: "username", autofocus: true %>
    </div>

    <div class="actions">
      <%= f.submit t(".submit") %>
    </div>
  <% end %>

  <p><%= link_to t(".sign_in"), new_session_path %></p>
ERB

PASSWORDS_EDIT_VIEW = <<~ERB
  <h1><%= t(".title") %></h1>

  <%= form_with(url: password_path(@token), method: :put) do |f| %>
    <div class="field">
      <%= f.label :password, t("activerecord.attributes.user.password") %>
      <%= f.password_field :password, autocomplete: "new-password", autofocus: true %>
    </div>

    <div class="field">
      <%= f.label :password_confirmation, t("activerecord.attributes.user.password_confirmation") %>
      <%= f.password_field :password_confirmation, autocomplete: "new-password" %>
    </div>

    <div class="actions">
      <%= f.submit t(".submit") %>
    </div>
  <% end %>
ERB

PASSWORD_RESET_MAIL = <<~ERB
  <%# locals: (user:, url:) %>
  <p><%= t(".greeting", email_address: user.email_address) %></p>
  <p><%= t(".intro") %></p>
  <p><%= link_to t(".link"), url %></p>
  <p><%= t(".ignore") %></p>
ERB

test "password reset: the controller, the mailer and the views" do
  assert_equal PASSWORDS_CONTROLLER, read("shop/app/controllers/passwords_controller.rb")
  assert_equal PASSWORDS_MAILER, read("shop/app/mailers/passwords_mailer.rb")
  assert_equal PASSWORDS_NEW_VIEW, read("shop/app/views/passwords/new.html.erb")
  assert_equal PASSWORDS_EDIT_VIEW, read("shop/app/views/passwords/edit.html.erb")
  assert_equal PASSWORD_RESET_MAIL, read("shop/app/views/mail/_password_reset.html.erb")
  # The same files in --invite-only mode.
  ["app/controllers/passwords_controller.rb", "app/mailers/passwords_mailer.rb", "app/views/passwords/new.html.erb",
   "app/views/passwords/edit.html.erb", "app/views/mail/_password_reset.html.erb"].each do |f|
    assert_equal read("shop/#{f}"), read("club/#{f}")
  end
end

test "password reset: the token in the model, the base URL in the concern" do
  model = read("shop/app/models/user.rb")
  assert_includes model, indented(<<~RUBY, 2)
      # The user a password_reset_token was made for, while it is valid against
      # that user's password now; nil for any other token (a wrong, expired or
      # spent one, or one made for another user).
      def self.find_by_password_reset_token(token)
        text = token.to_s
        user = User.find_by(id: Cybertrain::Token.id_from(text))
        return nil if user.nil?
        return nil unless Cybertrain::Token.valid?(text, "password_reset", user.password_digest)

        user
      end
  RUBY
  assert_includes model, indented(<<~RUBY, 2)
      # The token of a password reset link (PasswordsController): signed,
      # valid for 15 minutes from now, and bound to password_digest, so it
      # stops working once the password changes (Cybertrain::Token).
      def password_reset_token(now = Time.now.to_i)
        Cybertrain::Token.issue("password_reset", id, 15 * 60, password_digest, now)
      end
  RUBY
  concern = read("shop/app/controllers/concerns/authentication.rb")
  assert_includes concern, indented(<<~RUBY, 2)
      # Where links in mails start ("https://shop.example.com"): the base_url
      # setting (SHOP_BASE_URL, config/app.rb) when set; else the address this
      # request came to, but only where the Host header is known to be
      # safe: the Host is checked (development, or CYBERTRAIN_HOSTS lists
      # the hosts the app answers to, so any other Host is refused before
      # an action runs), or the app runs its tests. In any other
      # environment (production, staging, ...) "" and an [ERROR] line: the
      # mail named `mail` is not sent, as a link built from a Host header
      # anyone can forge would carry its token to their site.
      def mail_link_base(mail)
        c = Cybertrain.config
        configured = c.string_setting(:base_url)
        return configured.delete_suffix("/") unless configured.empty?
        return request.base_url if c.host_check? || c.test?

        Cybertrain.logger.error("\#{mail} mail not sent: set SHOP_BASE_URL (or CYBERTRAIN_HOSTS)")
        ""
      end
  RUBY
  # One copy of that decision: the controller asks the concern.
  assert_equal 1, read("shop/app/controllers/passwords_controller.rb").scan("mail_link_base(").size
  assert read("shop/app/controllers/passwords_controller.rb").index("base_url").nil?
end

test "password reset: the route, the sign-in link and the base_url setting in both modes" do
  assert_includes read("shop/config/routes.rb"), "  resources :passwords, param: :token, only: [:new, :create, :edit, :update]\n"
  assert_includes read("club/config/routes.rb"), "  resources :passwords, param: :token, only: [:new, :create, :edit, :update]\n"
  assert_includes read("shop/app/views/sessions/new.html.erb"), "<p><%= link_to t(\".forgot_password\"), new_password_path %></p>\n"
  shop_config = read("shop/config/app.rb")
  assert_includes shop_config, <<~RUBY
    Cybertrain.configure do |c|
      # Links in mails (the password reset's) start with this, as in
      # SHOP_BASE_URL=https://shop.example.com: set it, with https, wherever the
      # app is served. Unset, they take the address the request came to,
      # which is trusted only in development, in tests, or when
      # CYBERTRAIN_HOSTS lists the app's hosts; anywhere else a reset mail
      # is not sent and the log says why.
      c.setting_string :base_url, env: "SHOP_BASE_URL", default: ""

      # c.port = 3000
  RUBY
  assert shop_config.index("setup_open").nil?
  assert_equal 1, read("club/config/app.rb").scan("setting_string :base_url").size
end

test "password reset: the generated tests and their helpers" do
  helpers = read("shop/test/support/authentication_helpers.rb")
  assert_includes helpers, "require \"cybertrain/test/smtp_receiver\"\nrequire_relative \"app_test\"\n"
  assert_includes helpers, "def with_smtp_receiver\n"
  # The settings come back even when the block fails.
  assert_includes helpers, "    yield receiver\n  ensure\n    receiver.stop\n    c.smtp_host = host\n    c.smtp_port = given_port\n" \
                           "    c.smtp_tls = tls\n    c.smtp_from = from\n  end\n"
  assert_includes helpers, "    c.smtp_host = \"127.0.0.1\"\n    c.smtp_port = port\n    c.smtp_tls = \"none\"\n    c.smtp_from = \"noreply@example.com\"\n"
  assert_includes helpers, "def last_mail_link(receiver)\n"
  assert_includes helpers, "def backdate_session(row, seconds)\n  at = Time.at(Time.now.to_i - seconds).utc\n  row.update_columns(created_at: at, last_active_at: at)\n  nil\nend\n"
  spec = read("shop/test/passwords.rb")
  assert_includes spec, "require_relative \"support/app_test\"\nrequire_relative \"support/authentication_helpers\"\n"
  ["reset answers the same for unknown addresses and links to base_url",
   "without base_url a link takes the request's address only where that is safe",
   "any other environment without base_url sends no mail and answers the same",
   "an address the mailer refuses gets the same answer, and the log says why",
   "the token expires after 15 minutes", "the token stops working once the password changed",
   "updating the password ends every other session", "a reset clears a lockout",
   "the mail arrives through the SMTP receiver with the dictionary's subject",
   "POST /passwords past ten requests is refused for a while"].each do |name|
    assert_includes spec, "test \"#{name}\" do\n"
  end
  # Review Focus 4: a forged Host, both addresses, one mail, base_url.
  assert_includes spec, "    known = request_reset(client, \"Ann@Example.com\", \"evil.example\")\n"
  assert_includes spec, "    unknown = request_reset(client, \"nobody@example.com\", \"evil.example\")\n"
  assert_includes spec, "    assert_equal known_body, unknown.body\n"
  assert_includes spec, "    assert link.start_with?(\"https://shop.example/passwords/\"), link\n"
  # Every branch of the base URL, with the app's own variable in the log line.
  assert_includes spec, "  assert_includes log.string, \"[ERROR] password reset mail not sent: set SHOP_BASE_URL (or CYBERTRAIN_HOSTS)\\n\"\n"
  assert_includes read("club/test/passwords.rb"), "set CLUB_BASE_URL (or CYBERTRAIN_HOSTS)"
  # 15 minutes: 16 minutes ago is too old, 14 is not.
  assert_includes spec, "  stale = user.password_reset_token(now - 16 * 60)\n  fresh = user.password_reset_token(now - 14 * 60)\n"
  # Every change to global state is put back in an ensure (with_config).
  assert_includes spec, "  ensure\n    c.env = saved_env\n    c.hosts_from_env = saved_hosts\n" \
                        "    c.set_string_setting(:base_url, saved_base_url)\n    Cybertrain.logger = saved_logger\n  end\n"
  assert spec.index("Cybertrain.config.set_string_setting").nil?
  assert spec.index("config.env = ").nil?
  assert_includes spec, "  with_config(\"staging\", NO_HOSTS, \"\", log) do\n"
  assert_includes spec, "  assert_equal \"no-referrer\", res.header(\"Referrer-Policy\")\n"
  assert_includes spec, "Cybertrain::Test.run!\n"
end

test "a re-run adds the reset route and the base_url setting to an app generated before them" do
  Cybertrain::CLI::NewApp.create("older", "{ path = \"../cybertrain\" }")
  Cybertrain::CLI::Authentication.generate("older")
  routes = read("older/config/routes.rb")
  File.write("older/config/routes.rb", routes.sub("  resources :passwords, param: :token, only: [:new, :create, :edit, :update]\n", ""))
  config = read("older/config/app.rb")
  start = config.index("  # Links in mails")
  stop = config.index("default: \"\"\n\n", start) + 13
  File.write("older/config/app.rb", config[0, start] + config[stop, config.size - stop])
  refute read("older/config/app.rb").include?("base_url")
  Cybertrain::CLI::Authentication.generate("older")
  assert_equal routes, read("older/config/routes.rb")
  assert_equal config, read("older/config/app.rb")
end

ACCOUNTS_CONTROLLER = <<~'RUBY'
  # The signed-in user's account (cybertrain generate authentication): a new
  # email address, a new password, or both, each only with the current
  # password; and the account deleted, also only with the password.
  #
  # Written by the generator; it is yours to change.
  class AccountsController < ApplicationController
    # Ten changes or deletions per client address every three minutes, as for
    # signing in: a current password is guessed here no faster than there.
    rate_limit to: 10, within: 3 * 60, only: [:update, :destroy], with: :rate_limited
    before_action :set_user

    # GET /account/edit
    def edit
    end

    # PATCH/PUT /account
    # The current password first, for any change. A new address takes effect
    # at once. A new password ends every other session of the user and starts
    # this browser's again (restart_sessions), and every password reset link
    # sent before stops working (they are bound to the password).
    def update
      fields = params.expect(user: [:current_password, :email_address, :password, :password_confirmation])
      digest = @user.password_digest
      if @user.authenticate(fields["current_password"].to_s)
        @user.email_address = fields["email_address"].to_s if fields.key?("email_address")
        password = fields["password"].to_s
        unless password.empty?
          @user.password = password
          @user.password_confirmation = fields["password_confirmation"].to_s
        end
        if @user.save
          restart_sessions if @user.password_digest != digest
          flash[:notice] = t(".updated")
          redirect_to edit_account_path, status: :see_other
        else
          render :edit, status: :unprocessable_entity
        end
      else
        flash.now[:alert] = t(".wrong_password")
        render :edit, status: :unprocessable_entity
      end
    end

    # DELETE /account
    # With the password: the user's sessions (every browser's), then the user,
    # are deleted, and this browser's cookie session is emptied.
    def destroy
      if @user.authenticate(params[:password].to_s)
        Session.where(user_id: @user.id).delete_all
        @user.destroy
        terminate_session
        flash[:notice] = t(".deleted")
        redirect_to "/", status: :see_other
      else
        flash.now[:alert] = t(".wrong_password")
        render :edit, status: :unprocessable_entity
      end
    end

    private

    # A copy of the signed-in user for the forms, so that a change that does
    # not pass leaves @current_user, which the nav shows, as it is.
    def set_user
      @user = User.find(@current_user.id)
    end

    # After a new password: every Session row of the user ends, the other
    # browsers' and this one's, and this browser signs in again at once with
    # the new password key, remembered ("keep me signed in") as it was.
    def restart_sessions
      current = @current_session
      remember = current.nil? ? false : current.remember
      Session.where(user_id: @user.id).delete_all
      start_new_session_for(@user, remember: remember)
      nil
    end

    # What a client past the rate limit gets (the key is update's).
    def rate_limited
      flash[:alert] = t("accounts.update.rate_limited")
      redirect_to edit_account_path, status: :see_other
      nil
    end
  end
RUBY

ACCOUNTS_EDIT_VIEW = <<~ERB
  <h1><%= t(".title") %></h1>

  <%= form_with(model: @user, url: account_path) do |f| %>
    <% if @user.errors.any? %>
      <div id="error_explanation">
        <h2><%= t("errors.template.header", count: @user.errors.count, model: t(".model")) %></h2>
        <ul>
          <% @user.errors.full_messages.each do |message| %>
            <li><%= message %></li>
          <% end %>
        </ul>
      </div>
    <% end %>

    <div class="field">
      <%= f.label :email_address %>
      <%= f.email_field :email_address, autocomplete: "username" %>
    </div>

    <div class="field">
      <%= f.label :password, t(".new_password") %>
      <%= f.password_field :password, autocomplete: "new-password" %>
      <p class="hint"><%= t(".password_hint") %></p>
    </div>

    <div class="field">
      <%= f.label :password_confirmation %>
      <%= f.password_field :password_confirmation, autocomplete: "new-password" %>
    </div>

    <div class="field">
      <%= f.label :current_password %>
      <%= f.password_field :current_password, autocomplete: "current-password", required: true %>
    </div>

    <div class="actions">
      <%= f.submit t(".submit") %>
    </div>
  <% end %>

  <h2><%= t(".delete_title") %></h2>
  <p><%= t(".delete_intro") %></p>

  <%= form_with(url: account_path, method: :delete) do |f| %>
    <div class="field">
      <%= f.label :password, t("activerecord.attributes.user.current_password") %>
      <%= f.password_field :password, autocomplete: "current-password", required: true %>
    </div>

    <div class="actions">
      <%= f.submit t(".delete") %>
    </div>
  <% end %>
ERB

test "account pages: the controller, the view, the route and the nav link in both modes" do
  assert_equal ACCOUNTS_CONTROLLER, read("shop/app/controllers/accounts_controller.rb")
  assert_equal ACCOUNTS_EDIT_VIEW, read("shop/app/views/accounts/edit.html.erb")
  ["app/controllers/accounts_controller.rb", "app/views/accounts/edit.html.erb", "app/views/sessions/_nav.html.erb",
   "test/accounts.rb"].each do |f|
    assert_equal read("shop/#{f}"), read("club/#{f}")
  end
  assert_includes read("club/config/routes.rb"), "  resource :account, only: [:edit, :update, :destroy]\n"
  # F9: the restart goes through start_new_session_for with the row's own
  # remember flag, so a remembered sign-in stays remembered.
  controller = read("shop/app/controllers/accounts_controller.rb")
  assert_equal 1, controller.scan("start_new_session_for(").size
  assert_includes controller, "    remember = current.nil? ? false : current.remember\n"
  assert_includes controller, "    start_new_session_for(@user, remember: remember)\n"
  # A wrong current password is rate limited with the sign-in's numbers.
  assert_includes controller, "  rate_limit to: 10, within: 3 * 60, only: [:update, :destroy], with: :rate_limited\n"
  # No mail is sent from here, so no link base either.
  assert controller.index("mail_link_base").nil?
  assert controller.index("base_url").nil?
end

test "account pages: the generated test" do
  spec = read("shop/test/accounts.rb")
  assert_includes spec, "require_relative \"support/app_test\"\n"
  ["changing email or password requires the current password",
   "a password change ends other sessions and keeps this one",
   "deleting the account requires the password and removes the user and sessions",
   "a visitor is sent to sign in",
   "PATCH /account past ten requests is refused for a while"].each do |name|
    assert_includes spec, "test \"#{name}\" do\n"
  end
  assert_includes spec, "WRONG_PASSWORD = \"<p class=\\\"alert\\\">That is not your current password.</p>\"\n"
  # Both sides of the current password: wrong (nothing changes) and right.
  assert_includes spec, "  res = update_account(client, \"wrong-password\", { \"email_address\" => \"ann@new.example\", " \
                        "\"password\" => NEW_PASSWORD, \"password_confirmation\" => NEW_PASSWORD })\n" \
                        "  assert_response res, :unprocessable_entity\n  assert_includes res.body, WRONG_PASSWORD\n"
  assert_includes spec, "  assert_equal \"ann@example.com\", same.email_address\n  assert_equal digest, same.password_digest\n"
  assert_includes spec, "  assert_equal \"ann@new.example\", changed.email_address\n  assert_equal digest, changed.password_digest\n"
  # What a password change ends and keeps, with the remember flag kept (F9).
  assert_includes spec, "  assert session_cookie(res).end_with?(\"; Max-Age=2592000\"), session_cookie(res)\n"
  assert_includes spec, "  assert_equal 1, rows.size\n  refute rows[0].id == laptop_id\n  assert_equal true, rows[0].remember\n"
  assert_includes spec, "  assert signed_in?(laptop)\n  refute signed_in?(phone)\n  assert signed_in?(bobs, \"bob@example.com\")\n"
  assert_includes spec, "  assert_nil User.find_by_password_reset_token(token)\n"
  # Deleting: both sides of the password, the user and their rows gone.
  assert_includes spec, "  assert_nil User.find_by(id: ann.id)\n  assert_equal 0, Session.where(user_id: ann.id).count\n  assert_equal 1, Session.count\n"
  assert_includes spec, "  assert_includes client.get(\"/session/new\").body, DELETED\n"
  # A visitor: every action sends them to sign in, and changes nothing.
  assert_includes spec, "  assert_redirected_to client.get(\"/account/edit\"), \"/session/new\"\n"
  assert_includes spec, "Cybertrain::Test.run!\n"
end

test "a re-run adds the account route to an app generated before it" do
  Cybertrain::CLI::NewApp.create("prior", "{ path = \"../cybertrain\" }")
  Cybertrain::CLI::Authentication.generate("prior")
  routes = read("prior/config/routes.rb")
  File.write("prior/config/routes.rb", routes.sub("  resource :account, only: [:edit, :update, :destroy]\n", ""))
  refute read("prior/config/routes.rb").include?("resource :account")
  Cybertrain::CLI::Authentication.generate("prior")
  assert_equal routes, read("prior/config/routes.rb")
  # Neither the reset's nor the account's: both come back, in that order.
  File.write("prior/config/routes.rb", routes.sub("  resources :passwords, param: :token, only: [:new, :create, :edit, :update]\n", "")
                                             .sub("  resource :account, only: [:edit, :update, :destroy]\n", ""))
  Cybertrain::CLI::Authentication.generate("prior")
  assert_equal routes, read("prior/config/routes.rb")
  # Once there, a third run leaves the file alone.
  Cybertrain::CLI::Authentication.generate("prior")
  assert_equal routes, read("prior/config/routes.rb")
end

test "both modes refuse an app without config/app.rb's configure line, before writing" do
  Cybertrain::CLI::NewApp.create("noconf", "{ path = \"../cybertrain\" }")
  File.write("noconf/config/app.rb", "# settings\n")
  assert_equal 1, Dir.chdir("noconf") { Cybertrain::CLI.run(["generate", "authentication"]) }
  refute File.exist?("noconf/app/models/user.rb")
  File.delete("noconf/config/app.rb")
  assert_equal 1, Dir.chdir("noconf") { Cybertrain::CLI.run(["generate", "authentication"]) }
  refute File.exist?("noconf/app/models/user.rb")
end

test "insert_before_line inserts at the start of the line" do
  out = Cybertrain::CLI::Authentication.insert_before_line("a\nexit(x)\n", "exit(", "b\n")
  assert_equal "a\nb\nexit(x)\n", out
  out = Cybertrain::CLI::Authentication.insert_before_line("exit(x)\n", "exit(", "b\n")
  assert_equal "b\nexit(x)\n", out
  message = assert_raises("InvalidArgument") { Cybertrain::CLI::Authentication.insert_before_line("# exit(x)\n", "exit(", "b\n") }
  assert_includes message, "no line starting with `exit(`"
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
  assert_equal "Cybertrain::Routes.draw do\n  # jobs_page \"/admin/jobs\", before_action: :require_admin\nend\n", read("broken/config/routes.rb")
end

Cybertrain::Test.run!
