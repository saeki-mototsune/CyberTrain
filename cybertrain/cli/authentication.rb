# `cybertrain generate authentication`: email-and-password sign-in, the way
# Rails 8's `bin/rails generate authentication` writes it, as code the
# application owns (docs/design.md D15):
#
#   db/migrate/*_create_users.rb, *_create_sessions.rb
#   app/models/user.rb, app/models/session.rb
#   app/controllers/concerns/authentication.rb   the Authentication concern
#   app/controllers/sessions_controller.rb, registrations_controller.rb
#   app/controllers/passwords_controller.rb      password reset by mail
#   app/mailers/passwords_mailer.rb              its mail
#   app/commands/user_command.rb                 `./<app> user ...`
#   app/views/sessions/new.html.erb, _nav.html.erb, registrations/new.html.erb
#   app/views/passwords/new.html.erb, edit.html.erb, mail/_password_reset.html.erb
#   test/authentication.rb, test/admin.rb, test/remember_me.rb,
#   test/lockout.rb, test/passwords.rb, test/support/app_test.rb,
#   test/support/authentication_helpers.rb
#
# and these edits: `include Authentication` into
# app/controllers/application_controller.rb, the routes into
# config/routes.rb (and the jobs page's line, a comment until now, drawn
# behind require_admin), the nav partial into the layout, the user command
# into bin/<app>.rb, the base_url setting (<APP>_BASE_URL, where links in
# mails start) into config/app.rb (plus a sign-in in any
# test/attachment_*.rb written before it, which now needs one). Every file is written once
# (Templates.write never overwrites) and every edit is made once, so
# running the generator again is harmless.
#
# Every word the screens show goes through t(): lazy keys
# (`t(".title")`, sessions.new.title) in the views and the actions,
# absolute ones in private methods, all of them in the bundled en and ja
# dictionaries (cybertrain/locales/*.yml); an application's
# config/locales overrides any of them.
#
# Sign-in attempts are rate limited as in Rails' generator (`rate_limit to:
# 10, within: 3 * 60, only: [:create]`, per client address, counted in
# Cybertrain::Cache; docs/design.md D26), and AppTest.sign_in resets the
# counts so a test suite never reaches the limit.
#
# Users have an admin flag (`users.admin`, User#admin?), which the
# concern's require_admin asks for and `./<app> user admin EMAIL` sets.
#
# Lockout (users.failed_attempts, users.locked_until): auth_lockout_attempts
# wrong passwords lock an account for auth_lockout_period, answered with the
# wrong-password message. Remember me (sessions.remember): the sign-in
# form's "Keep me signed in" box makes a sign-in last auth_remember_for in
# place of session_absolute_max_age, with a cookie that has a Max-Age;
# unchecked, the cookie ends with the browser. Either way a sign-in unused
# for auth_idle_timeout ends (sessions.last_active_at).
#
# Password reset (/passwords): a link by mail (deliver_later, so the app
# needs the CYBERTRAIN_SMTP_* settings and a job thread), valid for 15
# minutes and until the password changes; the answer is the same for an
# unknown address. The link starts with the base_url setting, else with
# the request's address only where a forged Host cannot reach it (the
# concern's mail_link_base). A reset clears a lockout and ends every
# session of the user.
#
# What it leaves out, and why: a `Current` object (templates read `@current_user` instead, an ivar
# `resume_session` sets on every controller). What it adds that Rails'
# does not: a sign-up page, because there is no console to create the first
# user in (Spinel has no `eval`), and the user command.
#
# `--invite-only` (docs/design.md D29) writes no sign-up page. Instead:
#
#   app/controllers/setup_controller.rb, app/views/setup/new.html.erb
#                                  /setup, the first user's form: only while
#                                  no user exists, only with the one-time
#                                  token the boot warning prints, only from
#                                  loopback unless <APP>_SETUP_OPEN=1
#
# plus the boot warning while no user exists (in the user command's file,
# called from bin/<app>.rb), and the `setup_open` setting into
# config/app.rb's configure block.
require "cybertrain/cli/templates"
require "cybertrain/cli/scaffold"
require "cybertrain/cli/build"

module Cybertrain
  module CLI
    module Authentication
      CLASS_LINE = "class ApplicationController < Cybertrain::Controller"
      ROUTE_MARK = "resource :session"
      # The password reset's routes, added after ROUTE_MARK's line to an app
      # whose routes have the sign-in but not these yet.
      PASSWORDS_ROUTE_MARK = "resources :passwords"
      PASSWORDS_ROUTE = "resources :passwords, param: :token, only: [:new, :create, :edit, :update]"
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
      # The edits bin/<app>.rb and config/app.rb get: the user command's file
      # (and, with --invite-only, the boot warning) before this line, the
      # setting (--invite-only) after this one.
      MAIN_RUN_LINE = "exit(Cybertrain::Main.run("
      CONFIGURE_LINE = "Cybertrain.configure do |c|"
      COMMAND_REQUIRE = "require_relative \"../app/commands/user_command\""
      # What ApplicationController gets right after its class line.
      INCLUDE_LINE = "include Authentication"
      # `cybertrain new`'s routes carry the jobs page as a comment of this
      # line (Templates.routes), there being no require_admin yet.
      NEW_APP_JOBS_PAGE_LINE = "jobs_page \"/admin/jobs\", before_action: :require_admin"
      # What enable_jobs_page draws in its place: require_admin alone
      # decides, so a visitor gets its 404 rather than a redirect to sign in
      # that shows the page exists (the skip is jobs_page's explicit option).
      JOBS_PAGE_LINE = "jobs_page \"/admin/jobs\", before_action: :require_admin, skip_before_action: :require_authentication"

      # What generate_with_result did: the paths it created, the paths it
      # overwrote and the diffs to apply by hand where a file it writes
      # whole exists with other content. The generator leaves such a file
      # alone and reports nothing yet, so the last two are empty.
      class GenerateResult
        # @return [Array<String>] each one's path from the app's root
        attr_reader :created, :forced, :manual

        def initialize(created, forced, manual)
          @created = created
          @forced = forced
          @manual = manual
        end
      end

      # The paths it created (generate_with_result's `created`).
      def self.generate(root, invite_only = false)
        generate_with_result(root, invite_only).created
      end

      # Writes the files and makes the edits. Raises InvalidArgument, before
      # anything is written, when `root` is not an application (no
      # config/routes.rb with the draw line, no
      # app/controllers/application_controller.rb with the class line, no
      # bin/<app>.rb with the Main.run line, no config/app.rb with the
      # configure line).
      def self.generate_with_result(root, invite_only = false)
        routes_path = File.join(root, "config/routes.rb")
        raise InvalidArgument, "#{routes_path} not found: run this inside a cybertrain app" unless File.exist?(routes_path)
        raise InvalidArgument, "#{routes_path} has no `#{Scaffold::DRAW_LINE}` line" if File.read(routes_path).index(Scaffold::DRAW_LINE).nil?

        controller_path = File.join(root, "app/controllers/application_controller.rb")
        raise InvalidArgument, "#{controller_path} not found: run this inside a cybertrain app" unless File.exist?(controller_path)
        raise InvalidArgument, "#{controller_path} has no `#{CLASS_LINE}` line" if File.read(controller_path).index(CLASS_LINE).nil?

        # Both modes require the user command from bin/<app>.rb.
        app = Build.app_name(root)
        raise InvalidArgument, "#{root}/spin.toml has no [package] name: run this inside a cybertrain app" if app == ""

        bin_path = File.join(root, "bin/#{app}.rb")
        raise InvalidArgument, "#{bin_path} not found: run this inside a cybertrain app" unless File.exist?(bin_path)
        raise InvalidArgument, "#{bin_path} has no line starting with `#{MAIN_RUN_LINE}`" if line_start(File.read(bin_path), MAIN_RUN_LINE) < 0

        # Both modes declare the base_url setting in config/app.rb.
        config_path = File.join(root, "config/app.rb")
        raise InvalidArgument, "#{config_path} not found: run this inside a cybertrain app" unless File.exist?(config_path)
        raise InvalidArgument, "#{config_path} has no `#{CONFIGURE_LINE}` line" if File.read(config_path).index(CONFIGURE_LINE).nil?

        created = Array.new(0) { "" }
        users = migration_path(root, "users")
        record(created, root, users, users_migration)
        record(created, root, migration_path(root, "sessions"), sessions_migration)
        record(created, root, "app/models/user.rb", user_model)
        record(created, root, "app/models/session.rb", session_model)
        record(created, root, "app/controllers/concerns/authentication.rb", authentication_concern(app))
        record(created, root, "app/controllers/sessions_controller.rb", sessions_controller)
        if invite_only
          record(created, root, "app/controllers/setup_controller.rb", setup_controller(app))
        else
          record(created, root, "app/controllers/registrations_controller.rb", registrations_controller)
        end
        record(created, root, "app/controllers/passwords_controller.rb", passwords_controller)
        record(created, root, "app/mailers/passwords_mailer.rb", passwords_mailer)
        record(created, root, "app/commands/user_command.rb", user_command(app, invite_only))
        record(created, root, "app/views/sessions/new.html.erb", sessions_new_view(invite_only))
        record(created, root, "app/views/sessions/_nav.html.erb", nav_partial)
        if invite_only
          record(created, root, "app/views/setup/new.html.erb", setup_new_view)
        else
          record(created, root, "app/views/registrations/new.html.erb", registrations_new_view)
        end
        record(created, root, "app/views/passwords/new.html.erb", passwords_new_view)
        record(created, root, "app/views/passwords/edit.html.erb", passwords_edit_view)
        record(created, root, "app/views/mail/_password_reset.html.erb", password_reset_mail_view)
        record(created, root, "test/support/app_test.rb", app_test_support)
        record(created, root, "test/support/authentication_helpers.rb", authentication_helpers)
        record(created, root, "test/authentication.rb", invite_only ? invite_only_test(app) : authentication_test)
        record(created, root, "test/admin.rb", admin_test(app))
        record(created, root, "test/remember_me.rb", remember_me_test)
        record(created, root, "test/lockout.rb", lockout_test)
        record(created, root, "test/passwords.rb", passwords_test(app))
        add_to_application_controller(controller_path)
        add_routes(routes_path, invite_only)
        enable_jobs_page(routes_path, controller_path)
        add_nav_to_layout(File.join(root, "app/views/layouts/application.html.erb"))
        add_sign_in_to_attachment_tests(root)
        add_command_to_bin(bin_path, app, invite_only)
        add_setting_to_config(config_path, app, invite_only)
        GenerateResult.new(created, Array.new(0) { "" }, Array.new(0) { "" })
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

      # Whether source has an `include Authentication` line (a trailing
      # comment allowed): not a commented-out one, and not
      # `include AuthenticationHelpers` or `include Authentication::X`.
      def self.included?(source)
        source.each_line do |line|
          return true if Authentication.include_line?(line)
        end
        false
      end

      # Whether this one line is such an include (Attachment reads the
      # concern's callbacks in its place).
      def self.include_line?(line)
        code = line.strip
        code == INCLUDE_LINE || code.start_with?("#{INCLUDE_LINE} #")
      end

      # Inserts `include Authentication` right after the class line, once. A
      # controller that defines require_authentication itself (0.4's
      # generator put the whole block there) is left alone: including the
      # concern on top of it would run every callback twice. Returns true
      # when the file was changed.
      def self.add_to_application_controller(path)
        source = File.read(path)
        if Authentication.included?(source)
          puts "identical app/controllers/application_controller.rb (#{INCLUDE_LINE})"
          return false
        end
        unless source.index("def require_authentication").nil?
          puts "skip app/controllers/application_controller.rb (it defines require_authentication itself): " \
               "replace that code with `#{INCLUDE_LINE}` (app/controllers/concerns/authentication.rb)"
          return false
        end

        File.write(path, insert_after_line(source, CLASS_LINE, "  #{INCLUDE_LINE}\n\n"))
        puts "insert app/controllers/application_controller.rb (#{INCLUDE_LINE})"
        true
      end

      # Draws the jobs page `cybertrain new` left as a comment (a line that
      # is `# jobs_page "/admin/jobs", before_action: :require_admin`, or
      # already JOBS_PAGE_LINE commented out) as JOBS_PAGE_LINE, once
      # ApplicationController includes the concern that defines
      # require_admin. Any other routes file is left as it is. Returns true
      # when the file was changed.
      def self.enable_jobs_page(routes_path, controller_path)
        source = File.read(routes_path)
        comments = ["# #{NEW_APP_JOBS_PAGE_LINE}", "# #{JOBS_PAGE_LINE}"]
        updated = +""
        found = ""
        source.each_line do |line|
          code = line.strip
          if found.empty? && comments.include?(code)
            found = code
            updated << line[0, line.index(code).to_i].to_s << JOBS_PAGE_LINE << "\n"
          else
            updated << line
          end
        end
        return false if found.empty?

        unless Authentication.included?(File.read(controller_path))
          puts "skip config/routes.rb (#{found}): ApplicationController has no require_admin until it includes Authentication"
          return false
        end

        File.write(routes_path, updated)
        puts "route #{JOBS_PAGE_LINE}"
        true
      end

      # Inserts the sign-in, password reset and sign-up (or setup) routes
      # after the draw line, once. Routes that have the sign-in but not the
      # reset (an app generated before it) get the reset's line right after
      # the sign-in's, indented as that one is.
      def self.add_routes(path, invite_only = false)
        source = File.read(path)
        if source.index(ROUTE_MARK).nil?
          File.write(path, insert_after_line(source, Scaffold::DRAW_LINE, indent(routes_block(invite_only))))
          puts "route #{ROUTE_MARK}, #{PASSWORDS_ROUTE_MARK}, get/post #{invite_only ? "/setup" : "/sign_up"}"
          return true
        end
        unless source.index(PASSWORDS_ROUTE_MARK).nil?
          puts "identical route #{ROUTE_MARK}, #{PASSWORDS_ROUTE_MARK}"
          return false
        end

        at = source.index(ROUTE_MARK).to_i
        start = line_start_before(source, at)
        margin = source[start, at - start].to_s
        File.write(path, insert_after_line(source, ROUTE_MARK, "#{margin}#{PASSWORDS_ROUTE}\n"))
        puts "route #{PASSWORDS_ROUTE_MARK}"
        true
      end

      # Where the line holding offset `at` of source starts.
      def self.line_start_before(source, at)
        found = at > 0 ? source.rindex("\n", at - 1) : nil
        found.nil? ? 0 : found + 1
      end

      # Requires app/commands/user_command.rb (which registers the `user`
      # command) and, with --invite-only, runs its boot warning, just before
      # the Main.run line of bin/<app>.rb, once.
      def self.add_command_to_bin(path, app, invite_only = false)
        name = "bin/#{app}.rb"
        source = File.read(path)
        unless source.index(COMMAND_REQUIRE).nil?
          puts "identical #{name} (user command already required)"
          return false
        end

        File.write(path, insert_before_line(source, MAIN_RUN_LINE, bin_block(app, invite_only)))
        puts invite_only ? "insert #{name} (./#{app} user, the first-run warning)" : "insert #{name} (./#{app} user)"
        true
      end

      # Declares the base_url setting (both modes) and, with --invite-only,
      # the setup_open setting above it, at the top of config/app.rb's
      # configure block, each once. Returns true when the file was changed.
      def self.add_setting_to_config(path, app, invite_only = false)
        source = File.read(path)
        changed = false
        if source.index("setting_string :base_url").nil?
          source = insert_after_line(source, CONFIGURE_LINE, indent(base_url_block(app)))
          puts "insert config/app.rb (#{base_url_env(app)})"
          changed = true
        else
          puts "identical config/app.rb (base_url already declared)"
        end
        if invite_only
          if source.index("setting_bool :setup_open").nil?
            source = insert_after_line(source, CONFIGURE_LINE, indent(config_block(app)))
            puts "insert config/app.rb (#{setup_env(app)})"
            changed = true
          else
            puts "identical config/app.rb (setup_open already declared)"
          end
        end
        File.write(path, source) if changed
        changed
      end

      # The environment variable that opens /setup to any address:
      # SHOP_SETUP_OPEN for the app shop.
      def self.setup_env(app)
        "#{app.upcase}_SETUP_OPEN"
      end

      # The environment variable of the base_url setting, which links in
      # mails start with: SHOP_BASE_URL for the app shop.
      def self.base_url_env(app)
        "#{app.upcase}_BASE_URL"
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
                t.boolean "admin", null: false, default: "false"
                t.integer "failed_attempts", null: false, default: "0"
                t.datetime "locked_until"
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
                t.boolean "remember", null: false, default: "false"
                t.datetime "last_active_at"
                t.timestamps
              end
            end
          end
        RUBY
      end

      def self.user_model
        <<~RUBY
          # Columns (email_address, password_digest, admin, failed_attempts,
          # locked_until), the Cybertrain::Model superclass and `sessions` (from
          # the sessions table's foreign key) come from gen/models/user.rb,
          # generated from db/schema.rb by `spin run gen`.
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
            # and a locked account (locked?, while lockout is on) cost a password
            # verification too, against Cybertrain::Password.dummy_digest, and
            # answer nil whatever the password, as a wrong one does: the sign-in
            # form shows them all the wrong-password message. A wrong password
            # on an existing, unlocked account also writes its row once
            # (count_failed_attempt!), as Devise's lockable does; that one write
            # is the timing difference left between it and the other two, and it
            # is accepted. The right password clears the count.
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

            # Whether this user may see the admin pages (the Authentication
            # concern's require_admin): `./<app> user admin EMAIL` sets it.
            def admin? = admin

            # Whether wrong passwords have locked the account for now
            # (count_failed_attempt!): authenticate_by refuses it until then,
            # unless lockout is off (auth_lockout_attempts 0), which also stops
            # enforcing a lock made before.
            def locked? = !locked_until.nil? && locked_until > Time.now

            # A wrong password: one more failed attempt, counted by the database
            # in one UPDATE that reads the row as it is (so sign-ins at the same
            # time all count). The attempt that reaches
            # Cybertrain.config.auth_lockout_attempts (10; 0 never locks) locks
            # the account for auth_lockout_period seconds (an hour) and starts
            # the count again, in the same statement.
            def count_failed_attempt!
              limit = Cybertrain.config.auth_lockout_attempts
              return nil if limit <= 0

              count = "failed_attempts = CASE WHEN failed_attempts + 1 >= ? THEN 0 ELSE failed_attempts + 1 END"
              lock = "locked_until = CASE WHEN failed_attempts + 1 >= ? THEN ? ELSE locked_until END"
              ends = Time.now + Cybertrain.config.auth_lockout_period
              User.where(id: id).update_all_sql(count + ", " + lock, [limit, limit, ends])
              nil
            end

            # No failed attempts and no lock: a successful sign-in calls it, and
            # so do `./<app> user EMAIL PASSWORD` and a password reset
            # (PasswordsController#update). Writes only when there is something
            # to clear.
            def clear_failed_attempts!
              return nil if failed_attempts == 0 && locked_until.nil?

              update_columns(failed_attempts: 0, locked_until: nil)
              nil
            end

            # The token of a password reset link (PasswordsController): signed,
            # valid for 15 minutes from now, and bound to password_digest, so it
            # stops working once the password changes (Cybertrain::Token).
            def password_reset_token(now = Time.now.to_i)
              Cybertrain::Token.issue("password_reset", id, 15 * 60, password_digest, now)
            end

            # Public so the before_validation block above (which receives the
            # record, not an implicit self) can call them. Their messages come
            # from the dictionary of the current locale, as a validator's do.

            def validate_email_address_taken
              address = email_address
              return nil if address.nil? || address.empty?

              taken = User.where(email_address: address).where_sql("id != ?", [id]).exists?
              errors.add(:email_address, I18n.error_message("user", :email_address, :taken)) if taken
              nil
            end

            def validate_password
              given = password
              if password_digest.to_s.empty?
                errors.add(:password, I18n.error_message("user", :password, :blank))
              elsif !given.empty? && given.size < MIN_PASSWORD_LENGTH
                errors.add(:password, I18n.error_message("user", :password, :too_short, { count: MIN_PASSWORD_LENGTH }))
              end
              confirmation = @password_confirmation
              if !confirmation.nil? && confirmation != given
                attribute = I18n.human_attribute_name("user", :password)
                errors.add(:password_confirmation, I18n.error_message("user", :password_confirmation, :confirmation, { attribute: attribute }))
              end
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
          # Not to be confused with Cybertrain::Session, the encrypted cookie that
          # holds this row's id as `session[:session_id]`.
          class Session
          end
        RUBY
      end

      # app/controllers/concerns/authentication.rb: what 0.4 inserted into
      # ApplicationController, as Rails 8's concern, plus require_admin and
      # mail_link_base (the one place that decides where a mail's links
      # point: the reset's now, the confirmation's after it).
      def self.authentication_concern(app)
        env = base_url_env(app)
        <<~RUBY
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
            # setting (#{env}, config/app.rb) when set; else the address this
            # request came to, outside production, or in production when
            # CYBERTRAIN_HOSTS lists the hosts the app answers to (any other Host
            # is refused before an action runs). Otherwise "" and an [ERROR] line:
            # the mail named `mail` is not sent, as a link built from a Host header
            # anyone can forge would carry its token to their site.
            def mail_link_base(mail)
              c = Cybertrain.config
              configured = c.string_setting(:base_url)
              return configured.delete_suffix("/") unless configured.empty?
              return request.base_url if !c.production? || c.host_check?

              Cybertrain.logger.error("\#{mail} mail not sent: set #{env} (or CYBERTRAIN_HOSTS)")
              ""
            end
          end
        RUBY
      end

      def self.sessions_controller
        <<~RUBY
          # Sign in and out (cybertrain generate authentication).
          class SessionsController < ApplicationController
            allow_unauthenticated_access only: [:new, :create]
            # Ten sign-in attempts per client address every three minutes, then
            # back to the form (rate_limited) until the window closes. Behind a
            # reverse proxy on this host, set CYBERTRAIN_TRUSTED_PROXY=1 so that
            # each visitor is counted rather than the proxy.
            rate_limit to: 10, within: 3 * 60, only: [:create], with: :rate_limited

            # GET /session/new
            # (named new_action: a `new` method would shadow SessionsController.new)
            def new_action
            end

            # POST /session
            def create
              user = User.authenticate_by(email_address: params[:email_address].to_s, password: params[:password].to_s)
              if user.nil?
                flash[:alert] = t(".invalid")
                redirect_to new_session_path, status: :see_other
              else
                start_new_session_for(user, remember: params[:remember_me] == "1")
                redirect_to after_authentication_url, status: :see_other
              end
            end

            # DELETE /session
            def destroy
              terminate_session
              flash[:notice] = t(".signed_out")
              redirect_to new_session_path, status: :see_other
            end

            private

            # What a client past the rate limit gets: the form again, with a
            # message. Not an action, so its key is written in full (the
            # action it answers for is create).
            def rate_limited
              flash[:alert] = t("sessions.create.rate_limited")
              redirect_to new_session_path, status: :see_other
              nil
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
                flash[:notice] = t(".welcome")
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
          <h1><%= t(".title") %></h1>

          <%= form_with(url: session_path) do |f| %>
            <div class="field">
              <%= f.label :email_address, t(".email_address") %>
              <%= f.email_field :email_address, autocomplete: "username", autofocus: true %>
            </div>

            <div class="field">
              <%= f.label :password, t(".password") %>
              <%= f.password_field :password, autocomplete: "current-password" %>
            </div>

            <div class="field">
              <%= check_box_tag :remember_me %>
              <%= label_tag :remember_me, t(".remember_me") %>
            </div>

            <div class="actions">
              <%= f.submit t(".submit") %>
            </div>
          <% end %>

          <p><%= link_to t(".forgot_password"), new_password_path %></p>
        ERB
        return view if invite_only

        "#{view}<p><%= link_to t(\".sign_up\"), sign_up_path %></p>\n"
      end

      def self.nav_partial
        <<~ERB
          <%# locals: () %>
          <nav class="session">
            <% if @current_user %>
              <span><%= @current_user.email_address %></span>
              <%= button_to t(".sign_out"), session_path, method: :delete %>
            <% else %>
              <%= link_to t(".sign_in"), new_session_path %>
            <% end %>
          </nav>
        ERB
      end

      def self.registrations_new_view
        <<~ERB
          <h1><%= t(".title") %></h1>

          <%= form_with(model: @user, url: sign_up_path) do |f| %>
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
              <%= f.label :password %>
              <%= f.password_field :password, autocomplete: "new-password" %>
            </div>

            <div class="field">
              <%= f.label :password_confirmation %>
              <%= f.password_field :password_confirmation, autocomplete: "new-password" %>
            </div>

            <div class="actions">
              <%= f.submit t(".submit") %>
            </div>
          <% end %>

          <p><%= link_to t(".sign_in"), new_session_path %></p>
        ERB
      end

      # ---- password reset -----------------------------------------------

      # app/controllers/passwords_controller.rb: Rails 8's, with the same
      # answer and work for an unknown address, the link's base from the
      # concern's mail_link_base, and a reset that clears a lockout and ends
      # every session of the user.
      def self.passwords_controller
        <<~'RUBY'
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
                mail.deliver_later unless user.nil?
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
      end

      # app/mailers/passwords_mailer.rb. `reset` takes the link as well as
      # the user (Rails' takes the user alone): the base URL may be the
      # request's (mail_link_base), and a mailer has no request.
      def self.passwords_mailer
        <<~'RUBY'
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
              text << greeting << "\n\n"
              text << I18n.t("mail.password_reset.intro") << "\n" << url << "\n\n"
              text << I18n.t("mail.password_reset.ignore") << "\n"
              subject = I18n.t("passwords_mailer.reset.subject")
              Cybertrain::MailMessage.new(to: address, subject: subject, body: text, html: html)
            end
          end
        RUBY
      end

      def self.passwords_new_view
        <<~ERB
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
      end

      def self.passwords_edit_view
        <<~ERB
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
      end

      # The mail's HTML (Views.render_mail); its lazy keys are
      # mail.password_reset.* (D8).
      def self.password_reset_mail_view
        <<~ERB
          <%# locals: (user:, url:) %>
          <p><%= t(".greeting", email_address: user.email_address) %></p>
          <p><%= t(".intro") %></p>
          <p><%= link_to t(".link"), url %></p>
          <p><%= t(".ignore") %></p>
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
              # The no-user check and the insert are one write transaction
              # (BEGIN IMMEDIATE takes the lock first), so two requests that
              # both passed require_first_run cannot both create "the first"
              # account: the second finds a user and saves nothing.
              saved = false
              User.transaction(immediate: true) do |c|
                saved = @user.save unless User.all.exists?
              end
              if saved
                start_new_session_for(@user)
                flash[:notice] = t(".welcome")
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
          <h1><%= t(".title") %></h1>

          <p><%= t(".intro") %></p>

          <%= form_with(model: @user, url: setup_path) do |f| %>
            <input type="hidden" name="token" value="<%= @setup_token %>">

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
              <%= f.submit t(".submit") %>
            </div>
          <% end %>
        ERB
      end

      # app/commands/user_command.rb: the `user` command, required from
      # bin/<app>.rb (and from the app's tests, which run it). With
      # --invite-only it also holds the boot warning, which names /setup's
      # token; a sign-up app has no SetupController to name.
      def self.user_command(app, invite_only = false)
        head = user_command_head(app, invite_only)
        warning = invite_only ? user_command_warning(app) : ""
        tail = <<~RUBY
          end

          Cybertrain::Main.command("user", "EMAIL [PASSWORD] | admin EMAIL | unadmin EMAIL: create a user or set its password, or grant or revoke admin") do |argv|
            UserCommand.run(argv)
          end
        RUBY
        join_three(head, warning, tail)
      end

      # The command's file up to the end of its last method, in both modes.
      def self.user_command_head(app, invite_only)
        mode = invite_only ? " --invite-only" : ""
        warned = invite_only ? ", which also calls UserCommand.warn_if_no_user before serving" : ""
        <<~RUBY
          # `./#{app} user EMAIL [PASSWORD]` (cybertrain generate authentication#{mode}):
          # creates the user with this address, or sets the password of the one
          # that has it (which signs that user's browsers out: their sessions'
          # password key no longer matches; and clears a lockout, User#locked?).
          # Without PASSWORD it is read from
          # standard input, one line, so that it stays out of `ps` and the shell
          # history:
          #
          #   ./#{app} user ann@example.com          # type it, then Enter (it is echoed)
          #   printf '%s' "$PASSWORD" | ./#{app} user ann@example.com
          #
          # `./#{app} user admin EMAIL` makes that user an admin (User#admin?, which
          # the Authentication concern's require_admin asks for: the jobs page),
          # `./#{app} user unadmin EMAIL` makes them an ordinary user again.
          #
          # Registered with Cybertrain::Main.command, which connects the database
          # first. Required by bin/#{app}.rb#{warned}.
          # Written by the generator; it is yours to change.
          module UserCommand
            USAGE = "usage: ./#{app} user EMAIL [PASSWORD] (without PASSWORD, it is read from standard input) | ./#{app} user admin EMAIL | ./#{app} user unadmin EMAIL"

            # The exit status: 0 when the user was created, updated or made an
            # admin or not, 1 for bad arguments, an empty password, an unknown
            # address (admin, unadmin) or a record that does not validate.
            def self.run(argv)
              if !argv.empty? && (argv[0] == "admin" || argv[0] == "unadmin")
                if argv.size != 2
                  puts USAGE
                  return 1
                end
                return UserCommand.grant_admin(argv[1], argv[0] == "admin")
              end
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
              user.clear_failed_attempts!
              puts created ? "created \#{address}" : "updated \#{address}"
              0
            end

            # `user admin EMAIL` (granted) or `user unadmin EMAIL`: prints what
            # admin_change did and answers the exit status.
            def self.grant_admin(email, granted)
              line = UserCommand.admin_change(email, granted)
              puts line
              line.start_with?("error: ") ? 1 : 0
            end

            # Sets the admin flag of the user with this address, who must exist,
            # and answers the line to print: "admin ann@example.com",
            # "unadmin ann@example.com" or "error: ...".
            def self.admin_change(email, granted)
              address = User.normalize_email_address(email)
              found = User.find_by(email_address: address)
              return "error: no user \#{address}" if found.nil?

              found.admin = granted
              return "error: \#{found.errors.full_messages.join(", ")}" unless found.save

              granted ? "admin \#{address}" : "unadmin \#{address}"
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
        RUBY
      end

      # --invite-only: the boot warning and the question it asks, indented
      # into the module.
      def self.user_command_warning(app)
        text = <<~RUBY

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
        RUBY
        indent(text)
      end

      # Inserted before the Main.run line of bin/<app>.rb; with
      # --invite-only it also runs the boot warning.
      def self.bin_block(app, invite_only = false)
        if invite_only
          return <<~RUBY
            # `./#{app} user EMAIL [PASSWORD]`, `./#{app} user admin EMAIL` and
            # `./#{app} user unadmin EMAIL`, and a [WARN] at boot while no user exists
            # (cybertrain generate authentication --invite-only).
            #{COMMAND_REQUIRE}
            UserCommand.warn_if_no_user if Cybertrain::Main.server?(ARGV)

          RUBY
        end

        <<~RUBY
          # `./#{app} user EMAIL [PASSWORD]`, `./#{app} user admin EMAIL` and
          # `./#{app} user unadmin EMAIL` (cybertrain generate authentication).
          #{COMMAND_REQUIRE}

        RUBY
      end

      # Inserted (indented) after the configure line of config/app.rb, in
      # both modes.
      def self.base_url_block(app)
        env = base_url_env(app)
        <<~RUBY
          # Links in mails (the password reset's) start with this, as in
          # #{env}=https://#{app}.example.com. Unset, they take the address
          # the request came to, which production trusts only when
          # CYBERTRAIN_HOSTS lists the app's hosts; with neither, a reset mail is
          # not sent and the log says why.
          c.setting_string :base_url, env: "#{env}", default: ""

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
            #{PASSWORDS_ROUTE}
            get "/setup", to: "setup#new", as: "setup"
            post "/setup", to: "setup#create"
          RUBY
        end

        <<~RUBY
          resource :session, only: [:new, :create, :destroy]
          #{PASSWORDS_ROUTE}
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
          require "cybertrain/test/jobs"
          require_relative "../../config/app"
          require_relative "../../gen/app"
          require_relative "../../gen/migrations"

          # No request log: `spin test` diffs the whole output against the
          # snapshot, and "Completed 303 in 246ms" is never the same twice.
          Cybertrain.config.log_level = :none

          # Webhooks and e-mail the app sends are received in-process: require
          # "cybertrain/test/http_receiver" or "cybertrain/test/smtp_receiver",
          # then `port = receiver.start`, point the app at 127.0.0.1:port
          # (HttpClient needs `Cybertrain.config.http_allow_private = true`, the
          # Mailer `tls: "none"`), and read `receiver.received_request` /
          # `received_message` before `receiver.stop`. Every wait is bounded.

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

      # test/admin.rb: the admin flag, require_admin (through the jobs page
      # config/routes.rb draws behind it) and the user command's admin and
      # unadmin.
      def self.admin_test(app)
        <<~RUBY
          # The admin flag (cybertrain generate authentication): User#admin?,
          # require_admin (the Authentication concern's before_action, which the
          # jobs page in config/routes.rb names) and `./#{app} user admin EMAIL`.
          # Run with `cybertrain spin test`; its snapshot comes from the compiled
          # binary (the database is FFI).
          require_relative "support/app_test"
          require_relative "../app/commands/user_command"

          def new_client
            Session.all.delete_all
            User.all.delete_all
            Cybertrain::Test::Client.new(APP)
          end

          # require_admin is private (the Authentication concern's): a controller
          # made for this test calls it, as a before_action would.
          class AdminProbeController < ApplicationController
            def probe_require_admin
              require_admin
            end
          end

          test "user.admin? is false for a new user" do
            new_client
            user = AppTest.user
            assert_equal false, user.admin?
            assert_equal false, User.find(user.id).admin?
            user.admin = true
            user.save!
            assert_equal true, User.find(user.id).admin?
          end

          test "require_admin answers 404 to a visitor and a non-admin and 200 to an admin" do
            # A visitor (no @current_user): require_admin itself answers 404.
            ctx = Cybertrain::Context.new(Cybertrain::Request.new("GET", "/admin/jobs", {}, ""))
            ctx.session = Cybertrain::Session.new
            probe = AdminProbeController.new(ctx)
            probe.probe_require_admin
            assert probe.performed?
            assert_equal 404, ctx.response.status
            assert_equal "Not Found", ctx.response.body
            # Through the full stack the same: the jobs page runs require_admin
            # alone (no redirect to sign in, which would show the page exists).
            client = new_client
            res = client.get("/admin/jobs")
            assert_response res, :not_found
            assert_equal "Not Found", res.body
            # Signed in, not an admin: 404, as if there were no such page; the
            # same body and type as a path no route has.
            user = AppTest.user
            AppTest.sign_in(client)
            res = client.get("/admin/jobs")
            assert_response res, :not_found
            assert_equal "Not Found", res.body
            refute res.body.include?("<h1>Jobs</h1>")
            missing = client.get("/admin/no-such-page")
            assert_response missing, :not_found
            assert_equal missing.body, res.body
            assert_equal missing.header("content-type"), res.header("content-type")
            # Made an admin, the same browser sees the page.
            user.admin = true
            user.save!
            res = client.get("/admin/jobs")
            assert_response res, :ok
            assert_includes res.body, "<h1>Jobs</h1>"
            # And no more once that is taken back.
            user.admin = false
            user.save!
            res = client.get("/admin/jobs")
            assert_response res, :not_found
          end

          test "./#{app} user admin and unadmin print what they did" do
            new_client
            AppTest.user
            assert_equal "admin ann@example.com", UserCommand.admin_change("Ann@Example.com", true)
            assert_equal true, User.first.admin?
            assert_equal "unadmin ann@example.com", UserCommand.admin_change("ann@example.com", false)
            assert_equal false, User.first.admin?
            assert_equal "error: no user bob@example.com", UserCommand.admin_change("bob@example.com", true)
            assert_equal 1, User.count
          end

          test "./#{app} user admin and unadmin set the flag of an existing user" do
            new_client
            AppTest.user
            assert_equal 0, UserCommand.run(["admin", "Ann@Example.com"])
            assert_equal true, User.first.admin?
            assert_equal 0, UserCommand.run(["unadmin", "ann@example.com"])
            assert_equal false, User.first.admin?
            assert_equal 1, UserCommand.run(["admin", "bob@example.com"])
            assert_equal 1, UserCommand.run(["admin"])
            assert_equal 1, UserCommand.run(["unadmin", "ann@example.com", "extra"])
            assert_equal 1, User.count
            assert_equal false, User.first.admin?
          end

          Cybertrain::Test.run!
        RUBY
      end

      # test/remember_me.rb: how long a sign-in lasts, remembered or not, and
      # the idle limit, proved by moving a Session row's created_at and
      # last_active_at back (the cookie's own limit is the framework's
      # test/session.rb).
      def self.remember_me_test
        <<~'RUBY'
          # "Keep me signed in" and the idle limit (cybertrain generate
          # authentication): a sign-in lasts session_absolute_max_age (two weeks)
          # unless the box was checked (auth_remember_for, 30 days), and ends
          # either way after auth_idle_timeout (7 days) without a request. The
          # tests move the Session row's created_at and last_active_at back in
          # time rather than wait; the cookie's own limit (the stamp
          # start_new_session_for writes) is the framework's to enforce. Run with
          # `cybertrain spin test`; its snapshot comes from the compiled binary
          # (the database is FFI).
          require_relative "support/app_test"

          DAY = 24 * 60 * 60

          def new_client
            Session.all.delete_all
            User.all.delete_all
            Cybertrain::Test::Client.new(APP)
          end

          # Signs client in through the form as AppTest.sign_in does, the box
          # checked or not.
          def sign_in_with(client, remember)
            Cybertrain::RateLimit.reset_all!
            client.get("/session/new")
            fields = { "authenticity_token" => AppTest.form_token(client),
                       "email_address" => "ann@example.com", "password" => "s3cr3t-s3cr3t" }
            fields["remember_me"] = "1" if remember
            client.post("/session", fields)
          end

          # The first (in these tests, the browser's only) Session row, as if
          # started `started` seconds ago and last used `idle` seconds ago.
          def backdate(started, idle)
            now = Time.now.to_i
            Session.first.update_columns(created_at: Time.at(now - started).utc, last_active_at: Time.at(now - idle).utc)
            nil
          end

          # Whether client is still signed in: the nav names the user.
          def signed_in?(client)
            client.get("/session/new").body.include?("<span>ann@example.com</span>")
          end

          # The session cookie client holds now, as a request header.
          def cookie_header(client)
            name = Cybertrain.config.session_cookie_name
            "#{name}=#{client.cookies[name]}"
          end

          # Whether a copy of an old cookie (kept by whoever had it) signs in.
          def replayed_signed_in?(client, cookie)
            client.get("/session/new", { "cookie" => cookie }).body.include?("<span>ann@example.com</span>")
          end

          # The Set-Cookie line of the session cookie in res ("" when none).
          def session_cookie(res)
            prefix = "#{Cybertrain.config.session_cookie_name}="
            found = ""
            res.cookies.each { |line| found = line if line.start_with?(prefix) }
            found
          end

          # start_new_session_for is private (the Authentication concern's): a
          # controller made for these tests calls it, as an action would.
          class LifetimeProbeController < ApplicationController
            def probe_start(user, remember)
              start_new_session_for(user, remember: remember)
            end
          end

          # The cookie session start_new_session_for leaves for user.
          def stamped_session(user, remember)
            ctx = Cybertrain::Context.new(Cybertrain::Request.new("POST", "/session", {}, ""))
            ctx.session = Cybertrain::Session.new
            LifetimeProbeController.new(ctx).probe_start(user, remember)
            ctx.session
          end

          test "a remembered session is alive on day 15 and ended after day 30" do
            client = new_client
            AppTest.user
            res = sign_in_with(client, true)
            assert_redirected_to res, "/"
            assert_equal true, Session.first.remember
            assert session_cookie(res).end_with?("; Max-Age=2592000"), session_cookie(res)
            backdate(15 * DAY, 0)
            assert signed_in?(client)
            backdate(30 * DAY - 60, 0)
            assert signed_in?(client)
            cookie = cookie_header(client)
            backdate(30 * DAY, 0)
            refute signed_in?(client)
            # Ended: the row is gone, so a longer limit set afterwards does not
            # bring back a copy of the cookie.
            assert_equal 0, Session.count
            remember_for = Cybertrain.config.auth_remember_for
            begin
              Cybertrain.config.auth_remember_for = 60 * DAY
              refute replayed_signed_in?(client, cookie)
            ensure
              Cybertrain.config.auth_remember_for = remember_for
            end
          end

          test "an unremembered session ends after day 14" do
            client = new_client
            AppTest.user
            res = sign_in_with(client, false)
            assert_redirected_to res, "/"
            assert_equal false, Session.first.remember
            backdate(14 * DAY - 60, 0)
            assert signed_in?(client)
            backdate(14 * DAY, 0)
            refute signed_in?(client)
            # Day 15, where a remembered one is alive.
            client = new_client
            AppTest.user
            sign_in_with(client, false)
            backdate(15 * DAY, 0)
            refute signed_in?(client)
          end

          test "an unremembered session still ends with session_absolute_max_age off" do
            absolute = Cybertrain.config.session_absolute_max_age
            max_age = Cybertrain.config.session_max_age
            remember_for = Cybertrain.config.auth_remember_for
            begin
              # Off (0): the limit is session_max_age (two weeks), stamped on
              # the cookie and checked on the row.
              Cybertrain.config.session_absolute_max_age = 0
              client = new_client
              user = AppTest.user
              res = sign_in_with(client, false)
              assert_redirected_to res, "/"
              refute session_cookie(res).empty?
              refute session_cookie(res).include?("Max-Age")
              backdate(14 * DAY - 60, 0)
              assert signed_in?(client)
              backdate(14 * DAY, 0)
              refute signed_in?(client)
              # The stamp itself (each probe adds a Session row of its own, so
              # no backdate follows).
              stamped = stamped_session(user, false)
              assert_equal 1_209_600, stamped.lifetime_limit
              assert stamped.browser_session?
              # session_max_age not positive either: two weeks all the same.
              Cybertrain.config.session_max_age = 0
              assert_equal 1_209_600, stamped_session(user, false).lifetime_limit
              # A limit of its own is stamped as it is; a remembered sign-in
              # takes auth_remember_for and a Max-Age (not a browser session).
              Cybertrain.config.session_absolute_max_age = 3600
              assert_equal 3600, stamped_session(user, false).lifetime_limit
              remembered = stamped_session(user, true)
              assert_equal 2_592_000, remembered.lifetime_limit
              refute remembered.browser_session?
              # auth_remember_for not positive (set at run time, past boot's
              # check): the same chain as an unremembered sign-in, still
              # persistent.
              Cybertrain.config.auth_remember_for = 0
              remembered = stamped_session(user, true)
              assert_equal 3600, remembered.lifetime_limit
              refute remembered.browser_session?
              Cybertrain.config.session_absolute_max_age = 0
              Cybertrain.config.session_max_age = 0
              assert_equal 1_209_600, stamped_session(user, true).lifetime_limit
            ensure
              Cybertrain.config.session_absolute_max_age = absolute
              Cybertrain.config.session_max_age = max_age
              Cybertrain.config.auth_remember_for = remember_for
            end
          end

          test "both end after 7 idle days" do
            [true, false].each do |remember|
              client = new_client
              AppTest.user
              sign_in_with(client, remember)
              backdate(8 * DAY, 7 * DAY - 60)
              assert signed_in?(client)
              cookie = cookie_header(client)
              backdate(8 * DAY, 7 * DAY)
              refute signed_in?(client)
              # Ended: the row is gone, so turning the idle limit off afterwards
              # does not bring back a copy of the cookie.
              assert_equal 0, Session.count
              idle = Cybertrain.config.auth_idle_timeout
              begin
                Cybertrain.config.auth_idle_timeout = 0
                refute replayed_signed_in?(client, cookie)
              ensure
                Cybertrain.config.auth_idle_timeout = idle
              end
            end
            # A row with no last_active_at is idle since created_at.
            client = new_client
            AppTest.user
            sign_in_with(client, true)
            now = Time.now.to_i
            Session.first.update_columns(created_at: Time.at(now - 7 * DAY + 60).utc, last_active_at: nil)
            assert signed_in?(client)
            refute Session.first.last_active_at.nil?
            Session.first.update_columns(created_at: Time.at(now - 7 * DAY).utc, last_active_at: nil)
            refute signed_in?(client)
            assert_equal 0, Session.count
            # auth_idle_timeout 0: no idle limit, the absolute one alone.
            idle = Cybertrain.config.auth_idle_timeout
            begin
              Cybertrain.config.auth_idle_timeout = 0
              client = new_client
              AppTest.user
              sign_in_with(client, true)
              backdate(29 * DAY, 29 * DAY)
              assert signed_in?(client)
              backdate(30 * DAY, 29 * DAY)
              refute signed_in?(client)
            ensure
              Cybertrain.config.auth_idle_timeout = idle
            end
          end

          test "last_active_at is touched at most once a minute" do
            client = new_client
            AppTest.user
            before = Time.now.to_i
            sign_in_with(client, false)
            started = Session.first.last_active_at
            refute started.nil?
            assert started.to_i >= before
            # Used 30 seconds ago: a request does not write the row.
            now = Time.now.to_i
            Session.first.update_columns(last_active_at: Time.at(now - 30).utc)
            updated_at = Session.first.updated_at.to_i
            assert signed_in?(client)
            assert_equal now - 30, Session.first.last_active_at.to_i
            # Used 61 seconds ago: the request moves it to now, and leaves
            # updated_at alone.
            Session.first.update_columns(last_active_at: Time.at(now - 61).utc)
            assert signed_in?(client)
            assert Session.first.last_active_at.to_i >= now
            assert_equal updated_at, Session.first.updated_at.to_i
          end

          test "an unremembered sign-in sets a cookie without Max-Age" do
            client = new_client
            AppTest.user
            res = sign_in_with(client, false)
            assert_redirected_to res, "/"
            cookie = session_cookie(res)
            refute cookie.empty?
            refute cookie.include?("Max-Age")
            refute cookie.include?("Expires")
            # The box checked, the same cookie lasts auth_remember_for.
            client = new_client
            AppTest.user
            res = sign_in_with(client, true)
            cookie = session_cookie(res)
            assert cookie.end_with?("; Max-Age=2592000"), cookie
            refute cookie.include?("Expires")
          end

          Cybertrain::Test.run!
        RUBY
      end

      # test/lockout.rb: auth_lockout_attempts wrong passwords lock the
      # account, the lock answers as a wrong password does, and a successful
      # sign-in clears the count.
      def self.lockout_test
        <<~'RUBY'
          # Account lockout (cybertrain generate authentication):
          # auth_lockout_attempts (10) wrong passwords in a row lock the account
          # for auth_lockout_period (an hour); while it is locked even the right
          # password gets the wrong-password message; a successful sign-in clears
          # the count. SessionsController's rate_limit (ten attempts per address
          # in three minutes) would answer the eleventh attempt first, so every
          # attempt here forgets its counts (AppTest.sign_in calls
          # Cybertrain::RateLimit.reset_all!). Run with `cybertrain spin test`;
          # its snapshot comes from the compiled binary (the database is FFI).
          require_relative "support/app_test"
          require_relative "../app/commands/user_command"

          WRONG = "<p class=\"alert\">Try another email address or password.</p>"

          def new_client
            Session.all.delete_all
            User.all.delete_all
            Cybertrain::Test::Client.new(APP)
          end

          # One sign-in attempt through the form, the rate limit's counts
          # forgotten first; returns the page the redirect leads to.
          def attempt(client, password)
            res = AppTest.sign_in(client, "ann@example.com", password)
            assert_response res, :see_other
            client.follow_redirect!
          end

          # Ten wrong passwords: the account is locked.
          def lock(client)
            10.times { attempt(client, "wrong-password") }
            nil
          end

          test "10 failures lock the account for an hour with the wrong-password message" do
            client = new_client
            user = AppTest.user
            assert_equal 0, user.failed_attempts
            9.times do |i|
              page = attempt(client, "wrong-password")
              assert_includes page.body, WRONG
              assert_equal i + 1, User.find(user.id).failed_attempts
              assert_nil User.find(user.id).locked_until
              refute User.find(user.id).locked?
            end
            before = Time.now.to_i
            page = attempt(client, "wrong-password")
            after = Time.now.to_i
            assert_includes page.body, WRONG
            locked = User.find(user.id)
            assert locked.locked?
            refute locked.locked_until.nil?
            assert locked.locked_until.to_i >= before + 3600
            assert locked.locked_until.to_i <= after + 3600
            assert_equal 0, locked.failed_attempts
            assert_equal 0, Session.count
          end

          test "a locked account refuses the right password until locked_until passes" do
            client = new_client
            user = AppTest.user
            lock(client)
            ends = User.find(user.id).locked_until.to_i
            # The eleventh attempt, the right password: the rate limit's counts
            # are forgotten (AppTest.sign_in), so it is the lock that answers,
            # with the wrong-password message.
            res = AppTest.sign_in(client)
            assert_redirected_to res, "/session/new"
            page = client.follow_redirect!
            assert_includes page.body, WRONG
            refute page.body.include?("Try again later.")
            assert_equal 0, Session.count
            # Refused while locked, neither counted nor extended.
            assert_equal 0, User.find(user.id).failed_attempts
            assert_equal ends, User.find(user.id).locked_until.to_i
            # A minute before the lock ends: still refused.
            User.find(user.id).update_columns(locked_until: Time.at(Time.now.to_i + 60).utc)
            page = attempt(client, "s3cr3t-s3cr3t")
            assert_includes page.body, WRONG
            assert_equal 0, Session.count
            # Once it has passed, the right password signs in and the lock is gone.
            User.find(user.id).update_columns(locked_until: Time.at(Time.now.to_i - 1).utc)
            res = AppTest.sign_in(client)
            assert_redirected_to res, "/"
            assert_equal 1, Session.count
            assert_nil User.find(user.id).locked_until
            assert_equal 0, User.find(user.id).failed_attempts
          end

          test "a successful sign-in clears the count" do
            client = new_client
            user = AppTest.user
            3.times { attempt(client, "wrong-password") }
            assert_equal 3, User.find(user.id).failed_attempts
            res = AppTest.sign_in(client)
            assert_redirected_to res, "/"
            assert_equal 0, User.find(user.id).failed_attempts
            assert_nil User.find(user.id).locked_until
            # The count starts again: nine more wrong passwords do not lock.
            9.times { attempt(client, "wrong-password") }
            assert_equal 9, User.find(user.id).failed_attempts
            assert_nil User.find(user.id).locked_until
            refute User.find(user.id).locked?
          end

          test "./APP user EMAIL PASSWORD clears a lock" do
            client = new_client
            user = AppTest.user
            lock(client)
            assert User.find(user.id).locked?
            assert_equal 0, UserCommand.run(["ann@example.com", "an0ther-s3cr3t"])
            assert_nil User.find(user.id).locked_until
            assert_equal 0, User.find(user.id).failed_attempts
            res = AppTest.sign_in(client, "ann@example.com", "an0ther-s3cr3t")
            assert_redirected_to res, "/"
            assert_equal 1, Session.count
            # Some failures, no lock: the count is cleared too.
            client = new_client
            user = AppTest.user
            3.times { attempt(client, "wrong-password") }
            assert_equal 0, UserCommand.run(["ann@example.com", "an0ther-s3cr3t"])
            assert_equal 0, User.find(user.id).failed_attempts
          end

          test "with auth_lockout_attempts 0 an existing lock is not enforced" do
            client = new_client
            user = AppTest.user
            lock(client)
            attempts = Cybertrain.config.auth_lockout_attempts
            begin
              Cybertrain.config.auth_lockout_attempts = 0
              # Lockout off: the lock no longer refuses the right password, and
              # the sign-in clears it.
              refute User.find(user.id).locked_until.nil?
              res = AppTest.sign_in(client)
              assert_redirected_to res, "/"
              assert_equal 1, Session.count
              assert_nil User.find(user.id).locked_until
            ensure
              Cybertrain.config.auth_lockout_attempts = attempts
            end
            # Lockout on again, the same lock is enforced (made afresh).
            client = new_client
            user = AppTest.user
            lock(client)
            res = AppTest.sign_in(client)
            assert_redirected_to res, "/session/new"
            assert_equal 0, Session.count
          end

          test "auth_lockout_attempts 0 never locks" do
            attempts = Cybertrain.config.auth_lockout_attempts
            begin
              Cybertrain.config.auth_lockout_attempts = 0
              client = new_client
              user = AppTest.user
              11.times { attempt(client, "wrong-password") }
              assert_equal 0, User.find(user.id).failed_attempts
              assert_nil User.find(user.id).locked_until
              res = AppTest.sign_in(client)
              assert_redirected_to res, "/"
              assert_equal 1, Session.count
            ensure
              Cybertrain.config.auth_lockout_attempts = attempts
            end
          end

          Cybertrain::Test.run!
        RUBY
      end

      # test/support/authentication_helpers.rb (D20): what the
      # authentication tests share beyond AppTest.
      def self.authentication_helpers
        <<~'RUBY'
          # Helpers for the authentication tests (cybertrain generate
          # authentication): mail sent to an SMTP receiver in this process, the link
          # a mail carries, and a Session row moved back in time. Required by the
          # test files, not run.
          require "cybertrain/test/smtp_receiver"
          require_relative "app_test"

          # Runs the block with the app's mail going to a receiver on 127.0.0.1
          # (Config#smtp_*: plain text, from noreply@example.com), then stops the
          # receiver and puts the settings back. A mail sent with deliver_later
          # goes out when the test runs the jobs (perform_enqueued_jobs).
          def with_smtp_receiver
            receiver = Cybertrain::Test::SmtpReceiver.new
            port = receiver.start
            c = Cybertrain.config
            host = c.smtp_host
            given_port = c.smtp_port
            tls = c.smtp_tls
            from = c.smtp_from
            c.smtp_host = "127.0.0.1"
            c.smtp_port = port
            c.smtp_tls = "none"
            c.smtp_from = "noreply@example.com"
            yield receiver
            receiver.stop
            c.smtp_host = host
            c.smtp_port = given_port
            c.smtp_tls = tls
            c.smtp_from = from
            nil
          end

          # The first http:// or https:// link in the text of the last mail the
          # receiver got (waiting at most 5 seconds for it); "" when none came.
          def last_mail_link(receiver)
            messages = receiver.received_messages
            return "" if messages.empty?

            text = messages.last.message_parts["text"].to_s
            start = text.index("https://")
            plain = text.index("http://")
            start = plain if start.nil? || (!plain.nil? && plain < start)
            return "" if start.nil?

            stop = start
            while stop < text.size && text[stop] != " " && text[stop] != "\r" && text[stop] != "\n"
              stop += 1
            end
            text[start, stop - start].to_s
          end

          # A Session row as if it had started, and last been used, `seconds`
          # ago.
          def backdate_session(row, seconds)
            at = Time.at(Time.now.to_i - seconds).utc
            row.update_columns(created_at: at, last_active_at: at)
            nil
          end
        RUBY
      end

      # Stands for the app's base_url variable in passwords_test_body.
      BASE_URL_ENV_MARK = "@BASE_URL_ENV@"

      # test/passwords.rb: the reset through the stack, the mail through the
      # SMTP receiver.
      def self.passwords_test(app)
        env = base_url_env(app)
        body = passwords_test_body
        body.gsub(BASE_URL_ENV_MARK, env)
      end

      def self.passwords_test_body
        <<~'RUBY'
          # Password reset (cybertrain generate authentication): the address form,
          # the mail (through an SMTP receiver in this process), the link's token
          # (15 minutes, bound to the password) and what a reset ends. Run with
          # `cybertrain spin test`; its snapshot comes from the compiled binary (the
          # database is FFI).
          require "stringio"
          require_relative "support/app_test"
          require_relative "support/authentication_helpers"

          SENT = "<p class=\"notice\">If that address is registered, a link to reset the password was sent to it.</p>"
          INVALID = "<p class=\"alert\">That password reset link is invalid or has expired.</p>"
          UPDATED = "<p class=\"notice\">Your password has been reset. Sign in with the new one.</p>"
          NEW_PASSWORD = "n3w-s3cr3t-n3w"

          def new_client
            Session.all.delete_all
            User.all.delete_all
            clear_enqueued_jobs
            Cybertrain::Test::Client.new(APP)
          end

          # Sends the address form as a browser would, with the Host header
          # given. The rate limit's counts are forgotten first, as AppTest.sign_in
          # does.
          def request_reset(client, email_address, host = "www.example.com")
            Cybertrain::RateLimit.reset_all!
            client.get("/passwords/new")
            fields = { "authenticity_token" => AppTest.form_token(client), "email_address" => email_address }
            client.post("/passwords", fields, { "host" => host })
          end

          # Sends the new-password form of the link with this token.
          def reset_with(client, token, password, confirmation = password)
            client.get("/passwords/new")
            fields = { "authenticity_token" => AppTest.form_token(client),
                       "password" => password, "password_confirmation" => confirmation }
            client.put("/passwords/#{token}", fields)
          end

          # The token in a link ("https://.../passwords/<token>/edit").
          def token_in(link)
            start = link.index("/passwords/").to_i + 11
            stop = link.index("/edit").to_i
            link[start, stop - start].to_s
          end

          # Whether client is signed in as email_address: the nav names them.
          def signed_in?(client, email_address = "ann@example.com")
            client.get("/session/new").body.include?("<span>#{email_address}</span>")
          end

          test "reset answers the same for unknown addresses and links to base_url" do
            client = new_client
            AppTest.user
            Cybertrain.config.set_string_setting(:base_url, "https://shop.example")
            with_smtp_receiver do |receiver|
              # A forged Host on both: the link takes base_url, never the header.
              known = request_reset(client, "Ann@Example.com", "evil.example")
              known_status = known.status
              known_location = known.header("Location")
              known_body = known.body
              known_page = client.follow_redirect!.body
              assert_enqueued_jobs 1, "cybertrain mail"
              unknown = request_reset(client, "nobody@example.com", "evil.example")
              assert_equal 303, known_status
              assert_equal known_status, unknown.status
              assert_equal "/session/new", known_location
              assert_equal known_location, unknown.header("Location")
              assert_equal known_body, unknown.body
              unknown_page = client.follow_redirect!.body
              assert_includes known_page, SENT
              assert_includes unknown_page, SENT
              # One mail, for the registered address only.
              assert_enqueued_jobs 1, "cybertrain mail"
              assert_equal 1, perform_enqueued_jobs
              link = last_mail_link(receiver)
              assert link.start_with?("https://shop.example/passwords/"), link
              assert link.end_with?("/edit"), link
              refute link.include?("evil.example")
              # The link works once.
              token = token_in(link)
              res = client.get("/passwords/#{token}/edit")
              assert_response res, :ok
              assert_redirected_to reset_with(client, token, NEW_PASSWORD), "/session/new"
              res = client.get("/passwords/#{token}/edit")
              assert_redirected_to res, "/passwords/new"
            end
            Cybertrain.config.set_string_setting(:base_url, "")
          end

          test "without base_url a link takes the request's address only where that is safe" do
            client = new_client
            AppTest.user
            config = Cybertrain.config
            config.set_string_setting(:base_url, "")
            hosts = config.hosts_from_env
            # Outside production: the address the request came to.
            with_smtp_receiver do |receiver|
              request_reset(client, "ann@example.com", "www.example.com")
              assert_equal 1, perform_enqueued_jobs
              link = last_mail_link(receiver)
              assert link.start_with?("http://www.example.com/passwords/"), link
            end
            # Production with CYBERTRAIN_HOSTS (the Host header is checked): the
            # request's address too.
            config.env = "production"
            config.hosts_from_env = ["shop.example"]
            assert config.host_check?
            res = request_reset(client, "ann@example.com", "shop.example")
            config.env = "test"
            config.hosts_from_env = hosts
            assert_redirected_to res, "/session/new"
            with_smtp_receiver do |receiver|
              assert_equal 1, perform_enqueued_jobs
              link = last_mail_link(receiver)
              assert link.start_with?("http://shop.example/passwords/"), link
            end
            # Production with base_url: base_url, whatever the Host.
            config.env = "production"
            config.set_string_setting(:base_url, "https://shop.example")
            res = request_reset(client, "ann@example.com", "evil.example")
            config.env = "test"
            config.set_string_setting(:base_url, "")
            assert_redirected_to res, "/session/new"
            with_smtp_receiver do |receiver|
              assert_equal 1, perform_enqueued_jobs
              link = last_mail_link(receiver)
              assert link.start_with?("https://shop.example/passwords/"), link
            end
            # Production with neither: no mail, an [ERROR] line, the same answer.
            log = StringIO.new
            logger = Cybertrain.logger
            Cybertrain.logger = Cybertrain::Logger.new(log, :error)
            config.env = "production"
            refute config.host_check?
            res = request_reset(client, "ann@example.com", "evil.example")
            config.env = "test"
            Cybertrain.logger = logger
            assert_redirected_to res, "/session/new"
            assert_includes client.follow_redirect!.body, SENT
            assert_no_enqueued_jobs "cybertrain mail"
            assert_includes log.string, "[ERROR] password reset mail not sent: set @BASE_URL_ENV@ (or CYBERTRAIN_HOSTS)\n"
          end

          test "the token expires after 15 minutes" do
            client = new_client
            user = AppTest.user
            now = Time.now.to_i
            assert user.password_reset_token(now).start_with?("#{user.id}--#{now + 15 * 60}--")
            stale = user.password_reset_token(now - 16 * 60)
            fresh = user.password_reset_token(now - 14 * 60)
            assert_nil User.find_by_password_reset_token(stale)
            found = User.find_by_password_reset_token(fresh)
            refute found.nil?
            assert_equal user.id, found.id
            res = client.get("/passwords/#{stale}/edit")
            assert_redirected_to res, "/passwords/new"
            assert_includes client.follow_redirect!.body, INVALID
            assert_redirected_to reset_with(client, stale, NEW_PASSWORD), "/passwords/new"
            assert_equal user.password_digest, User.find_by(id: user.id).password_digest
            res = client.get("/passwords/#{fresh}/edit")
            assert_response res, :ok
            assert_includes res.body, "<form action=\"/passwords/#{fresh}\" method=\"post\"><input type=\"hidden\" name=\"_method\" value=\"put\">"
          end

          test "the token stops working once the password changed" do
            client = new_client
            ann = AppTest.user
            bob = AppTest.user("bob@example.com")
            token = ann.password_reset_token
            earlier = ann.password_reset_token(Time.now.to_i - 60)
            # A token names its user and is bound to that user's password: one
            # with bob's id and ann's password, or another purpose, is no one's.
            assert_equal ann.id, User.find_by_password_reset_token(token).id
            assert_equal bob.id, User.find_by_password_reset_token(bob.password_reset_token).id
            assert_nil User.find_by_password_reset_token(Cybertrain::Token.issue("password_reset", bob.id, 15 * 60, ann.password_digest))
            assert_nil User.find_by_password_reset_token(Cybertrain::Token.issue("confirmation", ann.id, 15 * 60, ann.password_digest))
            assert_nil User.find_by_password_reset_token("")
            # A new password that does not pass: the token still holds.
            res = reset_with(client, token, NEW_PASSWORD, "something-else")
            assert_redirected_to res, "/passwords/#{token}/edit"
            assert_includes client.follow_redirect!.body, "<p class=\"alert\">Password confirmation doesn&#39;t match Password</p>"
            refute User.find_by_password_reset_token(token).nil?
            assert_redirected_to reset_with(client, token, NEW_PASSWORD), "/session/new"
            # Used once, the link is spent, and so is every link sent before.
            assert_redirected_to client.get("/passwords/#{token}/edit"), "/passwords/new"
            assert_redirected_to reset_with(client, earlier, "an0ther-s3cr3t"), "/passwords/new"
            assert_includes client.follow_redirect!.body, INVALID
            assert_redirected_to AppTest.sign_in(client, "ann@example.com", NEW_PASSWORD), "/"
            # bob's link is not ann's change: it still works.
            refute User.find_by_password_reset_token(bob.password_reset_token).nil?
            # A password changed any other way ends a link too.
            changed = User.find_by(email_address: "ann@example.com")
            fresh = changed.password_reset_token
            changed.password = "th1rd-s3cr3t-x"
            changed.save!
            assert_nil User.find_by_password_reset_token(fresh)
          end

          test "updating the password ends every other session" do
            laptop = new_client
            ann = AppTest.user
            AppTest.user("bob@example.com")
            AppTest.sign_in(laptop)
            # The laptop signed in a day ago.
            backdate_session(Session.first, 24 * 60 * 60)
            assert Session.first.created_at.to_i <= Time.now.to_i - 24 * 60 * 60
            phone = Cybertrain::Test::Client.new(APP)
            AppTest.sign_in(phone)
            bobs = Cybertrain::Test::Client.new(APP)
            AppTest.sign_in(bobs, "bob@example.com")
            assert_equal 2, Session.where(user_id: ann.id).count
            assert signed_in?(laptop)
            assert signed_in?(phone)
            stranger = Cybertrain::Test::Client.new(APP)
            res = reset_with(stranger, ann.password_reset_token, NEW_PASSWORD)
            assert_redirected_to res, "/session/new"
            assert_includes stranger.follow_redirect!.body, UPDATED
            assert_equal 0, Session.where(user_id: ann.id).count
            refute signed_in?(laptop)
            refute signed_in?(phone)
            # Another user's sessions are left alone.
            assert_equal 1, Session.count
            assert signed_in?(bobs, "bob@example.com")
            # The old password no longer signs in; the new one does.
            assert_redirected_to AppTest.sign_in(stranger), "/session/new"
            assert_redirected_to AppTest.sign_in(stranger, "ann@example.com", NEW_PASSWORD), "/"
          end

          test "a reset clears a lockout" do
            client = new_client
            ann = AppTest.user
            attempts = 0
            while attempts < Cybertrain.config.auth_lockout_attempts
              AppTest.sign_in(client, "ann@example.com", "wrong-password")
              attempts += 1
            end
            locked = User.find_by(id: ann.id)
            assert locked.locked?
            # While locked, the right password is refused.
            assert_redirected_to AppTest.sign_in(client), "/session/new"
            res = reset_with(client, locked.password_reset_token, NEW_PASSWORD)
            assert_redirected_to res, "/session/new"
            cleared = User.find_by(id: ann.id)
            assert_nil cleared.locked_until
            assert_equal 0, cleared.failed_attempts
            refute cleared.locked?
            assert_redirected_to AppTest.sign_in(client, "ann@example.com", NEW_PASSWORD), "/"
          end

          test "the mail arrives through the SMTP receiver with the dictionary's subject" do
            client = new_client
            AppTest.user
            Cybertrain.config.set_string_setting(:base_url, "https://shop.example/")
            with_smtp_receiver do |receiver|
              request_reset(client, "ann@example.com")
              assert_enqueued_jobs 1, "cybertrain mail"
              assert_equal 1, perform_enqueued_jobs
              mail = receiver.received_message
              refute mail.nil?
              assert_equal "Reset your password", mail.message_header("Subject")
              assert_equal I18n.t("passwords_mailer.reset.subject"), mail.message_header("Subject")
              assert_equal ["ann@example.com"], mail.envelope_recipients
              assert_equal "noreply@example.com", mail.envelope_from
              link = last_mail_link(receiver)
              # base_url's trailing slash is not doubled.
              assert link.start_with?("https://shop.example/passwords/"), link
              parts = mail.message_parts
              assert_equal "Hello ann@example.com,\r\n\r\nYou can choose a new password within the next 15 minutes at this address:\r\n" \
                           "#{link}\r\n\r\nIf you did not ask for this, ignore this mail: your password stays as it is.\r\n", parts["text"]
              assert_includes parts["html"], "<p>Hello ann@example.com,</p>"
              assert_includes parts["html"], "<p><a href=\"#{link}\">Choose a new password</a></p>"
            end
            Cybertrain.config.set_string_setting(:base_url, "")
          end

          test "POST /passwords past ten requests is refused for a while" do
            client = new_client
            AppTest.user
            Cybertrain::RateLimit.reset_all!
            client.get("/passwords/new")
            token = AppTest.form_token(client)
            count = 0
            while count < 10
              res = client.post("/passwords", { "authenticity_token" => token, "email_address" => "nobody@example.com" })
              assert_redirected_to res, "/session/new"
              count += 1
            end
            res = client.post("/passwords", { "authenticity_token" => token, "email_address" => "ann@example.com" })
            assert_redirected_to res, "/passwords/new"
            assert_includes client.follow_redirect!.body, "<p class=\"alert\">Try again later.</p>"
            assert_no_enqueued_jobs "cybertrain mail"
            Cybertrain::RateLimit.reset_all!
          end

          Cybertrain::Test.run!
        RUBY
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
          # `script/regen-snapshot`-style.
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

          # after_authentication_url is private (the Authentication concern's):
          # a controller made for these tests reads it.
          class ReturnPathProbeController < ApplicationController
            def probe_after_authentication_url
              after_authentication_url
            end
          end

          test "authentication returns to a local path once" do
            ctx = Cybertrain::Context.new(Cybertrain::Request.new("GET", "/", {}, ""))
            ctx.session = Cybertrain::Session.new
            controller = ReturnPathProbeController.new(ctx)
            assert_equal "/", controller.probe_after_authentication_url
            ["/", "/products", "/products/1?tab=details#title", "/products//1", "/caf%C3%A9"].each do |path|
              controller.session[:return_to_after_authenticating] = path
              assert_equal path, controller.probe_after_authentication_url
              refute controller.session.key?(:return_to_after_authenticating)
              assert_equal "/", controller.probe_after_authentication_url
            end
          end

          test "authentication rejects unsafe return destinations and consumes them" do
            ctx = Cybertrain::Context.new(Cybertrain::Request.new("GET", "/", {}, ""))
            ctx.session = Cybertrain::Session.new
            controller = ReturnPathProbeController.new(ctx)
            unsafe = ["", "products", "https://evil.example/", "//evil.example/", "///evil.example/",
                      "/\\\\evil.example/", "/products\\\\evil", " //evil.example/", "/記事", "/" + "a" * 2048]
            (0..32).each { |byte| unsafe << "/\#{Cybertrain::Test.binary([byte])}/evil.example/" }
            unsafe << "/\#{Cybertrain::Test.binary([127])}/evil.example/"
            unsafe.each do |path|
              controller.session[:return_to_after_authenticating] = path
              assert_equal "/", controller.probe_after_authentication_url
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
          # The counts live in Cybertrain::Cache, in windows aligned to the
          # epoch: the cache's clock is held still, so the attempts share one
          # window, then moved a whole window on. The ten go to an address no
          # user has: the limit counts per client, whatever the address, and
          # there is no account for lockout (test/lockout.rb) to lock.
          test "POST /session past ten attempts is refused for a while" do
            client = new_client
            AppTest.user
            Cybertrain::RateLimit.reset_all!
            Cybertrain::Cache.clock = -> { 2_000_000_000 }
            begin
              client.get("/session/new")
              wrong_password = { "authenticity_token" => AppTest.form_token(client),
                                 "email_address" => "nobody@example.com", "password" => "wrong-password" }
              right_password = { "authenticity_token" => AppTest.form_token(client),
                                 "email_address" => "ann@example.com", "password" => "s3cr3t-s3cr3t" }
              10.times { client.post("/session", wrong_password) }
              res = client.post("/session", right_password)
              assert_redirected_to res, "/session/new"
              assert_equal 0, Session.count
              res = client.follow_redirect!
              assert_includes res.body, "<p class=\\"alert\\">Try again later.</p>"
              Cybertrain::Cache.clock = -> { 2_000_000_000 + 3 * 60 }
              res = client.post("/session", right_password)
              assert_redirected_to res, "/"
              assert_equal 1, Session.count
            ensure
              # The system clock again, even when an assertion fails: the
              # tests after this one must not run at a frozen time.
              Cybertrain::Cache.clock = -> { Time.now.to_i }
            end
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

              # Keep the session cookie and its row, but move the creation time
              # to the expiration boundary. Saving updates updated_at too;
              # neither that nor a rewritten cookie extends authentication.
              row = Session.first
              row.created_at = Time.at(Time.now.to_i - Cybertrain.config.session_absolute_max_age).utc
              row.save!
              res = client.post("/session", { "_method" => "delete", "authenticity_token" => token },
                                           { "cookie" => cookie })
              assert_redirected_to res, "/session/new"
              assert_equal 0, Session.count
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
