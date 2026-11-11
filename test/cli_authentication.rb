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

AUTH_FILES = [
  "db/migrate/20260925120000_create_users.rb",
  "db/migrate/20260925120001_create_sessions.rb",
  "app/models/user.rb",
  "app/models/session.rb",
  "app/controllers/concerns/authentication.rb",
  "app/controllers/sessions_controller.rb",
  "app/controllers/registrations_controller.rb",
  "app/commands/user_command.rb",
  "app/views/sessions/new.html.erb",
  "app/views/sessions/_nav.html.erb",
  "app/views/registrations/new.html.erb",
  "test/support/app_test.rb",
  "test/authentication.rb",
  "test/admin.rb"
]

test "generate authentication writes the migrations, models, controllers, views and tests" do
  result = Cybertrain::CLI::Authentication.generate_with_result("shop")
  assert_equal AUTH_FILES, result.created
  assert_equal [], result.forced
  assert_equal [], result.manual
  AUTH_FILES.each { |f| assert(File.exist?("shop/#{f}"), "missing #{f}") }
end

test "the users migration has the NOT NULL columns, the admin flag and a unique index" do
  assert_equal <<~RUBY, read("shop/db/migrate/20260925120000_create_users.rb")
    class CreateUsers < Cybertrain::Migration::Base
      def change
        create_table "users" do |t|
          t.string "email_address", null: false
          t.string "password_digest", null: false
          t.boolean "admin", null: false, default: "false"
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
  # The messages come from the dictionary of the current locale.
  assert_includes model, "errors.add(:email_address, I18n.error_message(\"user\", :email_address, :taken)) if taken\n"
  assert_includes model, "errors.add(:password, I18n.error_message(\"user\", :password, :blank))\n"
  assert_includes model, "errors.add(:password, I18n.error_message(\"user\", :password, :too_short, { count: MIN_PASSWORD_LENGTH }))\n"
  assert_includes model, "attribute = I18n.human_attribute_name(\"user\", :password)\n"
  assert_includes model, "errors.add(:password_confirmation, I18n.error_message(\"user\", :password_confirmation, :confirmation, { attribute: attribute }))\n"
  assert model.index("errors.add(:password, \"").nil?
  # The admin flag, which require_admin asks for.
  assert_includes model, "  def admin? = admin\n"
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

      # Loads the Session row the cookie names (and its user); a stale or
      # expired id is dropped. Cookie Max-Age alone cannot stop replay:
      # authentication expires session_absolute_max_age seconds after
      # sign-in (SessionStore enforces the same on the cookie). A cookie
      # whose password key no longer matches (the password changed since
      # it signed in) ends its Session row.
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
        lifetime = Cybertrain.config.session_absolute_max_age
        if created_at.nil? || (lifetime > 0 && created_at.to_i + lifetime <= Time.now.to_i)
          session.delete(:session_id)
          return nil
        end
        user = found.user
        if user.nil? || !Cybertrain::Password.session_key_matches?(session[:password_key], user.password_digest)
          found.destroy
          session.delete(:session_id)
          return nil
        end
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
      # app/commands/user_command.rb). On the jobs page (config/routes.rb)
      # it runs alone, so a visitor gets the 404 too; in a controller that
      # declares `before_action :require_admin` itself,
      # require_authentication runs first and sends a visitor to sign in.
      def require_admin
        render plain: "Not Found", status: :not_found unless @current_user && @current_user.admin?
        nil
      end

      # Also stores the password key resume_session compares, and restarts
      # the cookie's absolute lifetime. After a password change, call
      # `session[:password_key] = Cybertrain::Password.session_key(user.password_digest)`
      # to keep the browser that changed it signed in.
      def start_new_session_for(user)
        started = Session.create(user_id: user.id, ip_address: request.client_ip,
                                 user_agent: request.header("user-agent").to_s)
        session.restart_lifetime!
        session[:session_id] = started.id
        session[:password_key] = Cybertrain::Password.session_key(user.password_digest)
        @current_session = started
        @current_user = user
        nil
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
  assert_equal "Cybertrain::Routes.draw do\n  jobs_page \"/admin/jobs\", before_action: :require_admin\nend\n", read("legacy/config/routes.rb")
  assert_equal false, Cybertrain::CLI::Authentication.enable_jobs_page("legacy/config/routes.rb", "legacy/app/controllers/application_controller.rb")
end

test "the controllers open their sign-in actions and the views post to the routes" do
  sessions = read("shop/app/controllers/sessions_controller.rb")
  assert_includes sessions, "class SessionsController < ApplicationController\n  allow_unauthenticated_access only: [:new, :create]\n"
  assert_includes sessions, "def new_action\n"
  # Sign-in attempts are rate limited, as Rails' generator does; the
  # exhausted client gets rate_limited's answer.
  assert_includes sessions, "  rate_limit to: 10, within: 3 * 60, only: [:create], with: :rate_limited\n"
  assert_includes sessions, "User.authenticate_by(email_address: params[:email_address].to_s, password: params[:password].to_s)"
  assert_includes sessions, "start_new_session_for(user)"
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

  sign_in = read("shop/app/views/sessions/new.html.erb")
  assert_includes sign_in, "<%= form_with(url: session_path) do |f| %>"
  assert_includes sign_in, "<%= f.email_field :email_address, autocomplete: \"username\", autofocus: true %>"
  assert_includes sign_in, "<%= f.password_field :password, autocomplete: \"current-password\" %>"
  assert_includes sign_in, "<h1><%= t(\".title\") %></h1>\n"
  assert_includes sign_in, "<%= f.label :email_address, t(\".email_address\") %>"
  assert_includes sign_in, "<%= f.submit t(\".submit\") %>"
  assert_includes sign_in, "<p><%= link_to t(\".sign_up\"), sign_up_path %></p>\n"
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

SHOP_KEYS = ["errors.template.header",
             "registrations.create.welcome", "registrations.new.model", "registrations.new.sign_in",
             "registrations.new.submit", "registrations.new.title",
             "sessions.create.invalid", "sessions.create.rate_limited", "sessions.destroy.signed_out",
             "sessions.nav.sign_in", "sessions.nav.sign_out",
             "sessions.new.email_address", "sessions.new.password", "sessions.new.sign_up",
             "sessions.new.submit", "sessions.new.title"]

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
  assert_equal "You have been signed out.", bundled("en", "sessions.destroy.signed_out")
  assert_equal "Welcome! You have signed up.", bundled("en", "registrations.create.welcome")
  # The form labels of User come from activerecord.attributes.user.
  assert_equal "Email address", bundled("en", "activerecord.attributes.user.email_address")
  assert_equal "メールアドレス", bundled("ja", "activerecord.attributes.user.email_address")
  assert_equal "パスワード（確認用）", bundled("ja", "activerecord.attributes.user.password_confirmation")
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
      get "/sign_up", to: "registrations#new", as: "sign_up"
      post "/sign_up", to: "registrations#create"
      jobs_page "/admin/jobs", before_action: :require_admin
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
      get "/sign_up", to: "registrations#new", as: "sign_up"
      post "/sign_up", to: "registrations#create"
      resources :products
      jobs_page "/admin/jobs", before_action: :require_admin
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
  "app/commands/user_command.rb",
  "app/views/sessions/new.html.erb",
  "app/views/sessions/_nav.html.erb",
  "app/views/setup/new.html.erb",
  "test/support/app_test.rb",
  "test/authentication.rb",
  "test/admin.rb"
]

test "--invite-only writes the user command and /setup instead of the sign-up page" do
  Cybertrain::CLI::NewApp.create("club", "{ path = \"../cybertrain\" }")
  status = Dir.chdir("club") { Cybertrain::CLI.run(["generate", "authentication", "--invite-only"]) }
  assert_equal 0, status
  INVITE_FILES.each { |f| assert(File.exist?("club/#{f}"), "missing #{f}") }
  assert_equal INVITE_FILES.size, INVITE_FILES.select { |f| File.exist?("club/#{f}") }.size
  # The same concern, whichever the mode.
  assert_equal read("shop/app/controllers/concerns/authentication.rb"), read("club/app/controllers/concerns/authentication.rb")
  refute File.exist?("club/app/controllers/registrations_controller.rb")
  refute File.exist?("club/app/views/registrations/new.html.erb")
  # No link to a sign-up page that does not exist.
  sign_in_view = read("club/app/views/sessions/new.html.erb")
  assert sign_in_view.end_with?("  </div>\n<% end %>\n"), sign_in_view
  assert sign_in_view.index("sign_up").nil?
  assert_equal <<~RUBY, read("club/config/routes.rb")
    Cybertrain::Routes.draw do
      resource :session, only: [:new, :create, :destroy]
      get "/setup", to: "setup#new", as: "setup"
      post "/setup", to: "setup#create"
      jobs_page "/admin/jobs", before_action: :require_admin
    end
  RUBY
end

test "--invite-only's screens go through t, with keys the bundled dictionaries have" do
  assert_equal [], untranslated("club")
  keys = ["errors.template.header",
          "sessions.create.invalid", "sessions.create.rate_limited", "sessions.destroy.signed_out",
          "sessions.nav.sign_in", "sessions.nav.sign_out",
          "sessions.new.email_address", "sessions.new.password", "sessions.new.submit", "sessions.new.title",
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
  assert_includes club_config, "  c.setting_bool :setup_open, env: \"CLUB_SETUP_OPEN\", default: false\n\n  # c.port = 3000\n"
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
