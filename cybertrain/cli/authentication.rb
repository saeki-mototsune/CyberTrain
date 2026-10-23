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
# What it leaves out, and why: password reset (needs a mailer, which
# cybertrain does not have), rate limiting (no `rate_limit` yet) and a
# `Current` object (templates read `@current_user` instead, an ivar
# `resume_session` sets on every controller). What it adds that Rails'
# does not: a sign-up page, because there is no console to create the first
# user in (Spinel has no `eval`). Delete RegistrationsController and its
# routes for an invitation-only application.
require "cybertrain/cli/templates"
require "cybertrain/cli/scaffold"

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

      # Returns the paths it created. Raises InvalidArgument, before anything
      # is written, when `root` is not an application (no config/routes.rb
      # with the draw line, no app/controllers/application_controller.rb
      # with the class line).
      def self.generate(root)
        routes_path = File.join(root, "config/routes.rb")
        raise InvalidArgument, "#{routes_path} not found: run this inside a cybertrain app" unless File.exist?(routes_path)
        raise InvalidArgument, "#{routes_path} has no `#{Scaffold::DRAW_LINE}` line" if File.read(routes_path).index(Scaffold::DRAW_LINE).nil?

        controller_path = File.join(root, "app/controllers/application_controller.rb")
        raise InvalidArgument, "#{controller_path} not found: run this inside a cybertrain app" unless File.exist?(controller_path)
        raise InvalidArgument, "#{controller_path} has no `#{CLASS_LINE}` line" if File.read(controller_path).index(CLASS_LINE).nil?

        created = Array.new(0) { "" }
        users = migration_path(root, "users")
        record(created, root, users, users_migration)
        record(created, root, migration_path(root, "sessions"), sessions_migration)
        record(created, root, "app/models/user.rb", user_model)
        record(created, root, "app/models/session.rb", session_model)
        record(created, root, "app/controllers/sessions_controller.rb", sessions_controller)
        record(created, root, "app/controllers/registrations_controller.rb", registrations_controller)
        record(created, root, "app/views/sessions/new.html.erb", sessions_new_view)
        record(created, root, "app/views/sessions/_nav.html.erb", nav_partial)
        record(created, root, "app/views/registrations/new.html.erb", registrations_new_view)
        record(created, root, "test/support/app_test.rb", app_test_support)
        record(created, root, "test/authentication.rb", authentication_test)
        add_to_application_controller(controller_path)
        add_routes(routes_path)
        add_nav_to_layout(File.join(root, "app/views/layouts/application.html.erb"))
        add_sign_in_to_attachment_tests(root)
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

      # Inserts the sign-in and sign-up routes after the draw line, once.
      def self.add_routes(path)
        source = File.read(path)
        unless source.index(ROUTE_MARK).nil?
          puts "identical route #{ROUTE_MARK}"
          return false
        end

        File.write(path, insert_after_line(source, Scaffold::DRAW_LINE, indent(routes_block)))
        puts "route #{ROUTE_MARK}, get/post /sign_up"
        true
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
            # costs a hash too, so the response time does not say which of the
            # two was wrong.
            def self.authenticate_by(email_address:, password:)
              user = User.find_by(email_address: User.normalize_email_address(email_address))
              if user.nil?
                Cybertrain::Password.hash(password.to_s.empty? ? "-" : password.to_s)
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
            # everyone as they sign in.
            def authenticate(plain)
              return false unless Cybertrain::Password.verify?(plain, password_digest)

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
          # authentication expires session_max_age seconds after sign-in.
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
            if created_at.nil? || created_at.to_i + Cybertrain.config.session_max_age <= Time.now.to_i
              session.delete(:session_id)
              return nil
            end
            @current_session = found
            @current_user = found.user
            nil
          end

          # Sends a visitor to the sign-in page, remembering a GET to come back to.
          def require_authentication
            return nil if authenticated?

            session[:return_to_after_authenticating] = request.path if request.method == "GET"
            redirect_to new_session_path, status: :see_other
            nil
          end

          def start_new_session_for(user)
            started = Session.create(user_id: user.id, ip_address: request.remote_addr,
                                     user_agent: request.header("user-agent").to_s)
            session[:session_id] = started.id
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

          # Where to go after signing in: the page that asked for it, or /.
          def after_authentication_url
            url = session[:return_to_after_authenticating]
            session.delete(:return_to_after_authenticating)
            url.nil? || url.empty? ? "/" : url
          end
          # ---- end of authentication ------------------------------------------

        RUBY
      end

      def self.sessions_controller
        <<~RUBY
          # Sign in and out (cybertrain generate authentication).
          class SessionsController < ApplicationController
            allow_unauthenticated_access only: [:new, :create]

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

      def self.sessions_new_view
        <<~ERB
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

          <p><%= link_to "Sign up", sign_up_path %></p>
        ERB
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

      # Inserted (indented) after the draw line of config/routes.rb.
      def self.routes_block
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

            # Signs `client` in through the form, as a browser would.
            def self.sign_in(client, email_address = "ann@example.com", password = "s3cr3t-s3cr3t")
              client.get("/session/new")
              client.post("/session", { "authenticity_token" => form_token(client),
                                        "email_address" => email_address,
                                        "password" => password })
            end
          end

          APP = AppTest.boot
        RUBY
      end

      def self.authentication_test
        <<~RUBY
          # Sign-up, sign-in and sign-out through the full stack (session cookie,
          # CSRF, method override, router). Run with `cybertrain spin test`; its
          # snapshot comes from the compiled binary (the database is FFI):
          # `script/regen-snapshot`-style, see README "Testing an app".
          require_relative "support/app_test"

          def new_client
            Session.all.delete_all
            User.all.delete_all
            Cybertrain::Test::Client.new(APP)
          end

          # Every action but sign-in and sign-up needs a user: DELETE /session is
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
            assert_includes res.body, "<a href=\\"/sign_up\\">Sign up</a>"
          end

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

          test "POST /session signs in with the right password" do
            client = new_client
            AppTest.user
            res = AppTest.sign_in(client)
            assert_redirected_to res, "/"
            assert_response res, :see_other
            assert_equal 1, Session.count
            assert_equal "127.0.0.1", Session.first.ip_address
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

          test "an expired cookie cannot restore its user or reach a protected action" do
            max_age = Cybertrain.config.session_max_age
            Cybertrain.config.session_max_age = 60
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
              row.created_at = Time.at(Time.now.to_i - Cybertrain.config.session_max_age).utc
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
              Cybertrain.config.session_max_age = max_age
            end
          end

          Cybertrain::Test.run!
        RUBY
      end
    end
  end
end
