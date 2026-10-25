# `cybertrain generate authentication`: email-and-password sign-in, the way
# Rails 8's `bin/rails generate authentication` writes it, as code the
# application owns (docs/design.md D15):
#
#   db/migrate/*_create_users.rb, *_create_sessions.rb
#   app/models/user.rb, app/models/session.rb
#   app/controllers/sessions_controller.rb, registrations_controller.rb
#   app/views/sessions/new.html.erb, _nav.html.erb, registrations/new.html.erb
#   test/authentication.rb, test/support/app_test.rb
#
# and three edits: `before_action`s and the sign-in helpers into
# app/controllers/application_controller.rb, the routes into
# config/routes.rb and the nav partial into the layout (plus a sign-in in
# any test/attachment_*.rb written before it, which now needs one). Every
# file is written once (Templates.write never overwrites) and every edit is
# made once, so running the generator again is harmless.
#
# Sign-in attempts are rate limited as in Rails' generator (`rate_limit to:
# 10, within: 3 * 60, only: [:create]`, per client address, per process;
# docs/design.md D26), and AppTest.sign_in resets the counts so a test
# suite never reaches the limit.
#
# What it leaves out, and why: password reset (needs a mailer, which
# cybertrain does not have) and a `Current` object (templates read `@current_user` instead, an ivar
# `resume_session` sets on every controller). What it adds that Rails'
# does not: a sign-up page, because there is no console to create the first
# user in (Spinel has no `eval`).
#
# `--invite-only` (docs/design.md D29) writes no sign-up page. Instead:
#
#   app/commands/user_command.rb   `./<app> user EMAIL [PASSWORD]`, a
#                                  Main.command that creates a user or sets
#                                  its password (from stdin when not given),
#                                  and the boot warning while no user exists
#   app/controllers/setup_controller.rb, app/views/setup/new.html.erb
#                                  /setup, the first user's form: only while
#                                  no user exists, only with the one-time
#                                  token the boot warning prints, only from
#                                  loopback unless <APP>_SETUP_OPEN=1
#
# plus two more edits: the require and the warning into bin/<app>.rb
# (before `exit(Cybertrain::Main.run(`), and the `setup_open` setting into
# config/app.rb's configure block.
require "cybertrain/cli/templates"
require "cybertrain/cli/scaffold"
require "cybertrain/cli/build"

module Cybertrain
  module CLI
    module Authentication
      CLASS_LINE = "class ApplicationController < Cybertrain::Controller"
      ROUTE_MARK = "resource :session"
      NAV_LINE = "<%= render \"sessions/nav\" %>"
      # What an app test's new_client needs once the app has authentication:
      # empty the two tables, then a user signed in through the form.
      # `generate attachment` writes them into its test when app/models/user.rb
      # exists; add_sign_in_to_attachment_tests adds them to a test written
      # before this generator ran.
      TEST_RESET_LINES = "  Session.all.delete_all\n  User.all.delete_all\n"
      TEST_SIGN_IN_LINES = "  AppTest.user\n  AppTest.sign_in(client)\n"
      NEW_CLIENT_LINE = "def new_client"
      TEST_CLIENT_LINE = "  client = Cybertrain::Test::Client.new(APP)"
      # --invite-only's two edits: bin/<app>.rb gets the command file and the
      # boot warning before this line, config/app.rb the setting after this one.
      MAIN_RUN_LINE = "exit(Cybertrain::Main.run("
      CONFIGURE_LINE = "Cybertrain.configure do |c|"
      COMMAND_REQUIRE = "require_relative \"../app/commands/user_command\""

      # Returns the paths it created. Raises InvalidArgument, before anything
      # is written, when `root` is not an application (no config/routes.rb
      # with the draw line, no app/controllers/application_controller.rb
      # with the class line; with `invite_only`, no bin/<app>.rb with the
      # Main.run line or no config/app.rb with the configure line).
      def self.generate(root, invite_only = false)
        routes_path = File.join(root, "config/routes.rb")
        raise InvalidArgument, "#{routes_path} not found: run this inside a cybertrain app" unless File.exist?(routes_path)
        raise InvalidArgument, "#{routes_path} has no `#{Scaffold::DRAW_LINE}` line" if File.read(routes_path).index(Scaffold::DRAW_LINE).nil?

        controller_path = File.join(root, "app/controllers/application_controller.rb")
        raise InvalidArgument, "#{controller_path} not found: run this inside a cybertrain app" unless File.exist?(controller_path)
        raise InvalidArgument, "#{controller_path} has no `#{CLASS_LINE}` line" if File.read(controller_path).index(CLASS_LINE).nil?

        app = ""
        if invite_only
          app = Build.app_name(root)
          raise InvalidArgument, "#{root}/spin.toml has no [package] name: run this inside a cybertrain app" if app == ""

          bin_path = File.join(root, "bin/#{app}.rb")
          raise InvalidArgument, "#{bin_path} not found: run this inside a cybertrain app" unless File.exist?(bin_path)
          raise InvalidArgument, "#{bin_path} has no line starting with `#{MAIN_RUN_LINE}`" if line_start(File.read(bin_path), MAIN_RUN_LINE) < 0

          config_path = File.join(root, "config/app.rb")
          raise InvalidArgument, "#{config_path} not found: run this inside a cybertrain app" unless File.exist?(config_path)
          raise InvalidArgument, "#{config_path} has no `#{CONFIGURE_LINE}` line" if File.read(config_path).index(CONFIGURE_LINE).nil?
        end

        created = Array.new(0) { "" }
        users = migration_path(root, "users")
        record(created, root, users, users_migration)
        record(created, root, migration_path(root, "sessions"), sessions_migration)
        record(created, root, "app/models/user.rb", user_model)
        record(created, root, "app/models/session.rb", session_model)
        record(created, root, "app/controllers/sessions_controller.rb", sessions_controller)
        if invite_only
          record(created, root, "app/controllers/setup_controller.rb", setup_controller(app))
          record(created, root, "app/commands/user_command.rb", user_command(app))
        else
          record(created, root, "app/controllers/registrations_controller.rb", registrations_controller)
        end
        record(created, root, "app/views/sessions/new.html.erb", sessions_new_view(invite_only))
        record(created, root, "app/views/sessions/_nav.html.erb", nav_partial)
        if invite_only
          record(created, root, "app/views/setup/new.html.erb", setup_new_view)
        else
          record(created, root, "app/views/registrations/new.html.erb", registrations_new_view)
        end
        record(created, root, "test/support/app_test.rb", app_test_support)
        record(created, root, "test/authentication.rb", invite_only ? invite_only_test(app) : authentication_test)
        add_to_application_controller(controller_path)
        add_routes(routes_path, invite_only)
        add_nav_to_layout(File.join(root, "app/views/layouts/application.html.erb"))
        add_sign_in_to_attachment_tests(root)
        if invite_only
          add_command_to_bin(File.join(root, "bin/#{app}.rb"), app)
          add_setting_to_config(File.join(root, "config/app.rb"), app)
        end
        created
      end

      def self.record(created, root, path, content)
        created << path if Templates.write(root, path, content) == "create"
        nil
      end

      # db/migrate/<version>_create_<table>.rb, or the existing one; the
      # second table's version follows the first's (Scaffold.next_version).
      def self.migration_path(root, table)
        suffix = "_create_#{table}.rb"
        existing = Dir.glob(File.join(root, "db/migrate/*#{suffix}")).sort
        return "db/migrate/#{File.basename(existing[0])}" unless existing.empty?

        "db/migrate/#{Scaffold.next_version(root, Scaffold.timestamp)}#{suffix}"
      end

      # Inserts the authentication block right after the class line, once
      # (the block's own `def require_authentication` marks a file that has
      # it). Returns true when the file was changed.
      def self.add_to_application_controller(path)
        source = File.read(path)
        unless source.index("def require_authentication").nil?
          puts "identical app/controllers/application_controller.rb (authentication already added)"
          return false
        end

        File.write(path, insert_after_line(source, CLASS_LINE, indent(application_controller_block)))
        puts "insert app/controllers/application_controller.rb (authentication)"
        true
      end

      # Inserts the sign-in and sign-up (or setup) routes after the draw
      # line, once.
      def self.add_routes(path, invite_only = false)
        source = File.read(path)
        unless source.index(ROUTE_MARK).nil?
          puts "identical route #{ROUTE_MARK}"
          return false
        end

        File.write(path, insert_after_line(source, Scaffold::DRAW_LINE, indent(routes_block(invite_only))))
        puts "route #{ROUTE_MARK}, get/post #{invite_only ? "/setup" : "/sign_up"}"
        true
      end

      # --invite-only: requires app/commands/user_command.rb (which registers
      # the `user` command) and runs its boot warning, just before the
      # Main.run line of bin/<app>.rb, once.
      def self.add_command_to_bin(path, app)
        name = "bin/#{app}.rb"
        source = File.read(path)
        unless source.index(COMMAND_REQUIRE).nil?
          puts "identical #{name} (user command already required)"
          return false
        end

        File.write(path, insert_before_line(source, MAIN_RUN_LINE, bin_block(app)))
        puts "insert #{name} (./#{app} user, the first-run warning)"
        true
      end

      # --invite-only: declares the setup_open setting at the top of
      # config/app.rb's configure block, once.
      def self.add_setting_to_config(path, app)
        source = File.read(path)
        unless source.index("setting_bool :setup_open").nil?
          puts "identical config/app.rb (setup_open already declared)"
          return false
        end

        File.write(path, insert_after_line(source, CONFIGURE_LINE, indent(config_block(app))))
        env = setup_env(app)
        puts "insert config/app.rb (#{env})"
        true
      end

      # The environment variable that opens /setup to any address:
      # SHOP_SETUP_OPEN for the app shop.
      def self.setup_env(app)
        "#{app.upcase}_SETUP_OPEN"
      end

      # Renders the nav partial at the top of <main> in the layout, once;
      # a layout without a `<main>` line is left alone with a note.
      def self.add_nav_to_layout(path)
        unless File.exist?(path)
          puts "skip app/views/layouts/application.html.erb (not found): render \"sessions/nav\" in your layout"
          return false
        end

        source = File.read(path)
        unless source.index("sessions/nav").nil?
          puts "identical app/views/layouts/application.html.erb (nav already rendered)"
          return false
        end
        at = source.index("<main>")
        if at.nil?
          puts "skip app/views/layouts/application.html.erb (no <main>): add #{NAV_LINE} to your layout"
          return false
        end

        File.write(path, insert_after_line(source, "<main>", "      #{NAV_LINE}\n"))
        puts "insert app/views/layouts/application.html.erb (#{NAV_LINE})"
        true
      end

      # A test/attachment_*.rb written by `generate attachment` before this
      # generator ran drives the forms anonymously, which every action now
      # redirects to the sign-in page. Its new_client gets the reset and
      # sign-in lines, once (AppTest.sign_in marks a test that has them); a
      # new_client rewritten past recognition is left alone with a note.
      def self.add_sign_in_to_attachment_tests(root)
        Dir.glob(File.join(root, "test/attachment_*.rb")).sort.each do |path|
          name = "test/#{File.basename(path)}"
          source = File.read(path)
          unless source.index("AppTest.sign_in(").nil?
            puts "identical #{name} (signs in already)"
            next
          end
          if source.index(NEW_CLIENT_LINE).nil? || source.index(TEST_CLIENT_LINE).nil?
            puts "skip #{name} (no new_client): sign in there with AppTest.user and AppTest.sign_in(client)"
            next
          end

          source = insert_after_line(source, NEW_CLIENT_LINE, TEST_RESET_LINES)
          File.write(path, insert_after_line(source, TEST_CLIENT_LINE, TEST_SIGN_IN_LINES))
          puts "insert #{name} (sign in first)"
        end
        nil
      end

      # `text` with two spaces in front of every non-blank line: the heredocs
      # below are written flush (`<<~` strips their indentation), and what
      # goes inside a class body or a draw block is indented here.
      def self.indent(text)
        out = +""
        text.each_line { |line| out << (line == "\n" ? line : "  #{line}") }
        out
      end

      # `source` with `block` (its own lines, each ending in a newline)
      # inserted right after the first line containing `marker`.
      def self.insert_after_line(source, marker, block)
        at = source.index(marker)
        raise InvalidArgument, "no `#{marker}` line to insert after" if at.nil?

        eol = source.index("\n", at)
        eol = source.size if eol.nil?
        updated = +""
        updated << source[0, eol] << "\n"
        updated << block
        rest = source[eol + 1, source.size - eol - 1].to_s
        updated << rest
        updated << "\n" unless updated.end_with?("\n")
        updated
      end

      # Where the first line that starts with `marker` starts, or -1.
      def self.line_start(source, marker)
        return 0 if source.start_with?(marker)

        found = source.index("\n#{marker}")
        found.nil? ? -1 : found + 1
      end

      # `source` with `block` inserted right before the first line that
      # starts with `marker`.
      def self.insert_before_line(source, marker, block)
        start = line_start(source, marker)
        raise InvalidArgument, "no line starting with `#{marker}` to insert before" if start < 0

        updated = +""
        updated << source[0, start].to_s
        updated << block
        updated << source[start, source.size - start].to_s
        updated
      end

      # ---- the files ----------------------------------------------------

      def self.users_migration
        <<~RUBY
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
      end

      def self.sessions_migration
        <<~RUBY
          class CreateSessions < Cybertrain::Migration::Base
            def change
              create_table "sessions" do |t|
                t.references :user
                t.string "ip_address"
                t.string "user_agent"
                t.timestamps
              end
            end
          end
        RUBY
      end

      def self.user_model
        <<~RUBY
          # Columns (email_address, password_digest), the Cybertrain::Model
          # superclass and `sessions` (from the sessions table's foreign key) come
          # from gen/models/user.rb, generated from db/schema.rb by `spin run gen`.
          #
          # Written by `cybertrain generate authentication`; it is yours to change.
          # The password is hashed by Cybertrain::Password (PBKDF2-HMAC-SHA256) into
          # password_digest; the plain text lives only in @password until the
          # record is saved. `password=` and `authenticate` are what Rails'
          # `has_secure_password` would define (Spinel cannot define methods at
          # run time, so they are written out).
          class User
            MIN_PASSWORD_LENGTH = 8

            validates :email_address, presence: true

            # Normalizes the address, refuses a taken one, and checks the password
            # on a new record or whenever one was given. Errors added here make
            # the record invalid (Cybertrain::Model.before_validation).
            before_validation do |user|
              user.email_address = User.normalize_email_address(user.email_address)
              user.validate_email_address_taken
              user.validate_password
            end

            # The address lowercased and trimmed: "  Ann@Example.COM " is
            # "ann@example.com", so a visitor signs in however they type it.
            def self.normalize_email_address(value)
              value.to_s.strip.downcase
            end

            # The user with this address and password, or nil. A missing address
            # costs a verification too (against Cybertrain::Password.dummy_digest),
            # so the response time does not say which of the two was wrong.
            def self.authenticate_by(email_address:, password:)
              user = User.find_by(email_address: User.normalize_email_address(email_address))
              if user.nil?
                Cybertrain::Password.verify_serialized(password.to_s, Cybertrain::Password.dummy_digest)
                return nil
              end
              user.authenticate(password) ? user : nil
            end

            # The plain-text password given to `password=` in this request ("" when
            # none was), for the validations; never stored.
            def password
              plain = @password
              plain.nil? ? "" : plain
            end

            # Hashes the password into password_digest. A blank password clears
            # the digest, which `validate_password` reports.
            def password=(plain)
              text = plain.to_s
              @password = text
              self.password_digest = text.empty? ? "" : Cybertrain::Password.hash(text)
            end

            # What the sign-up form sends back a second time; nil until set, so a
            # form without the field is not asked to match.
            def password_confirmation
              @password_confirmation
            end

            def password_confirmation=(plain)
              @password_confirmation = plain.to_s
            end

            # Whether `plain` is this user's password. A digest hashed with fewer
            # iterations than Cybertrain::Password.iterations is rehashed and
            # saved on the way, so raising the cost in config/app.rb upgrades
            # everyone as they sign in (and, the digest being new, signs their
            # other browsers out once). verify_serialized runs one verification
            # at a time, so a burst of sign-ins does not hold every worker.
            def authenticate(plain)
              return false unless Cybertrain::Password.verify_serialized(plain.to_s, password_digest)

              if Cybertrain::Password.needs_rehash?(password_digest)
                self.password_digest = Cybertrain::Password.hash(plain.to_s)
                save
              end
              true
            end

            # Public so the before_validation block above (which receives the
            # record, not an implicit self) can call them.

            def validate_email_address_taken
              address = email_address
              return nil if address.nil? || address.empty?

              taken = User.where(email_address: address).where_sql("id != ?", [id]).exists?
              errors.add(:email_address, "has already been taken") if taken
              nil
            end

            def validate_password
              given = password
              if password_digest.to_s.empty?
                errors.add(:password, "can't be blank")
              elsif !given.empty? && given.size < MIN_PASSWORD_LENGTH
                errors.add(:password, "is too short (minimum is \#{MIN_PASSWORD_LENGTH} characters)")
              end
              confirmation = @password_confirmation
              errors.add(:password_confirmation, "doesn't match Password") if !confirmation.nil? && confirmation != given
              nil
            end
          end
        RUBY
      end

      def self.session_model
        <<~RUBY
          # One signed-in browser: a row the cookie session points at by id
          # (ApplicationController#resume_session), with the address and user
          # agent that created it, so a user can be signed out everywhere by
          # deleting their rows. Columns, the Cybertrain::Model superclass and
          # `user` (from the user_id foreign key) come from gen/models/session.rb.
          #
          # Not to be confused with Cybertrain::Session, the signed cookie that
          # holds this row's id as `session[:session_id]`.
          class Session
          end
        RUBY
      end

      # Inserted (indented) after the class line of
      # app/controllers/application_controller.rb.
      def self.application_controller_block
        <<~RUBY
          # ---- Authentication (cybertrain generate authentication) -------------
          # Every action needs a signed-in user unless its controller opens it:
          # `allow_unauthenticated_access only: [:new, :create]`. resume_session
          # sets @current_user (and @current_session), which templates can read.
          before_action :resume_session
          before_action :require_authentication

          def self.allow_unauthenticated_access(only: [], except: [])
            skip_before_action(:require_authentication, only: only, except: except)
          end

          # @return [Boolean] whether this request has a signed-in user
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
          # ---- end of authentication ------------------------------------------

        RUBY
      end

      def self.sessions_controller
        <<~RUBY
          # Sign in and out (cybertrain generate authentication).
          class SessionsController < ApplicationController
            allow_unauthenticated_access only: [:new, :create]
            # Ten sign-in attempts per client address every three minutes, then
            # back to the form until the window closes. Behind a reverse proxy on
            # this host, set CYBERTRAIN_TRUSTED_PROXY=1 so that each visitor is
            # counted rather than the proxy (README, "Rate limiting").
            rate_limit to: 10, within: 3 * 60, only: [:create],
                       redirect_to: "/session/new", alert: "Try again later."

            # GET /session/new
            # (named new_action: a `new` method would shadow SessionsController.new)
            def new_action
            end

            # POST /session
            def create
              user = User.authenticate_by(email_address: params[:email_address].to_s, password: params[:password].to_s)
              if user.nil?
                flash[:alert] = "Try another email address or password."
                redirect_to new_session_path, status: :see_other
              else
                start_new_session_for(user)
                redirect_to after_authentication_url, status: :see_other
              end
            end

            # DELETE /session
            def destroy
              terminate_session
              flash[:notice] = "You have been signed out."
              redirect_to new_session_path, status: :see_other
            end
          end
        RUBY
      end

      def self.registrations_controller
        <<~RUBY
          # Sign up (cybertrain generate authentication). Rails' generator has no
          # sign-up page and expects the first user to be created in the console;
          # cybertrain has no console, so this is how the first user gets in.
          # Delete it (and its routes) for an invitation-only application.
          class RegistrationsController < ApplicationController
            allow_unauthenticated_access only: [:new, :create]

            # GET /sign_up
            def new_action
              @user = User.new
            end

            # POST /sign_up
            def create
              fields = params.require(:user)
              @user = User.new(fields.permit(:email_address))
              @user.password = fields[:password].to_s
              @user.password_confirmation = fields[:password_confirmation].to_s
              if @user.save
                start_new_session_for(@user)
                flash[:notice] = "Welcome! You have signed up."
                redirect_to after_authentication_url, status: :see_other
              else
                render :new, status: :unprocessable_entity
              end
            end
          end
        RUBY
      end

      # With --invite-only there is no sign-up page to link to.
      def self.sessions_new_view(invite_only = false)
        view = <<~ERB
          <h1>Sign in</h1>

          <%= form_with(url: session_path) do |f| %>
            <div class="field">
              <%= f.label :email_address %>
              <%= f.email_field :email_address, autocomplete: "username", autofocus: true %>
            </div>

            <div class="field">
              <%= f.label :password %>
              <%= f.password_field :password, autocomplete: "current-password" %>
            </div>

            <div class="actions">
              <%= f.submit "Sign in" %>
            </div>
          <% end %>
        ERB
        return view if invite_only

        "#{view}\n<p><%= link_to \"Sign up\", sign_up_path %></p>\n"
      end

      def self.nav_partial
        <<~ERB
          <%# locals: () %>
          <nav class="session">
            <% if @current_user %>
              <span><%= @current_user.email_address %></span>
              <%= button_to "Sign out", session_path, method: :delete %>
            <% else %>
              <%= link_to "Sign in", new_session_path %>
            <% end %>
          </nav>
        ERB
      end

      def self.registrations_new_view
        <<~ERB
          <h1>Sign up</h1>

          <%= form_with(model: @user, url: sign_up_path) do |f| %>
            <% if @user.errors.any? %>
              <div id="error_explanation">
                <h2><%= pluralize(@user.errors.count, "error") %> prohibited this account from being created:</h2>
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
              <%= f.label :password %>
              <%= f.password_field :password, autocomplete: "new-password" %>
            </div>

            <div class="field">
              <%= f.label :password_confirmation %>
              <%= f.password_field :password_confirmation, autocomplete: "new-password" %>
            </div>

            <div class="actions">
              <%= f.submit "Sign up" %>
            </div>
          <% end %>

          <p><%= link_to "Sign in", new_session_path %></p>
        ERB
      end

      # ---- --invite-only ------------------------------------------------

      # The first user's page (--invite-only).
      def self.setup_controller(app)
        env = setup_env(app)
        <<~RUBY
          # First-run setup (cybertrain generate authentication --invite-only):
          # the form that creates the first user and signs them in. It answers
          # only while no user exists, only with the one-time token the server
          # prints at boot (/setup?token=..., carried back by the form in a
          # hidden field), and only to a connection from this machine
          # (request.loopback?, the socket's peer address) that did not come
          # through a proxy (no X-Forwarded-For header). #{env}=1
          # (config/app.rb) lifts the address check (never the token) while no
          # user exists, for a first run behind a proxy on another host; unset
          # it again afterwards. Anyone else gets a 404, as if there were no
          # such page. Later users are created with `./#{app} user EMAIL`
          # (app/commands/user_command.rb).
          class SetupController < ApplicationController
            allow_unauthenticated_access only: [:new, :create]
            before_action :require_first_run

            # The one-time token: 32 random hex characters, made when the
            # program starts and the same until it exits (a restart makes a new
            # one). The address check alone is not enough: a proxy on this host
            # that adds no X-Forwarded-For makes every client a loopback one.
            # Printed only by the boot [WARN] (UserCommand.warn_if_no_user) and
            # rendered only into the form's hidden field. A constant, which
            # Spinel keeps alive (a class variable it would not).
            SETUP_TOKEN = Cybertrain::Crypto.random_token(16)

            # The token /setup asks for: the boot warning prints it, the app's
            # test passes it.
            def self.setup_token
              SETUP_TOKEN
            end

            # GET /setup
            def new_action
              @user = User.new
            end

            # POST /setup
            def create
              fields = params.require(:user)
              @user = User.new(fields.permit(:email_address))
              @user.password = fields[:password].to_s
              @user.password_confirmation = fields[:password_confirmation].to_s
              if @user.save
                start_new_session_for(@user)
                flash[:notice] = "Welcome! Your account has been created."
                redirect_to "/", status: :see_other
              else
                render :new, status: :unprocessable_entity
              end
            end

            private

            # A missing or wrong token is the same 404 as the other refusals;
            # the comparison takes as long however much of it matched.
            def require_first_run
              @setup_token = params[:token].to_s
              head :not_found unless setup_open? && Cybertrain::Crypto.secure_compare(@setup_token, SetupController.setup_token)
              nil
            end

            # A header never opens the page; it can only close it: behind a proxy
            # on this host every request is a loopback one, and the proxy adds
            # X-Forwarded-For.
            def setup_open?
              return false if User.all.exists?
              return true if Cybertrain.config.bool_setting(:setup_open)

              request.loopback? && request.header("x-forwarded-for").nil?
            end
          end
        RUBY
      end

      def self.setup_new_view
        <<~ERB
          <h1>Set up</h1>

          <p>Create the first account. This page is only shown on this machine,
          with the link the server printed when it started, and only until an
          account exists.</p>

          <%= form_with(model: @user, url: setup_path) do |f| %>
            <input type="hidden" name="token" value="<%= @setup_token %>">

            <% if @user.errors.any? %>
              <div id="error_explanation">
                <h2><%= pluralize(@user.errors.count, "error") %> prohibited this account from being created:</h2>
                <ul>
                  <% @user.errors.full_messages.each do |message| %>
                    <li><%= message %></li>
                  <% end %>
                </ul>
              </div>
            <% end %>

            <div class="field">
              <%= f.label :email_address %>
              <%= f.email_field :email_address, autocomplete: "username", autofocus: true %>
            </div>

            <div class="field">
              <%= f.label :password %>
              <%= f.password_field :password, autocomplete: "new-password" %>
            </div>

            <div class="field">
              <%= f.label :password_confirmation %>
              <%= f.password_field :password_confirmation, autocomplete: "new-password" %>
            </div>

            <div class="actions">
              <%= f.submit "Create account" %>
            </div>
          <% end %>
        ERB
      end

      # app/commands/user_command.rb (--invite-only): the `user` command and
      # the boot warning, required from bin/<app>.rb (and from the app's
      # test, which runs the command through Main.run).
      def self.user_command(app)
        <<~RUBY
          # `./#{app} user EMAIL [PASSWORD]` (cybertrain generate authentication
          # --invite-only): creates the user with this address, or sets the
          # password of the one that has it (which signs that user's browsers
          # out: their sessions' password key no longer matches). Without
          # PASSWORD it is read from standard input, one line, so that it stays
          # out of `ps` and the shell history:
          #
          #   ./#{app} user ann@example.com          # type it, then Enter (it is echoed)
          #   printf '%s' "$PASSWORD" | ./#{app} user ann@example.com
          #
          # Registered with Cybertrain::Main.command, which connects the database
          # first (README, "Application commands"). Required by bin/#{app}.rb,
          # which also calls UserCommand.warn_if_no_user before serving.
          # Written by the generator; it is yours to change.
          module UserCommand
            USAGE = "usage: ./#{app} user EMAIL [PASSWORD] (without PASSWORD, it is read from standard input)"

            # The exit status: 0 when the user was created or updated, 1 for bad
            # arguments, an empty password or a record that does not validate.
            def self.run(argv)
              if argv.empty? || argv.size > 2 || argv[0].start_with?("-")
                puts USAGE
                return 1
              end
              password = argv.size == 2 ? argv[1] : UserCommand.read_password
              if password.empty?
                puts "error: the password is empty"
                return 1
              end

              address = User.normalize_email_address(argv[0])
              found = User.find_by(email_address: address)
              created = found.nil?
              user = found.nil? ? User.new(email_address: address) : found
              user.password = password
              unless user.save
                user.errors.full_messages.each { |message| puts "error: \#{message}" }
                return 1
              end
              puts created ? "created \#{address}" : "updated \#{address}"
              0
            end

            # One line of standard input, with a prompt when it is a terminal.
            def self.read_password
              if STDIN.tty?
                STDOUT.print("Password: ")
                STDOUT.flush
              end
              line = STDIN.gets
              UserCommand.password_from(line.nil? ? "" : line)
            end

            # The text without one trailing newline ("\\n" or "\\r\\n"), which a
            # terminal or `echo` adds. Anything else, spaces too, is the password.
            def self.password_from(text)
              s = text.to_s
              s = s[0, s.size - 1].to_s if s.end_with?("\\n")
              s = s[0, s.size - 1].to_s if s.end_with?("\\r")
              s
            end

            # Called by bin/#{app}.rb before the server boots: a [WARN] while no
            # user exists, which is while /setup is open, with the page's
            # one-time token (SetupController.setup_token, this process's own).
            # Says nothing when the users table is not there yet (`./#{app}
            # migrate` comes first).
            def self.warn_if_no_user
              Cybertrain.logger.warn("no user exists yet: run ./#{app} user EMAIL, or open /setup?token=\#{SetupController.setup_token} from this machine") if UserCommand.no_user?
              nil
            end

            # Connects for the question only: Application#boot connects the
            # server's own pool afterwards.
            def self.no_user?
              begin
                Cybertrain::DB.connect(Cybertrain.config.database_path, size: 1)
                !User.all.exists?
              rescue Cybertrain::DB::Error
                false
              ensure
                Cybertrain::DB.disconnect
              end
            end
          end

          Cybertrain::Main.command("user", "EMAIL [PASSWORD]: create a user or set its password") do |argv|
            UserCommand.run(argv)
          end
        RUBY
      end

      # Inserted before the Main.run line of bin/<app>.rb (--invite-only).
      def self.bin_block(app)
        <<~RUBY
          # `./#{app} user EMAIL [PASSWORD]`, and a [WARN] at boot while no user
          # exists (cybertrain generate authentication --invite-only).
          #{COMMAND_REQUIRE}
          UserCommand.warn_if_no_user if Cybertrain::Main.server?(ARGV)

        RUBY
      end

      # Inserted (indented) after the configure line of config/app.rb
      # (--invite-only).
      def self.config_block(app)
        env = setup_env(app)
        <<~RUBY
          # /setup (the first user's page) answers only to this machine, with the
          # token the boot warning prints, while no user exists; #{env}=1
          # opens it to any address (the token is still needed), for a first
          # run behind a proxy on another host. Unset it once the user exists.
          c.setting_bool :setup_open, env: "#{env}", default: false

        RUBY
      end

      # Inserted (indented) after the draw line of config/routes.rb.
      def self.routes_block(invite_only = false)
        if invite_only
          return <<~RUBY
            resource :session, only: [:new, :create, :destroy]
            get "/setup", to: "setup#new", as: "setup"
            post "/setup", to: "setup#create"
          RUBY
        end

        <<~RUBY
          resource :session, only: [:new, :create, :destroy]
          get "/sign_up", to: "registrations#new", as: "sign_up"
          post "/sign_up", to: "registrations#create"
        RUBY
      end

      # ---- tests --------------------------------------------------------

      # The same shape as examples/blog/test/support/blog_test.rb: boots the
      # app on a fresh test database. Shared by every test file; copy
      # helpers into it as the app grows.
      def self.app_test_support
        <<~RUBY
          # Shared setup for the integration tests (test/*.rb): the app booted in
          # the test environment on a fresh storage/test.sqlite3. Required by the
          # test files, not run (`spin test` runs test/*.rb only).
          ENV["CYBERTRAIN_ENV"] = "test"

          require "cybertrain"
          require "cybertrain/test/client"
          require_relative "../../config/app"
          require_relative "../../gen/app"
          require_relative "../../gen/migrations"

          # No request log: `spin test` diffs the whole output against the
          # snapshot, and "Completed 303 in 246ms" is never the same twice.
          Cybertrain.config.log_level = :none

          module AppTest
            # Deletes the test database (and its WAL files), migrates a new one
            # and boots the application on it.
            def self.boot
              path = Cybertrain.config.database_path
              [path, "\#{path}-wal", "\#{path}-shm"].each { |f| File.delete(f) if File.exist?(f) }
              connection = Cybertrain::DB::Connection.new(path)
              Cybertrain::DB::Migrator.new(connection).migrate(Cybertrain::Migration.all)
              connection.close

              app = Cybertrain::Application.new(
                router: Gen::Routes.build(Cybertrain::Router.new),
                url_resolver: Gen::Routes.url_resolver
              )
              app.boot
            end

            # The authenticity_token of the first form in the last response, as
            # a browser would submit it back.
            def self.form_token(client)
              body = client.response.body
              marker = "name=\\"authenticity_token\\" value=\\""
              at = body.index(marker)
              raise "no authenticity_token in the last response" if at.nil?

              start = at + marker.size
              stop = body.index("\\"", start)
              raise "unterminated authenticity_token" if stop.nil?

              body[start, stop - start].to_s
            end

            # A user with this address and password (both normalized the way the
            # forms are).
            def self.user(email_address = "ann@example.com", password = "s3cr3t-s3cr3t")
              user = User.new(email_address: email_address)
              user.password = password
              user.save!
              user
            end

            # Signs `client` in through the form, as a browser would. Every test
            # client has the same address, so the sign-in rate limit's counts
            # are forgotten first: a suite signs in far more than ten times.
            def self.sign_in(client, email_address = "ann@example.com", password = "s3cr3t-s3cr3t")
              Cybertrain::RateLimit.reset_all!
              client.get("/session/new")
              client.post("/session", { "authenticity_token" => form_token(client),
                                        "email_address" => email_address,
                                        "password" => password })
            end
          end

          APP = AppTest.boot
        RUBY
      end

      # test/authentication.rb: the head (requires, new_client, the sign-in
      # form), the sign-up or first-run tests, then the sign-in and sign-out
      # tests both variants share.
      # The pieces go through locals and `<<`: an interpolation of three
      # method calls could free one result while building the next under
      # Spinel (spikes/NOTES.md rule 65), and the CLI compiles there too.
      def self.authentication_test
        head = authentication_test_head(false)
        middle = sign_up_tests
        join_three(head, middle, authentication_test_tail)
      end

      # --invite-only's test/authentication.rb.
      def self.invite_only_test(app)
        head = authentication_test_head(true)
        middle = setup_tests(app)
        join_three(head, middle, authentication_test_tail)
      end

      def self.join_three(first, second, third)
        out = +""
        out << first << second << third
        out
      end

      def self.authentication_test_head(invite_only)
        what = invite_only ? "First-run setup, the user command, sign-in" : "Sign-up, sign-in"
        command = invite_only ? "require_relative \"../app/commands/user_command\"\n" : ""
        open_actions = invite_only ? "sign-in and setup" : "sign-in and sign-up"
        link = if invite_only
                 'refute res.body.include?("/sign_up")'
               else
                 'assert_includes res.body, "<a href=\"/sign_up\">Sign up</a>"'
               end
        <<~RUBY
          # #{what} and sign-out through the full stack (session cookie,
          # CSRF, method override, router). Run with `cybertrain spin test`; its
          # snapshot comes from the compiled binary (the database is FFI):
          # `script/regen-snapshot`-style, see README "Testing an app".
          require_relative "support/app_test"
          #{command}
          def new_client
            Session.all.delete_all
            User.all.delete_all
            Cybertrain::Test::Client.new(APP)
          end

          # Every action but #{open_actions} needs a user: DELETE /session is
          # the one such action this test can rely on before the app has pages
          # of its own (a `root` route, a scaffold).
          test "a visitor is sent to the sign-in page" do
            client = new_client
            client.get("/session/new")
            res = client.post("/session", { "_method" => "delete", "authenticity_token" => AppTest.form_token(client) })
            assert_redirected_to res, "/session/new"
            assert_response res, :see_other
          end

          test "GET /session/new renders the sign-in form" do
            client = new_client
            res = client.get("/session/new")
            assert_response res, :ok
            assert_includes res.body, "<h1>Sign in</h1>"
            assert_includes res.body, "<form action=\\"/session\\" method=\\"post\\">"
            assert_includes res.body, "name=\\"email_address\\""
            assert_includes res.body, "type=\\"password\\" name=\\"password\\""
            #{link}
          end

        RUBY
      end

      # --invite-only: /setup and `./<app> user` in place of the sign-up tests.
      def self.setup_tests(app)
        env = setup_env(app)
        <<~RUBY
          # The form /setup posts, filled in, with the page's one-time token
          # in its hidden field.
          def setup_form(authenticity_token, password, confirmation)
            { "authenticity_token" => authenticity_token,
              "token" => SetupController.setup_token,
              "user[email_address]" => " Ann@Example.com ",
              "user[password]" => password,
              "user[password_confirmation]" => confirmation }
          end

          # /setup with this process's token, the link the boot warning prints.
          def setup_link
            "/setup?token=\#{SetupController.setup_token}"
          end

          # `./#{app} ARGS...` in-process. Main.run connects a pool of one for
          # the command and disconnects it, so the tests' pool is connected
          # again afterwards (the database file is the same).
          def run_command(argv)
            status = Cybertrain::Main.run("#{app}", argv, router: Gen::Routes.build(Cybertrain::Router.new),
                                                     url_resolver: Gen::Routes.url_resolver,
                                                     views: Cybertrain::Application.no_views)
            reconnect
            status
          end

          def reconnect
            Cybertrain::DB.connect(Cybertrain.config.database_path, size: Cybertrain.config.pool_size)
            nil
          end

          test "GET /setup with the token shows the form to this machine while no user exists" do
            client = new_client
            res = client.get(setup_link)
            assert_response res, :ok
            assert_includes res.body, "<h1>Set up</h1>"
            assert_includes res.body, "<form action=\\"/setup\\" method=\\"post\\">"
            assert_includes res.body, "<input type=\\"hidden\\" name=\\"token\\" value=\\"\#{SetupController.setup_token}\\">"
            assert_includes res.body, "name=\\"user[password_confirmation]\\""
          end

          test "/setup without the token, or with a wrong one, is a 404" do
            client = new_client
            assert_equal 32, SetupController.setup_token.size
            res = client.get("/setup")
            assert_response res, :not_found
            res = client.get("/setup?token=")
            assert_response res, :not_found
            res = client.get("/setup?token=0123456789abcdef0123456789abcdef")
            assert_response res, :not_found
            res = client.get("/setup?token=\#{SetupController.setup_token}x")
            assert_response res, :not_found
            refute res.body.include?(SetupController.setup_token)
          end

          test "/setup is a 404 to another machine, through a proxy, and once a user exists" do
            client = new_client
            client.peer_address = "203.0.113.7"
            res = client.get(setup_link)
            assert_response res, :not_found
            client.peer_address = "127.0.0.1"
            res = client.get(setup_link, { "x-forwarded-for" => "203.0.113.7" })
            assert_response res, :not_found
            res = client.get(setup_link)
            assert_response res, :ok
            AppTest.user
            res = client.get(setup_link)
            assert_response res, :not_found
          end

          test "POST /setup from another machine, or without the token, creates nothing" do
            client = new_client
            client.get(setup_link)
            authenticity_token = AppTest.form_token(client)
            client.peer_address = "203.0.113.7"
            res = client.post("/setup", setup_form(authenticity_token, "s3cr3t-s3cr3t", "s3cr3t-s3cr3t"))
            assert_response res, :not_found
            client.peer_address = "127.0.0.1"
            form = setup_form(authenticity_token, "s3cr3t-s3cr3t", "s3cr3t-s3cr3t")
            form["token"] = "0123456789abcdef0123456789abcdef"
            res = client.post("/setup", form)
            assert_response res, :not_found
            form.delete("token")
            res = client.post("/setup", form)
            assert_response res, :not_found
            assert_equal 0, User.count
          end

          test "#{env} opens /setup to any address with the token until a user exists" do
            client = new_client
            client.peer_address = "203.0.113.7"
            Cybertrain.config.set_bool_setting(:setup_open, true)
            res = client.get(setup_link)
            without = client.get("/setup")
            Cybertrain.config.set_bool_setting(:setup_open, false)
            assert_response res, :ok
            assert_response without, :not_found
            AppTest.user
            Cybertrain.config.set_bool_setting(:setup_open, true)
            res = client.get(setup_link)
            Cybertrain.config.set_bool_setting(:setup_open, false)
            assert_response res, :not_found
          end

          test "POST /setup with the token creates the first user and signs them in" do
            client = new_client
            client.get(setup_link)
            res = client.post("/setup", setup_form(AppTest.form_token(client), "s3cr3t-s3cr3t", "s3cr3t-s3cr3t"))
            assert_redirected_to res, "/"
            assert_equal 1, User.count
            assert_equal "ann@example.com", User.first.email_address
            assert_equal 1, Session.count
            res = client.get("/session/new")
            assert_includes res.body, "<span>ann@example.com</span>"
            res = client.get(setup_link)
            assert_response res, :not_found
          end

          test "POST /setup with a short or mismatched password re-renders the form" do
            client = new_client
            client.get(setup_link)
            res = client.post("/setup", setup_form(AppTest.form_token(client), "short", "other"))
            assert_response res, :unprocessable_entity
            assert_includes res.body, "<li>Password is too short (minimum is 8 characters)</li>"
            assert_includes res.body, "<li>Password confirmation doesn&#39;t match Password</li>"
            assert_includes res.body, "<input type=\\"hidden\\" name=\\"token\\" value=\\"\#{SetupController.setup_token}\\">"
            assert_equal 0, User.count
          end

          test "./#{app} user creates a user, then sets its password" do
            new_client
            assert_equal 0, run_command(["user", "Bob@Example.com", "s3cr3t-s3cr3t"])
            assert_equal 1, User.count
            assert_equal "bob@example.com", User.first.email_address
            assert User.first.authenticate("s3cr3t-s3cr3t")
            assert_equal 0, run_command(["user", "bob@example.com", "another-s3cr3t"])
            assert_equal 1, User.count
            assert User.first.authenticate("another-s3cr3t")
            refute User.first.authenticate("s3cr3t-s3cr3t")
          end

          test "./#{app} user refuses bad arguments and an empty or short password" do
            new_client
            assert_equal 1, run_command(["user"])
            assert_equal 1, run_command(["user", "ann@example.com", "s3cr3t-s3cr3t", "extra"])
            assert_equal 1, run_command(["user", "--help"])
            assert_equal 1, run_command(["user", "ann@example.com", ""])
            assert_equal 1, run_command(["user", "ann@example.com", "short"])
            assert_equal 0, User.count
          end

          test "a password read from standard input loses one trailing newline" do
            assert_equal "s3cr3t s3cr3t", UserCommand.password_from("s3cr3t s3cr3t\\n")
            assert_equal "s3cr3t", UserCommand.password_from("s3cr3t\\r\\n")
            assert_equal "s3cr3t\\n", UserCommand.password_from("s3cr3t\\n\\n")
            assert_equal "", UserCommand.password_from("")
          end

          test "the boot warning is due while no user exists" do
            new_client
            assert UserCommand.no_user?
            reconnect
            AppTest.user
            refute UserCommand.no_user?
            reconnect
          end

        RUBY
      end

      def self.sign_up_tests
        <<~RUBY
          test "POST /sign_up creates the user and signs them in" do
            client = new_client
            client.get("/sign_up")
            res = client.post("/sign_up", { "authenticity_token" => AppTest.form_token(client),
                                            "user[email_address]" => " Ann@Example.com ",
                                            "user[password]" => "s3cr3t-s3cr3t",
                                            "user[password_confirmation]" => "s3cr3t-s3cr3t" })
            assert_redirected_to res, "/"
            assert_equal 1, User.count
            assert_equal "ann@example.com", User.first.email_address
            assert User.first.password_digest.start_with?("$pbkdf2-sha256$")
            assert_equal 1, Session.count
            res = client.get("/session/new")
            assert_includes res.body, "<span>ann@example.com</span>"
            assert_includes res.body, "Sign out"
          end

          test "POST /sign_up with a short or mismatched password re-renders the form" do
            client = new_client
            client.get("/sign_up")
            res = client.post("/sign_up", { "authenticity_token" => AppTest.form_token(client),
                                            "user[email_address]" => "ann@example.com",
                                            "user[password]" => "short",
                                            "user[password_confirmation]" => "other" })
            assert_response res, :unprocessable_entity
            assert_includes res.body, "<li>Password is too short (minimum is 8 characters)</li>"
            assert_includes res.body, "<li>Password confirmation doesn&#39;t match Password</li>"
            assert_equal 0, User.count
            res = client.post("/sign_up", { "authenticity_token" => AppTest.form_token(client),
                                            "user[email_address]" => "ann@example.com",
                                            "user[password]" => "",
                                            "user[password_confirmation]" => "" })
            assert_includes res.body, "<li>Password can&#39;t be blank</li>"
          end

          test "an email address can be registered once" do
            client = new_client
            AppTest.user("ann@example.com")
            client.get("/sign_up")
            res = client.post("/sign_up", { "authenticity_token" => AppTest.form_token(client),
                                            "user[email_address]" => "ANN@example.com",
                                            "user[password]" => "another-one",
                                            "user[password_confirmation]" => "another-one" })
            assert_response res, :unprocessable_entity
            assert_includes res.body, "<li>Email address has already been taken</li>"
            assert_equal 1, User.count
          end

        RUBY
      end

      def self.authentication_test_tail
        <<~RUBY
          test "POST /session signs in with the right password" do
            client = new_client
            AppTest.user
            res = AppTest.sign_in(client)
            assert_redirected_to res, "/"
            assert_response res, :see_other
            assert_equal 1, Session.count
            assert_equal "127.0.0.1", Session.first.ip_address
          end

          test "authentication returns to a local path once" do
            ctx = Cybertrain::Context.new(Cybertrain::Request.new("GET", "/", {}, ""))
            ctx.session = Cybertrain::Session.new
            controller = ApplicationController.new(ctx)
            assert_equal "/", controller.after_authentication_url
            ["/", "/products", "/products/1?tab=details#title", "/products//1", "/caf%C3%A9"].each do |path|
              controller.session[:return_to_after_authenticating] = path
              assert_equal path, controller.after_authentication_url
              refute controller.session.key?(:return_to_after_authenticating)
              assert_equal "/", controller.after_authentication_url
            end
          end

          test "authentication rejects unsafe return destinations and consumes them" do
            ctx = Cybertrain::Context.new(Cybertrain::Request.new("GET", "/", {}, ""))
            ctx.session = Cybertrain::Session.new
            controller = ApplicationController.new(ctx)
            unsafe = ["", "products", "https://evil.example/", "//evil.example/", "///evil.example/",
                      "/\\\\evil.example/", "/products\\\\evil", " //evil.example/", "/記事", "/" + "a" * 2048]
            (0..32).each { |byte| unsafe << "/\#{Cybertrain::Test.binary([byte])}/evil.example/" }
            unsafe << "/\#{Cybertrain::Test.binary([127])}/evil.example/"
            unsafe.each do |path|
              controller.session[:return_to_after_authenticating] = path
              assert_equal "/", controller.after_authentication_url
              refute controller.session.key?(:return_to_after_authenticating)
            end
          end

          test "POST /session with the wrong password shows an alert" do
            client = new_client
            AppTest.user
            res = AppTest.sign_in(client, "ann@example.com", "wrong-password")
            assert_redirected_to res, "/session/new"
            res = client.follow_redirect!
            assert_includes res.body, "<p class=\\"alert\\">Try another email address or password.</p>"
            assert_equal 0, Session.count
            res = AppTest.sign_in(client, "nobody@example.com", "s3cr3t-s3cr3t")
            assert_redirected_to res, "/session/new"
          end

          # SessionsController's rate_limit: ten attempts per address, then even
          # the right password goes back to the form until the window closes.
          test "POST /session past ten attempts is refused for a while" do
            client = new_client
            AppTest.user
            Cybertrain::RateLimit.reset_all!
            client.get("/session/new")
            wrong_password = { "authenticity_token" => AppTest.form_token(client),
                               "email_address" => "ann@example.com", "password" => "wrong-password" }
            right_password = { "authenticity_token" => AppTest.form_token(client),
                               "email_address" => "ann@example.com", "password" => "s3cr3t-s3cr3t" }
            10.times { client.post("/session", wrong_password) }
            res = client.post("/session", right_password)
            assert_redirected_to res, "/session/new"
            assert_equal 0, Session.count
            res = client.follow_redirect!
            assert_includes res.body, "<p class=\\"alert\\">Try again later.</p>"
            Cybertrain::RateLimit.current_time = Time.now.to_i + 3 * 60
            res = client.post("/session", right_password)
            Cybertrain::RateLimit.current_time = -1
            assert_redirected_to res, "/"
            assert_equal 1, Session.count
          end

          test "DELETE /session signs out and drops the Session row" do
            client = new_client
            AppTest.user
            AppTest.sign_in(client)
            client.get("/session/new")
            res = client.post("/session", { "_method" => "delete", "authenticity_token" => AppTest.form_token(client) })
            assert_redirected_to res, "/session/new"
            assert_equal 0, Session.count
            res = client.follow_redirect!
            assert_includes res.body, "<p class=\\"notice\\">You have been signed out.</p>"
            assert_includes res.body, "<a href=\\"/session/new\\">Sign in</a>"
          end

          test "a session the database no longer has signs the browser out" do
            client = new_client
            AppTest.user
            AppTest.sign_in(client)
            Session.all.delete_all
            client.get("/session/new")
            res = client.post("/session", { "_method" => "delete", "authenticity_token" => AppTest.form_token(client) })
            assert_redirected_to res, "/session/new"
          end

          test "changing the password signs out the sessions started before" do
            client = new_client
            user = AppTest.user
            AppTest.sign_in(client)
            res = client.get("/session/new")
            assert_includes res.body, "<span>ann@example.com</span>"
            user.password = "another-s3cr3t"
            user.save!
            res = client.get("/session/new")
            refute res.body.include?("<span>ann@example.com</span>")
            assert_equal 0, Session.count
            AppTest.sign_in(client, "ann@example.com", "another-s3cr3t")
            res = client.get("/session/new")
            assert_includes res.body, "<span>ann@example.com</span>"
          end

          test "an expired cookie cannot restore its user or reach a protected action" do
            max_age = Cybertrain.config.session_absolute_max_age
            Cybertrain.config.session_absolute_max_age = 60
            begin
              client = new_client
              AppTest.user
              AppTest.sign_in(client)
              name = Cybertrain.config.session_cookie_name
              cookie = "\#{name}=\#{client.cookies[name]}"
              res = client.get("/session/new", { "cookie" => cookie })
              assert_includes res.body, "<span>ann@example.com</span>"
              token = AppTest.form_token(client)

              # Keep the signed cookie and its row, but move the creation time
              # to the expiration boundary. Saving updates updated_at too;
              # neither that nor a rewritten cookie extends authentication.
              row = Session.first
              row.created_at = Time.at(Time.now.to_i - Cybertrain.config.session_absolute_max_age).utc
              row.save!
              res = client.post("/session", { "_method" => "delete", "authenticity_token" => token },
                                           { "cookie" => cookie })
              assert_redirected_to res, "/session/new"
              assert_equal 1, Session.count
              res = client.get("/session/new")
              refute res.body.include?("<span>ann@example.com</span>")
              assert_includes res.body, "<a href=\\"/session/new\\">Sign in</a>"

              # Replaying the original credential again still fails, even
              # after the server removed its id from the client's cookie.
              res = client.get("/session/new", { "cookie" => cookie })
              refute res.body.include?("<span>ann@example.com</span>")
            ensure
              Cybertrain.config.session_absolute_max_age = max_age
            end
          end

          Cybertrain::Test.run!
        RUBY
      end
    end
  end
end
