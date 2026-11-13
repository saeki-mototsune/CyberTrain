# `cybertrain generate authentication`: email-and-password sign-in, the way
# Rails 8's `bin/rails generate authentication` writes it, as code the
# application owns (docs/design.md D15):
#
#   db/migrate/*_create_users.rb, *_create_sessions.rb
#   app/models/user.rb, app/models/session.rb
#   app/controllers/concerns/authentication.rb   the Authentication concern
#   app/controllers/sessions_controller.rb, registrations_controller.rb
#   app/controllers/passwords_controller.rb      password reset by mail
#   app/controllers/accounts_controller.rb       the account page: a new
#                                                address or password, or
#                                                the account deleted
#   app/mailers/passwords_mailer.rb              its mail
#   app/commands/user_command.rb                 `./<app> user ...`
#   app/views/sessions/new.html.erb, _nav.html.erb, registrations/new.html.erb
#   app/views/passwords/new.html.erb, edit.html.erb, mail/_password_reset.html.erb
#   app/views/accounts/edit.html.erb
#   test/authentication.rb, test/admin.rb, test/remember_me.rb,
#   test/lockout.rb, test/passwords.rb, test/accounts.rb, test/support/app_test.rb,
#   test/support/authentication_helpers.rb
#
# and these edits: `include Authentication` into
# app/controllers/application_controller.rb, the routes into
# config/routes.rb (and the jobs page's line, a comment until now, drawn
# behind require_admin), the nav partial into the layout, the user command
# into bin/<app>.rb, the base_url setting (<APP>_BASE_URL, where links in
# mails start) into config/app.rb (plus a sign-in in any
# test/attachment_*.rb written before it, which now needs one). Every file is written once
# and every edit is made once, so running the generator again is
# harmless.
#
# Run over an application an older generator wrote (0.4's, or one
# without --confirmable; D19 of docs/superpowers/plans/2026-11-11-phase4b-i18n-auth-plan.md),
# it writes the files that are missing, a db/migrate/<v>_add_authentication_columns.rb
# with the columns the existing migrations lack, and the edits above; a
# file it writes whole that exists with other content is left alone and
# its diff printed (CLI::LineDiff; `patch -p1` applies the whole output),
# or overwritten with --force. 0.4's authentication block in
# ApplicationController (LEGACY_APPLICATION_CONTROLLER_BLOCKS) becomes
# `include Authentication` the same way, --force replacing it only as 0.4
# wrote it, and the jobs page's route follows it.
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
# What it writes needs four of the optional subsystems (docs/design.md
# D81), so it adds their lines to bin/<app>.rb and bin/db.rb, each unless
# it or `require "cybertrain"` is there (Templates.add_requires), in every
# mode and on the upgrade path: `cybertrain/jobs` (the jobs page it draws,
# the job thread that sends the mails), `cybertrain/mailer` (the mailers,
# and User's address check, Mailer.address_problem), `cybertrain/mailer/later`
# (the mails' deliver_later) and `cybertrain/rate_limit` (the rate_limit
# lines of the sign-in, sign-up, reset and account controllers).
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
# minutes and until the password or the address changes; the answer is
# the same for an unknown address. The link starts with the base_url setting, else with
# the request's address only where a forged Host cannot reach it (the
# concern's mail_link_base). A reset clears a lockout and ends every
# session of the user.
#
# The account page (/account/edit, the nav's "Account"): a new address
# (at once; with --confirmable once confirmed) or a new password, either
# only with the current password, and the account deleted (with its
# sessions, in one transaction), only with the password. A new password
# ends the user's other sessions and signs this browser in again,
# remembered as it was. Wrong passwords there are rate limited per client
# address as sign-ins are, and per user.
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
#
# `--confirmable` (either mode) asks each new account to confirm its
# address by mail before it can sign in, and a new address on the account
# page to confirm itself before it takes the old one's place:
#
#   users.confirmed_at, users.unconfirmed_email   (in the users migration)
#   app/controllers/confirmations_controller.rb   the link, and the form
#                                                that sends it again
#   app/mailers/confirmations_mailer.rb, app/views/confirmations/new.html.erb,
#   app/views/mail/_confirmation.html.erb, test/confirmations.rb
#
# plus the confirmations route. Sign-up mails the link and signs nobody
# in; a sign-in with the right password and an address not confirmed yet
# is refused with its own message (the wrong-password one otherwise); the
# link confirms, and the user then signs in. Users made by /setup and by
# the user command are confirmed as they are created: nothing mails them.
require "cybertrain/cli/templates"
require "cybertrain/cli/scaffold"
require "cybertrain/cli/build"
require "cybertrain/cli/line_diff"

module Cybertrain
  module CLI
    module Authentication
      CLASS_LINE = "class ApplicationController < Cybertrain::Controller"
      ROUTE_MARK = "resource :session"
      # The password reset's routes, added after ROUTE_MARK's line to an app
      # whose routes have the sign-in but not these yet.
      PASSWORDS_ROUTE_MARK = "resources :passwords"
      PASSWORDS_ROUTE = "resources :passwords, param: :token, only: [:new, :create, :edit, :update]"
      # The account page's route, added after PASSWORDS_ROUTE_MARK's line the
      # same way.
      ACCOUNT_ROUTE_MARK = "resource :account"
      ACCOUNT_ROUTE = "resource :account, only: [:edit, :update, :destroy]"
      # --confirmable's routes, added after PASSWORDS_ROUTE_MARK's line (so
      # before the account's) the same way.
      CONFIRMATIONS_ROUTE_MARK = "resources :confirmations"
      CONFIRMATIONS_ROUTE = "resources :confirmations, param: :token, only: [:new, :create, :show]"
      # --confirmable's button that withdraws a new address waiting, added
      # after ACCOUNT_ROUTE_MARK's line.
      PENDING_EMAIL_ROUTE_MARK = "/account/pending_email"
      PENDING_EMAIL_ROUTE = "delete \"/account/pending_email\", to: \"accounts#cancel_email_change\", as: \"account_pending_email\""
      NAV_LINE = "<%= render \"sessions/nav\" %>"
      # The subsystem lines its files need (Templates.add_requires), in the
      # order they are added: the jobs page and the mail job's thread, the
      # mailers and User's address check, deliver_later, rate_limit.
      SUBSYSTEM_REQUIRES = ["cybertrain/jobs", "cybertrain/mailer", "cybertrain/mailer/later", "cybertrain/rate_limit"]
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
      # jobs_page_plan's reason for a routes file that draws a jobs_page line
      # of its own (`admin.jobs_page "/jobs", ...`, say) without the skip.
      JOBS_PAGE_OWN_LINE = "it draws a jobs_page line of its own"
      # The authentication block 0.4's generator inserted after CLASS_LINE
      # (v0.4.0's and v0.4.1's application_controller_block, the same text
      # in both), each line indented two spaces as it was inserted
      # (indent). A re-run over a 0.4 application replaces it with
      # `include Authentication`: as a diff to apply by hand, or with
      # --force when the file holds it exactly.
      LEGACY_APPLICATION_CONTROLLER_BLOCKS = [
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
      ]
      # The block's first and last lines, as inserted: where a diff finds an
      # edited block.
      LEGACY_BLOCK_START = "  # ---- Authentication (cybertrain generate authentication) -------------\n"
      LEGACY_BLOCK_END = "  # ---- end of authentication ------------------------------------------\n"
      # The columns the users and sessions migrations above create that an
      # application generated before them may lack: table, column, and the
      # rest of the add_column line. --confirmable's two are CONFIRMABLE_COLUMNS.
      AUTHENTICATION_COLUMNS = [
        ["users", "admin", ":boolean, null: false, default: \"false\""],
        ["users", "failed_attempts", ":integer, null: false, default: \"0\""],
        ["users", "locked_until", ":datetime"],
        ["sessions", "remember", ":boolean, null: false, default: \"false\""],
        ["sessions", "last_active_at", ":datetime"]
      ]
      CONFIRMABLE_COLUMNS = [
        ["users", "confirmed_at", ":datetime"],
        ["users", "unconfirmed_email", ":string"]
      ]
      # What heads each diff in GenerateResult#manual.
      MANUAL_NOTE = "apply this diff by hand, or re-run with --force to overwrite the file"

      # What generate_with_result did: the paths it created, the paths it
      # overwrote (--force) and the changes to make by hand, each a heading
      # line (`manual  <path>: ...`) and a unified diff (LineDiff.unified)
      # that `patch -p1` applies: one per file it writes whole that exists
      # with other content, and one each for ApplicationController and the
      # jobs page's route of an application 0.4 generated.
      class GenerateResult
        # @return [Array<String>] each one's path from the app's root
        #   (`manual`: each one's heading and diff)
        attr_reader :created, :forced, :manual

        def initialize(created, forced, manual)
          @created = created
          @forced = forced
          @manual = manual
        end
      end

      # The paths it created (generate_with_result's `created`).
      def self.generate(root, invite_only = false, confirmable = false)
        generate_with_result(root, invite_only, confirmable).created
      end

      # Writes the files and makes the edits (with `confirmable`, those of
      # --confirmable too). Raises InvalidArgument, before
      # anything is written, when `root` is not an application (no
      # config/routes.rb with the draw line, no
      # app/controllers/application_controller.rb with the class line, no
      # bin/<app>.rb with the Main.run line, no config/app.rb with the
      # configure line).
      #
      # Run again over an application generated before (by 0.4, say, or
      # without --confirmable), it writes the files that are missing, a
      # `<v>_add_authentication_columns.rb` migration with the columns the
      # existing migrations lack, and makes the marker edits. A file it
      # writes whole that exists with other content is left alone and its
      # diff put in `manual`, or, with `force`, overwritten (`forced`). The
      # create_* migrations are never rewritten: they may have run.
      def self.generate_with_result(root, invite_only = false, confirmable = false, force = false)
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

        result = GenerateResult.new(Array.new(0) { "" }, Array.new(0) { "" }, Array.new(0) { "" })
        record_migration(result, root, migration_path(root, "users"), users_migration(confirmable))
        record_migration(result, root, migration_path(root, "sessions"), sessions_migration)
        add_columns = add_columns_migration(root, confirmable)
        record_migration(result, root, add_columns_path(root), add_columns) unless add_columns.empty?
        # Until these two are changed, they do not ask for a confirmation: the
        # concern's start_new_session_for still refuses an unconfirmed account
        # (so neither signs one in), but the user is not told why, and a
        # sign-up gets no link. Their diffs say so first.
        unconfirmed_sign_in = confirmable ? "until this diff is applied, an unconfirmed account's right password is refused without its message (the concern refuses it)" : ""
        unconfirmed_sign_up = confirmable ? "until this diff is applied, a sign-up is mailed no confirmation link (the concern signs it in no more)" : ""
        # An application generated before without --confirmable already has
        # the concern: its confirmation check, the backstop the two warnings
        # above lean on, then arrives only as this diff.
        unconfirmed_concern = confirmable ? "this diff holds the check that refuses an unconfirmed account a session; until it is applied, unconfirmed accounts sign in (whatever the other diffs say)" : ""
        unconfirmed_setup = confirmable ? "until this diff is applied, the first user /setup creates is not confirmed and cannot sign in (a password reset confirms it)" : ""
        record_file(result, root, "app/models/user.rb", user_model(app, confirmable), force)
        record_file(result, root, "app/models/session.rb", session_model, force)
        record_file(result, root, "app/controllers/concerns/authentication.rb", authentication_concern(app, confirmable), force, unconfirmed_concern)
        record_file(result, root, "app/controllers/sessions_controller.rb", sessions_controller(confirmable), force, unconfirmed_sign_in)
        if invite_only
          record_file(result, root, "app/controllers/setup_controller.rb", setup_controller(app, confirmable), force, unconfirmed_setup)
        else
          record_file(result, root, "app/controllers/registrations_controller.rb", registrations_controller(confirmable), force, unconfirmed_sign_up)
        end
        record_file(result, root, "app/controllers/passwords_controller.rb", passwords_controller(confirmable), force)
        record_file(result, root, "app/controllers/confirmations_controller.rb", confirmations_controller, force) if confirmable
        record_file(result, root, "app/controllers/accounts_controller.rb", accounts_controller(confirmable), force)
        record_file(result, root, "app/mailers/passwords_mailer.rb", passwords_mailer, force)
        record_file(result, root, "app/mailers/confirmations_mailer.rb", confirmations_mailer, force) if confirmable
        record_file(result, root, "app/commands/user_command.rb", user_command(app, invite_only, confirmable), force)
        record_file(result, root, "app/views/sessions/new.html.erb", sessions_new_view(invite_only, confirmable), force)
        record_file(result, root, "app/views/sessions/_nav.html.erb", nav_partial, force)
        if invite_only
          record_file(result, root, "app/views/setup/new.html.erb", setup_new_view, force)
        else
          record_file(result, root, "app/views/registrations/new.html.erb", registrations_new_view, force)
        end
        record_file(result, root, "app/views/passwords/new.html.erb", passwords_new_view, force)
        record_file(result, root, "app/views/passwords/edit.html.erb", passwords_edit_view, force)
        record_file(result, root, "app/views/mail/_password_reset.html.erb", password_reset_mail_view, force)
        if confirmable
          record_file(result, root, "app/views/confirmations/new.html.erb", confirmations_new_view, force)
          record_file(result, root, "app/views/mail/_confirmation.html.erb", confirmation_mail_view, force)
        end
        record_file(result, root, "app/views/accounts/edit.html.erb", accounts_edit_view(confirmable), force)
        record_file(result, root, "test/support/app_test.rb", app_test_support(confirmable), force)
        record_file(result, root, "test/support/authentication_helpers.rb", authentication_helpers, force)
        record_file(result, root, "test/authentication.rb", invite_only ? invite_only_test(app) : authentication_test(confirmable), force)
        record_file(result, root, "test/admin.rb", admin_test(app), force)
        record_file(result, root, "test/remember_me.rb", remember_me_test, force)
        record_file(result, root, "test/lockout.rb", lockout_test, force)
        record_file(result, root, "test/passwords.rb", passwords_test(app), force)
        record_file(result, root, "test/accounts.rb", accounts_test(confirmable), force)
        record_file(result, root, "test/confirmations.rb", confirmations_test(app, invite_only), force) if confirmable
        legacy = legacy_application_controller?(File.read(controller_path))
        if legacy
          upgrade_application_controller(result, controller_path, force)
        else
          add_to_application_controller(controller_path)
        end
        add_routes(routes_path, invite_only, confirmable)
        if legacy
          upgrade_jobs_page(result, routes_path, controller_path)
        else
          enable_jobs_page(routes_path, controller_path)
        end
        add_nav_to_layout(File.join(root, "app/views/layouts/application.html.erb"))
        add_sign_in_to_attachment_tests(root)
        add_command_to_bin(bin_path, app, invite_only)
        add_setting_to_config(config_path, app, invite_only)
        Templates.add_requires(root, SUBSYSTEM_REQUIRES)
        result
      end

      # Writes a file the generator writes whole (Templates.write: create,
      # or identical). One that exists with other content is left alone
      # and answered "manual", or, with `force`, overwritten and answered
      # "force".
      # @return [String] "create", "identical", "manual" or "force"
      def self.write_or_diff(root, path, content, force)
        full = File.join(root, path)
        return Templates.write(root, path, content) unless File.exist?(full)

        if LineDiff.as_utf8(File.read(full)) == content
          puts "identical #{path}"
          return "identical"
        end

        if force
          File.write(full, content)
          puts "force  #{path}"
          return "force"
        end
        puts "manual  #{path} (diff below)"
        "manual"
      end

      # write_or_diff, and what it did put into result; `warning`, when
      # given, is a second heading line above the diff.
      def self.record_file(result, root, path, content, force = false, warning = "")
        status = write_or_diff(root, path, content, force)
        if status == "create"
          result.created << path
        elsif status == "force"
          result.forced << path
        elsif status == "manual"
          result.manual << manual_change(path, File.read(File.join(root, path)), content, MANUAL_NOTE, warning)
        end
        nil
      end

      # A migration is written once and never rewritten (it may have run):
      # one that exists with other content is left as it is (Templates.write
      # says "exist"), and the columns it lacks go into the add-columns
      # migration.
      def self.record_migration(result, root, path, content)
        result.created << path if Templates.write(root, path, content) == "create"
        nil
      end

      # GenerateResult#manual's entry: the heading, the warning line if
      # any, and the diff from old_text to new_text.
      def self.manual_change(path, old_text, new_text, note, warning = "")
        out = +""
        out << "manual  #{path}: #{note}\n"
        out << "IMPORTANT: #{warning}\n" unless warning.empty?
        out << LineDiff.unified(path, old_text, new_text)
        out
      end

      # The add_column lines (each indented for the migration's change, and
      # with its newline) of the columns this generator's migrations create
      # that db/schema.rb and db/migrate/*.rb do not have; with
      # `confirmable`, --confirmable's two too.
      def self.missing_column_lines(root, confirmable)
        out = Array.new(0) { "" }
        AUTHENTICATION_COLUMNS.each do |col|
          out << "    add_column \"#{col[0]}\", \"#{col[1]}\", #{col[2]}\n" unless column_present?(root, col[0], col[1])
        end
        if confirmable
          CONFIRMABLE_COLUMNS.each do |col|
            out << "    add_column \"#{col[0]}\", \"#{col[1]}\", #{col[2]}\n" unless column_present?(root, col[0], col[1])
          end
        end
        out
      end

      # The migration that adds the missing columns (missing_column_lines),
      # or "" when none is missing. When it adds users.confirmed_at, the
      # users already there count as confirmed (since they were created):
      # they signed up when nobody was asked to confirm, and would
      # otherwise never sign in again.
      def self.add_columns_migration(root, confirmable)
        lines = missing_column_lines(root, confirmable)
        return "" if lines.empty?

        name = File.basename(add_columns_path(root), ".rb")
        name = name[Scaffold.leading_digits(name).size + 1, name.size].to_s
        out = +""
        out << "# The columns `cybertrain generate authentication` reads that the\n"
        out << "# migrations before this one did not create.\n"
        out << "class #{Inflector.camelize(name)} < Cybertrain::Migration::Base\n"
        out << "  def change\n"
        lines.each { |line| out << line }
        if confirmable && !column_present?(root, "users", "confirmed_at")
          out << "    # The users already here signed up when nobody was asked to\n"
          out << "    # confirm an address: they count as confirmed since they were\n"
          out << "    # created, or none of them could sign in again.\n"
          out << "    reversible do |dir|\n"
          out << "      dir.up { execute \"UPDATE users SET confirmed_at = COALESCE(created_at, strftime('%Y-%m-%d %H:%M:%S.000000', 'now')) WHERE confirmed_at IS NULL\" }\n"
          out << "    end\n"
        end
        out << "  end\n"
        out << "end\n"
        out
      end

      # db/migrate/<version>_add_authentication_columns.rb; when one is
      # there already (an earlier upgrade), the next free name of
      # ..._add_authentication_columns_2.rb, _3 and so on.
      def self.add_columns_path(root)
        base = "add_authentication_columns"
        name = base
        n = 1
        until Dir.glob(File.join(root, "db/migrate/*_#{name}.rb")).empty?
          n += 1
          name = "#{base}_#{n}"
        end
        "db/migrate/#{Scaffold.next_version(root, Scaffold.timestamp)}_#{name}.rb"
      end

      # Whether db/schema.rb or a migration in db/migrate has `column` in
      # `table` (declares_column?).
      def self.column_present?(root, table, column)
        sources = Dir.glob(File.join(root, "db/migrate/*.rb")).sort
        schema = File.join(root, "db/schema.rb")
        sources << schema if File.exist?(schema)
        sources.each do |path|
          return true if declares_column?(File.read(path), table, column)
        end
        false
      end

      # Whether source declares `column` of `table`: a `t.<type> "<column>"`
      # line (its first argument; a symbol too) inside a `create_table
      # "<table>"` block (the schema dump's `s.create_table` too), or an
      # `add_column "<table>", "<column>"` line (symbols too). Each name
      # must end where the line says it does (`:admin_notes` is not
      # `admin`, `:users_archive` not `users`), and comment lines are
      # skipped. Not read: remove_column and change_table (a column they
      # remove still counts, and one they add does not, so db migrate
      # then refuses the duplicate add_column, loudly).
      def self.declares_column?(source, table, column)
        heads = ["create_table \"#{table}\"", "create_table :#{table}", "s.create_table \"#{table}\""]
        names = ["\"#{column}\"", ":#{column}"]
        adds = Array.new(0) { "" }
        ["\"#{table}\"", ":#{table}"].each { |t| names.each { |n| adds << "add_column #{t}, #{n}" } }
        inside = false
        source.each_line do |raw|
          code = raw.strip
          next if code.start_with?("#")

          if heads.any? { |head| word_prefix?(code, head) }
            inside = true
          elsif inside && code == "end"
            inside = false
          elsif inside && code.start_with?("t.")
            space = code.index(" ")
            first = space.nil? ? "" : code[space + 1, code.size - space - 1].to_s.strip
            return true if names.any? { |name| word_prefix?(first, name) }
          elsif adds.any? { |add| word_prefix?(code, add) }
            return true
          end
        end
        false
      end

      # Whether text starts with prefix and the name there ends with it: the
      # next character, if any, is not a letter, a digit or `_`.
      def self.word_prefix?(text, prefix)
        return false unless text.start_with?(prefix)
        return true if text.size == prefix.size

        b = text.getbyte(prefix.bytesize).to_i
        !((b >= 97 && b <= 122) || (b >= 65 && b <= 90) || (b >= 48 && b <= 57) || b == 95)
      end

      # Whether source holds 0.4's authentication block (its first line)
      # and no include: what generate_with_result upgrades rather than
      # inserts into.
      def self.legacy_application_controller?(source)
        !source.index(LEGACY_BLOCK_START).nil? && !Authentication.included?(source)
      end

      # 0.4's ApplicationController with its authentication block (from
      # LEGACY_BLOCK_START to LEGACY_BLOCK_END and the blank line after it)
      # replaced by `include Authentication`. With `force` and the block as
      # 0.4 wrote it (LEGACY_APPLICATION_CONTROLLER_BLOCKS), the file is
      # changed; otherwise the change goes into result.manual. A block
      # whose end line is gone is left alone with a note.
      def self.upgrade_application_controller(result, path, force)
        name = "app/controllers/application_controller.rb"
        source = File.read(path)
        start = source.index(LEGACY_BLOCK_START).to_i
        unless source.index(LEGACY_BLOCK_START, start + LEGACY_BLOCK_START.size).nil?
          puts "skip #{name} (0.4's authentication block is there more than once): " \
               "replace each with one `#{INCLUDE_LINE}` (app/controllers/concerns/authentication.rb)"
          return nil
        end
        last = source.index(LEGACY_BLOCK_END, start)
        if last.nil?
          puts "skip #{name} (0.4's authentication block has no end line): " \
               "replace that code with `#{INCLUDE_LINE}` (app/controllers/concerns/authentication.rb)"
          return nil
        end

        stop = last + LEGACY_BLOCK_END.size
        stop += 1 if source[stop, 1] == "\n"
        block = source[start, stop - start].to_s
        updated = +""
        updated << source[0, start].to_s << "  #{INCLUDE_LINE}\n\n" << source[stop, source.size - stop].to_s
        exact = LEGACY_APPLICATION_CONTROLLER_BLOCKS.any? { |legacy| indent(legacy) == block }
        warn_own_require_admin(updated)
        if force && exact
          File.write(path, updated)
          puts "force  #{name} (0.4's authentication block replaced by #{INCLUDE_LINE})"
          result.forced << name
          return nil
        end

        note = exact ? MANUAL_NOTE : "apply this diff by hand (0.4's authentication block was edited, so --force leaves it alone)"
        puts "manual  #{name} (diff below)"
        result.manual << manual_change(name, source, updated, note)
        nil
      end

      # The jobs page of an application 0.4 generated (jobs_page_plan,
      # which adds the line where 0.4's `cybertrain new` wrote no comment
      # of it): drawn once ApplicationController includes the concern,
      # else its diff into result.manual, to apply with
      # application_controller.rb's.
      def self.upgrade_jobs_page(result, routes_path, controller_path)
        source = File.read(routes_path)
        plan = jobs_page_plan(source, true, jobs_page_line(File.read(controller_path)))
        updated = plan[0]
        if updated.empty?
          report_jobs_page_skip(plan[1])
          return nil
        end

        if Authentication.included?(File.read(controller_path))
          File.write(routes_path, updated)
          puts "route #{jobs_page_line(File.read(controller_path))}"
          return nil
        end

        puts "manual  config/routes.rb (diff below)"
        result.manual << manual_change("config/routes.rb", source, updated,
                                       "apply this diff by hand with application_controller.rb's (require_admin comes with #{INCLUDE_LINE})")
        nil
      end

      # The jobs page's line for this ApplicationController source:
      # JOBS_PAGE_LINE, which skips require_authentication so that a visitor
      # gets the concern's require_admin's 404; NEW_APP_JOBS_PAGE_LINE (no
      # skip) when the controller defines its own require_admin, which may
      # count on require_authentication having run.
      def self.jobs_page_line(controller_source)
        Authentication.own_require_admin?(controller_source) ? NEW_APP_JOBS_PAGE_LINE : JOBS_PAGE_LINE
      end

      # What to do with the jobs page's route, as [routes, reason]: routes
      # is source with the jobs page drawn as `line` (JOBS_PAGE_LINE unless
      # given) in place of the comment `cybertrain new` writes (or
      # JOBS_PAGE_LINE commented out), or, with `add_missing` and no
      # `jobs_page` anywhere in source, as the last line of the
      # Cybertrain::Routes.draw block (before the `end` at the draw line's
      # own indentation). When there is nothing to do, routes is "" and
      # reason says why: "drawn" (JOBS_PAGE_LINE is there), "drawn " and the
      # line (`line`, or a jobs_page line of the application's own that
      # already skips require_authentication), JOBS_PAGE_OWN_LINE (one of
      # its own without the skip), or the words report_jobs_page_skip prints.
      def self.jobs_page_plan(source, add_missing, line = JOBS_PAGE_LINE)
        comments = ["# #{NEW_APP_JOBS_PAGE_LINE}", "# #{JOBS_PAGE_LINE}"]
        updated = +""
        found = false
        drawn = false
        drawn_line = ""
        own = false
        source.each_line do |text|
          code = text.strip
          drawn = true if code == JOBS_PAGE_LINE
          if !code.start_with?("#") && !code.index("jobs_page ").nil?
            own = true
            # The line to draw (without the skip), or one of the application's
            # own that already skips require_authentication: nothing to do.
            drawn_line = code if code == line || !code.index("skip_before_action: :require_authentication").nil?
          end
          if !found && comments.include?(code)
            found = true
            updated << text[0, text.index(code).to_i].to_s << line << "\n"
          else
            updated << text
          end
        end
        return [updated.to_s, ""] if found
        return ["", "drawn"] if drawn
        return ["", "drawn #{drawn_line}"] unless drawn_line.empty?
        return ["", JOBS_PAGE_OWN_LINE] if own
        return ["", "it has a jobs_page line of its own"] unless source.index("jobs_page").nil?
        return ["", "no `# #{NEW_APP_JOBS_PAGE_LINE}` comment to draw"] unless add_missing

        draw = source.index(Scaffold::DRAW_LINE).to_i
        start = line_start_before(source, draw)
        pad = source[start, draw - start].to_s
        return ["", "its draw line is not at the start of a line"] unless pad.strip.empty?

        at = source.index("\n#{pad}end\n", draw)
        at = source.index("\n#{pad}end", draw) if at.nil? && source.end_with?("\n#{pad}end")
        return ["", "no `end` of the Cybertrain::Routes.draw block at its indentation"] if at.nil?

        out = +""
        out << source[0, at + 1].to_s << "#{pad}  #{line}\n" << source[at + 1, source.size - at - 1].to_s
        [out.to_s, ""]
      end

      # Says why config/routes.rb gets no jobs page line (jobs_page_plan's
      # reason).
      def self.report_jobs_page_skip(reason)
        if reason == "drawn"
          puts "identical config/routes.rb (#{JOBS_PAGE_LINE})"
        elsif reason.start_with?("drawn ")
          puts "identical config/routes.rb (#{reason[6, reason.size - 6]})"
        elsif reason == JOBS_PAGE_OWN_LINE
          puts "skip config/routes.rb (#{reason}): add `skip_before_action: :require_authentication` to that line " \
               "so that a visitor gets require_admin's 404"
        else
          puts "skip config/routes.rb (#{reason}): to show the jobs page to admins, add " \
               "`#{JOBS_PAGE_LINE}` inside Cybertrain::Routes.draw"
        end
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
        warn_own_require_admin(source)
        true
      end

      # Whether source (an ApplicationController) defines require_admin
      # itself, which then takes the place of the concern's in every
      # controller.
      def self.own_require_admin?(source)
        source.each_line do |line|
          code = line.strip
          return true if code == "def require_admin" || code.start_with?("def require_admin ") || code.start_with?("def require_admin(")
        end
        false
      end

      # Says so when ApplicationController defines its own require_admin.
      def self.warn_own_require_admin(source)
        return nil unless Authentication.own_require_admin?(source)

        puts "warn  app/controllers/application_controller.rb defines require_admin itself: it takes the place of " \
             "the Authentication concern's in every controller (delete it to use the concern's)"
        nil
      end

      # Draws the jobs page `cybertrain new` left as a comment (a line that
      # is `# jobs_page "/admin/jobs", before_action: :require_admin`, or
      # already JOBS_PAGE_LINE commented out) as JOBS_PAGE_LINE, once
      # ApplicationController includes the concern that defines
      # require_admin. Any other routes file is left as it is. Returns true
      # when the file was changed.
      def self.enable_jobs_page(routes_path, controller_path)
        line = jobs_page_line(File.read(controller_path))
        plan = jobs_page_plan(File.read(routes_path), false, line)
        updated = plan[0]
        if updated.empty?
          report_jobs_page_skip(plan[1])
          return false
        end

        unless Authentication.included?(File.read(controller_path))
          puts "skip config/routes.rb (the jobs page): ApplicationController has no require_admin until it includes Authentication"
          return false
        end

        File.write(routes_path, updated)
        puts "route #{line}"
        true
      end

      # Inserts the sign-in, password reset, (--confirmable) confirmation,
      # account and sign-up (or setup) routes after the draw line, once.
      # Routes that have the sign-in but not the reset, the confirmations or
      # the account page (an app generated before them) get the reset's
      # line right after the sign-in's, and the account's and then the
      # confirmations' right after the reset's, each indented as the line
      # before it is.
      def self.add_routes(path, invite_only = false, confirmable = false)
        source = File.read(path)
        confirmations = confirmable ? "#{CONFIRMATIONS_ROUTE_MARK}, " : ""
        if source.index(ROUTE_MARK).nil?
          File.write(path, insert_after_line(source, Scaffold::DRAW_LINE, indent(routes_block(invite_only, confirmable))))
          puts "route #{ROUTE_MARK}, #{PASSWORDS_ROUTE_MARK}, #{confirmations}#{ACCOUNT_ROUTE_MARK}, get/post #{invite_only ? "/setup" : "/sign_up"}"
          return true
        end
        added = Array.new(0) { "" }
        if source.index(PASSWORDS_ROUTE_MARK).nil?
          source = insert_route_after(source, ROUTE_MARK, PASSWORDS_ROUTE)
          added << PASSWORDS_ROUTE_MARK
        end
        if source.index(ACCOUNT_ROUTE_MARK).nil?
          source = insert_route_after(source, PASSWORDS_ROUTE_MARK, ACCOUNT_ROUTE)
          added << ACCOUNT_ROUTE_MARK
        end
        if confirmable && source.index(CONFIRMATIONS_ROUTE_MARK).nil?
          source = insert_route_after(source, PASSWORDS_ROUTE_MARK, CONFIRMATIONS_ROUTE)
          added << CONFIRMATIONS_ROUTE_MARK
        end
        if confirmable && source.index(PENDING_EMAIL_ROUTE_MARK).nil?
          source = insert_route_after(source, ACCOUNT_ROUTE_MARK, PENDING_EMAIL_ROUTE)
          added << "delete #{PENDING_EMAIL_ROUTE_MARK}"
        end
        if added.empty?
          puts "identical route #{ROUTE_MARK}, #{PASSWORDS_ROUTE_MARK}, #{confirmations}#{ACCOUNT_ROUTE_MARK}"
          return false
        end

        File.write(path, source)
        puts "route #{added.join(", ")}"
        true
      end

      # source with route on a line of its own right after the first line
      # that holds mark, indented as that line is.
      def self.insert_route_after(source, mark, route)
        at = source.index(mark).to_i
        start = line_start_before(source, at)
        margin = source[start, at - start].to_s
        insert_after_line(source, mark, "#{margin}#{route}\n")
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

      # `text` with `spaces` spaces before every non-blank line: a chunk
      # written flush, moved to where splice puts it (inside a method's
      # `if`, say).
      def self.margin(text, spaces)
        pad = " " * spaces
        out = +""
        text.each_line { |line| out << (line == "\n" ? line : "#{pad}#{line}") }
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

      # `text` with the whole line that holds `mark` (a placeholder line in
      # one of the templates below, wherever it is indented) replaced by
      # `chunk`: lines of their own, each ending in a newline and indented
      # as the file needs, or "" to drop the line. What --confirmable adds
      # to a file the other modes write too goes in this way.
      def self.splice(text, mark, chunk)
        at = text.index(mark)
        raise InvalidArgument, "no `#{mark}` in the template" if at.nil?

        start = line_start_before(text, at)
        stop = text.index("\n", at)
        stop = stop.nil? ? text.size : stop + 1
        out = +""
        out << text[0, start].to_s << chunk << text[stop, text.size - stop].to_s
        out
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

      # With `confirmable`, the two columns --confirmable reads: when the
      # address was confirmed (nil: not yet), and a new address waiting for
      # its own confirmation (nil: none).
      def self.users_migration(confirmable = false)
        text = <<~RUBY
          class CreateUsers < Cybertrain::Migration::Base
            def change
              create_table "users" do |t|
                t.string "email_address", null: false
                t.string "password_digest", null: false
                t.boolean "admin", null: false, default: "false"
                t.integer "failed_attempts", null: false, default: "0"
                t.datetime "locked_until"
                @CONFIRMABLE_COLUMNS@
                t.timestamps
              end
              add_index "users", ["email_address"], unique: true
            end
          end
        RUBY
        columns = confirmable ? "      t.datetime \"confirmed_at\"\n      t.string \"unconfirmed_email\"\n" : ""
        splice(text, "@CONFIRMABLE_COLUMNS@", columns)
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

      # With `confirmable`, what --confirmable adds: confirmed?, the
      # confirmation token and confirm, and the check of a new address
      # waiting for its confirmation.
      def self.user_model(app, confirmable = false)
        text = <<~RUBY
          # Columns (email_address, password_digest, admin, failed_attempts,
          # locked_until@CONFIRMABLE_COLUMN_NAMES@), the Cybertrain::Model superclass and `sessions` (from
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
            @CONFIRMATION_TOKEN_TTL@

            validates :email_address, presence: true

            # Normalizes the address, refuses one that is not a single address
            # or is taken, and checks the password on a new record or whenever
            # one was given. Errors added here make the record invalid
            # (Cybertrain::Model.before_validation).
            before_validation do |user|
              user.email_address = User.normalize_email_address(user.email_address)
              user.validate_email_address_format
              user.validate_email_address_taken
              user.validate_password
              @VALIDATE_UNCONFIRMED_EMAIL@
            end

            # The address lowercased and trimmed: "  Ann@Example.COM " is
            # "ann@example.com", so a visitor signs in however they type it.
            def self.normalize_email_address(value)
              value.to_s.strip.downcase
            end

            # Whether value is one address: exactly one @, with text before and
            # after it, and no comma, whitespace, angle bracket or control
            # character. Cybertrain::Mailer reads "a@x.example,b@y.example" as two
            # recipients, so without this an account could hold two mailboxes and
            # have its mails (a confirmation link among them) sent to both. It
            # must also be an address the mailer sends to
            # (Cybertrain::Mailer.address_problem: plain ASCII, none of
            # ( ) [ ] ; : \\ or ", within its length limits), so no account is
            # saved that could never be mailed. Some addresses the mail
            # standards allow (a quoted local part with a space or a comma in
            # it) are refused too.
            def self.email_address_format?(value)
              s = value.to_s
              n = s.bytesize
              at = -1
              i = 0
              while i < n
                b = s.getbyte(i)
                return false if b <= 32 || b == 127 || b == 44 || b == 60 || b == 62
                if b == 64
                  return false if at >= 0

                  at = i
                end
                i += 1
              end
              at > 0 && at < n - 1 && Cybertrain::Mailer.address_problem(s).empty?
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
            # that user's password and address now (password_reset_binding); nil for
            # any other token (a wrong, expired or spent one, or one made for another
            # user).
            def self.find_by_password_reset_token(token)
              text = token.to_s
              user = User.find_by(id: Cybertrain::Token.id_from(text))
              return nil if user.nil?
              return nil unless Cybertrain::Token.valid?(text, "password_reset", user.password_reset_binding)

              user
            end
            @FIND_BY_CONFIRMATION_TOKEN@

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
            # concern's require_admin): `./@APP@ user admin EMAIL` sets it.
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
            # so do `./@APP@ user EMAIL PASSWORD` and a password reset
            # (PasswordsController#update). Writes only when there is something
            # to clear.
            def clear_failed_attempts!
              return nil if failed_attempts == 0 && locked_until.nil?

              update_columns(failed_attempts: 0, locked_until: nil)
              nil
            end

            # The token of a password reset link (PasswordsController): signed,
            # valid for 15 minutes from now, and bound to password_reset_binding,
            # so it stops working once the password or the address changes
            # (Cybertrain::Token).
            def password_reset_token(now = Time.now.to_i)
              Cybertrain::Token.issue("password_reset", id, 15 * 60, password_reset_binding, now)
            end

            # What a password reset token is bound to: the password and the address,
            # so a new password or a new address ends every link sent before (the
            # old address's mailbox keeps no way into the account).
            def password_reset_binding
              digest = password_digest.to_s
              address = email_address.to_s
              "\#{digest}:\#{address}"
            end
            @CONFIRMATION_METHODS@

            # Public so the before_validation block above (which receives the
            # record, not an implicit self) can call them. Their messages come
            # from the dictionary of the current locale, as a validator's do.

            # An address saved before this check existed is left as it is, so
            # that account can still be reset and signed in to; a new or changed
            # one must be a single address (User.email_address_format?).
            def validate_email_address_format
              address = email_address.to_s
              return nil if address.empty? || User.email_address_format?(address)
              return nil if persisted? && User.where(id: id, email_address: address).exists?

              errors.add(:email_address, I18n.error_message("user", :email_address, :invalid))
              nil
            end

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
            @VALIDATE_UNCONFIRMED_EMAIL_METHOD@
          end
        RUBY
        text = text.gsub("@APP@", app)
        text = text.sub("@CONFIRMABLE_COLUMN_NAMES@", confirmable ? ", confirmed_at,\n# unconfirmed_email" : "")
        text = splice(text, "@CONFIRMATION_TOKEN_TTL@", confirmable ? confirmation_token_ttl_lines : "")
        text = splice(text, "@VALIDATE_UNCONFIRMED_EMAIL@", confirmable ? "    user.validate_unconfirmed_email\n" : "")
        text = splice(text, "@FIND_BY_CONFIRMATION_TOKEN@", confirmable ? find_by_confirmation_token_method : "")
        text = splice(text, "@CONFIRMATION_METHODS@", confirmable ? confirmation_methods : "")
        splice(text, "@VALIDATE_UNCONFIRMED_EMAIL_METHOD@", confirmable ? validate_unconfirmed_email_method : "")
      end

      # --confirmable's pieces of app/models/user.rb (user_model).
      def self.confirmation_token_ttl_lines
        indent(<<~'RUBY')
          # How long a confirmation link works: three days (--confirmable).
          CONFIRMATION_TOKEN_TTL = 3 * 24 * 3600
        RUBY
      end

      def self.find_by_confirmation_token_method
        indent(<<~'RUBY')

          # The user a confirmation_token was made for, while it still confirms
          # what it was made to (confirmation_binding); nil for any other token (a
          # wrong, expired or used one, or one made for another user).
          def self.find_by_confirmation_token(token)
            text = token.to_s
            user = User.find_by(id: Cybertrain::Token.id_from(text))
            return nil if user.nil?
            return nil unless Cybertrain::Token.valid?(text, "confirmation", user.confirmation_binding)

            user
          end
        RUBY
      end

      def self.confirmation_methods
        indent(<<~'RUBY')

          # Whether the address has been confirmed (--confirmable): until it is,
          # SessionsController#create answers the right password with the
          # message that asks for the confirmation, and signs nobody in.
          def confirmed? = !confirmed_at.nil?

          # The token of a confirmation link (ConfirmationsController#show):
          # signed, valid for CONFIRMATION_TOKEN_TTL from now, and bound to
          # confirmation_binding, so it confirms the address it was mailed to and
          # works once.
          def confirmation_token(now = Time.now.to_i)
            Cybertrain::Token.issue("confirmation", id, CONFIRMATION_TOKEN_TTL, confirmation_binding, now)
          end

          # What a confirmation token is bound to: the address being confirmed
          # (unconfirmed_email when a new one waits, else email_address), the
          # address in use, and when an address was last confirmed (0: never).
          # Confirming changes it (confirmed_at, and a new address moves into
          # email_address), so a used link confirms nothing more; asking for
          # another new address ends the link to the one before.
          def confirmation_binding
            pending = unconfirmed_email.to_s
            address = email_address.to_s
            at = confirmed_at
            stamp = at.nil? ? 0 : at.to_i
            "#{pending}:#{address}:#{stamp}"
          end

          # Confirms what confirmation_binding names: a new account's address, or
          # the new address waiting, which takes the place of the old one. False,
          # with the reason in errors, when another account has taken that address
          # since it was asked for (validate_email_address_taken asks again here,
          # and the unique index behind it): then only the address waiting is
          # forgotten, as it can never be confirmed now.
          def confirm
            pending = unconfirmed_email.to_s
            self.email_address = pending unless pending.empty?
            self.unconfirmed_email = nil
            self.confirmed_at = Time.now
            return true if save_confirmed

            update_columns(unconfirmed_email: nil) unless pending.empty?
            false
          end

          # confirm's save. Another account that takes the address between the
          # check and the write meets the unique index: the same answer as the
          # check's, not an error page.
          def save_confirmed
            save
          rescue Cybertrain::DB::Error => e
            raise e unless e.message.include?("UNIQUE")

            errors.add(:email_address, I18n.error_message("user", :email_address, :taken))
            false
          end

          # Asks for a new address (AccountsController#update): it waits in
          # unconfirmed_email for the link mailed to it, and is checked
          # (validate_unconfirmed_email) by this save only, so an address someone
          # takes later never stops a reset, the user command or a rehash from
          # saving the account.
          def request_email_change(address)
            requested = User.normalize_email_address(address)
            @requested_email = requested
            self.unconfirmed_email = requested
            nil
          end
        RUBY
      end

      def self.validate_unconfirmed_email_method
        indent(<<~'RUBY')

          # The new address request_email_change asked for (--confirmable),
          # refused when blank, not a single address (User.email_address_format?)
          # or another account's address, on email_address (the field the form
          # shows). Any other save skips it.
          def validate_unconfirmed_email
            requested = @requested_email
            return nil if requested.nil?

            if requested.empty?
              errors.add(:email_address, I18n.error_message("user", :email_address, :blank))
            elsif !User.email_address_format?(requested)
              errors.add(:email_address, I18n.error_message("user", :email_address, :invalid))
            elsif User.where(email_address: requested).where_sql("id != ?", [id]).exists?
              errors.add(:email_address, I18n.error_message("user", :email_address, :taken))
            end
            nil
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
      # point: the reset's, and --confirmable's), plus with `confirmable`
      # send_confirmation_mail, which the controllers that mail a
      # confirmation share.
      def self.authentication_concern(app, confirmable = false)
        env = base_url_env(app)
        text = <<~RUBY
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
              @CONFIRMED_ONLY@
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

              Cybertrain.logger.error("\#{mail} mail not sent: set #{env} (or CYBERTRAIN_HOSTS)")
              ""
            end
            @SEND_CONFIRMATION_MAIL@
          end
        RUBY
        text = splice(text, "@CONFIRMED_ONLY@", confirmable ? confirmed_only_lines : "")
        splice(text, "@SEND_CONFIRMATION_MAIL@", confirmable ? send_confirmation_mail_method : "")
      end

      # --confirmable's first lines of the concern's start_new_session_for:
      # no session for an account whose address is not confirmed, whichever
      # action asks. SessionsController#create refuses such an account
      # first, with its own message; this holds where that check is
      # missing too (a sessions controller an upgrade's diff never reached).
      def self.confirmed_only_lines
        margin(<<~'RUBY', 4)
          # --confirmable: an account whose address is not confirmed gets no
          # session, whichever action asks (SessionsController#create says
          # why first; this holds where that check is missing too).
          unless user.confirmed?
            Cybertrain.logger.warn("no session started: user #{user.id} has not confirmed its address")
            return nil
          end

        RUBY
      end

      # --confirmable's private method of the concern: sign-up, the account
      # page and the send-again form all mail a confirmation this way.
      def self.send_confirmation_mail_method
        indent(<<~'RUBY')

          # The confirmation mail (ConfirmationsMailer, --confirmable) to the
          # address user is confirming, with the link to
          # ConfirmationsController#show for token, from mail_link_base. Queued
          # only when deliver is true: the send-again form builds the mail for an
          # address that gets none as well, so that its answer takes the same
          # work. An address the mailer refuses is logged (the message never
          # repeats the address), and the caller answers as it would have.
          def send_confirmation_mail(user, token, deliver)
            base = mail_link_base("confirmation")
            return nil if base.empty?

            path = confirmation_path(token)
            mail = ConfirmationsMailer.confirmation_instructions(user, base + path)
            mail.deliver_later if deliver
            nil
          rescue ArgumentError => e
            Cybertrain.logger.error("confirmation mail not sent: #{e.message}")
            nil
          end
        RUBY
      end

      # With `confirmable`, the right password and an address not confirmed
      # yet get their own message, and no session.
      def self.sessions_controller(confirmable = false)
        text = <<~RUBY
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
              @UNCONFIRMED@
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
        splice(text, "@UNCONFIRMED@", confirmable ? sessions_unconfirmed_branch : "")
      end

      # --confirmable's branch of SessionsController#create.
      def self.sessions_unconfirmed_branch
        margin(<<~'RUBY', 4)
              elsif !user.confirmed?
                # Said only once the password is right, so that it tells nobody
                # without the password that the address is registered. The
                # sign-in page links to the form that mails the link again.
                flash[:alert] = t(".unconfirmed")
                redirect_to new_session_path, status: :see_other
        RUBY
      end

      # With `confirmable`, a sign-up mails the confirmation link and signs
      # nobody in.
      def self.registrations_controller(confirmable = false)
        text = <<~RUBY
          # Sign up (cybertrain generate authentication). Rails' generator has no
          # sign-up page and expects the first user to be created in the console;
          # cybertrain has no console, so this is how the first user gets in.
          # Delete it (and its routes) for an invitation-only application.
          class RegistrationsController < ApplicationController
            allow_unauthenticated_access only: [:new, :create]
            # Ten sign-ups per client address every three minutes, as for signing
            # in: each one hashes a password and may mail a link, and each
            # "already been taken" says an address is registered.
            rate_limit to: 10, within: 3 * 60, only: [:create], with: :rate_limited

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
                @SIGNED_UP@
              else
                render :new, status: :unprocessable_entity
              end
            end

            private

            # What a client past the rate limit gets: the form again, with a
            # message (the key is create's).
            def rate_limited
              flash[:alert] = t("registrations.create.rate_limited")
              redirect_to sign_up_path, status: :see_other
              nil
            end
          end
        RUBY
        splice(text, "@SIGNED_UP@", confirmable ? registrations_confirm_lines : registrations_sign_in_lines)
      end

      def self.registrations_sign_in_lines
        margin(<<~'RUBY', 6)
                start_new_session_for(@user)
                flash[:notice] = t(".welcome")
                redirect_to after_authentication_url, status: :see_other
        RUBY
      end

      # --confirmable: the link by mail, and the sign-in page.
      def self.registrations_confirm_lines
        margin(<<~'RUBY', 6)
                # Signed in only once the address is confirmed (the mail's link),
                # and then with the password.
                token = @user.confirmation_token
                send_confirmation_mail(@user, token, true)
                flash[:notice] = t(".confirm")
                redirect_to new_session_path, status: :see_other
        RUBY
      end

      # With --invite-only there is no sign-up page to link to; with
      # `confirmable`, a link to the form that mails the confirmation again.
      def self.sessions_new_view(invite_only = false, confirmable = false)
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
        view = "#{view}<p><%= link_to t(\".confirmation\"), new_confirmation_path %></p>\n" if confirmable
        return view if invite_only

        "#{view}<p><%= link_to t(\".sign_up\"), sign_up_path %></p>\n"
      end

      def self.nav_partial
        <<~ERB
          <%# locals: () %>
          <nav class="session">
            <% if @current_user %>
              <span><%= @current_user.email_address %></span>
              <%= link_to t(".account"), edit_account_path %>
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
      # With `confirmable` a reset also confirms the address it was mailed to.
      def self.passwords_controller(confirmable = false)
        text = <<~'RUBY'
          # Password reset (cybertrain generate authentication): the form that asks
          # for an address, the mail with a link (PasswordsMailer.reset), and the
          # form behind the link that sets a new password. The link's token
          # (User#password_reset_token) is signed, lasts 15 minutes and is bound to
          # the password and the address, so it stops working once either changes,
          # and every link sent before with it. The address form answers the same
          # whether or not the address is registered.
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
                @WITHDRAW_ON_RESET@
                if user.save
                  user.clear_failed_attempts!
                  @CONFIRM_ON_RESET@
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
              Cybertrain.logger.error("password reset mail not sent: #{e.message}")
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
        chunk = margin("# The link went to email_address: a reset proves that mailbox, as a\n" \
                       "# confirmation link does (--confirmable). A new address waiting\n" \
                       "# (unconfirmed_email) is not confirmed: that takes its own link.\n" \
                       "user.update_columns(confirmed_at: Time.now) unless user.confirmed?\n", 8)
        withdraw = margin("# A new address waiting (unconfirmed_email) is withdrawn, and with it\n" \
                          "# its link (the token is bound to it): whoever asked for it may be\n" \
                          "# the one the owner is taking the account back from.\n" \
                          "user.unconfirmed_email = nil\n", 6)
        text = splice(text, "@WITHDRAW_ON_RESET@", confirmable ? withdraw : "")
        splice(text, "@CONFIRM_ON_RESET@", confirmable ? chunk : "")
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

      # ---- --confirmable --------------------------------------------------

      # app/controllers/confirmations_controller.rb: the mail's link, and the
      # form that sends it again (the same answer for any address, after
      # the same work, as the password reset's address form).
      def self.confirmations_controller
        <<~'RUBY'
          # Confirming an email address (cybertrain generate authentication
          # --confirmable): the link a confirmation mail carries
          # (ConfirmationsMailer), which confirms a new account's address or puts
          # a new address in the old one's place, and the form that mails the link
          # again. The link's token (User#confirmation_token) is signed, lasts
          # three days (User::CONFIRMATION_TOKEN_TTL) and works once. Opening the
          # link signs nobody in: the user then signs in with the password. The
          # form answers the same whether or not the address is registered, or
          # confirmed already.
          #
          # Written by the generator; it is yours to change.
          class ConfirmationsController < ApplicationController
            allow_unauthenticated_access
            # Ten requests per client address every three minutes, as for signing in.
            rate_limit to: 10, within: 3 * 60, only: [:create], with: :rate_limited
            # The link's page carries the token in its address: no Referer for it.
            before_action :no_referrer, only: [:show]

            # GET /confirmations/new
            def new_action
            end

            # POST /confirmations
            # A new link for an account whose address is not confirmed yet. Any
            # other address (no account's, or one confirmed already) gets the same
            # answer after the same work (a token, the mail rendered), short of
            # queueing the mail.
            def create
              address = User.normalize_email_address(params[:email_address].to_s)
              user = User.find_by(email_address: address)
              if user.nil? || user.confirmed?
                token = Cybertrain::Token.issue("confirmation", 1, User::CONFIRMATION_TOKEN_TTL, address)
                send_confirmation_mail(User.new(email_address: address), token, false)
              else
                token = user.confirmation_token
                send_confirmation_mail(user, token, true)
              end
              flash[:notice] = t(".sent")
              redirect_to new_session_path, status: :see_other
            end

            # GET /confirmations/:token
            # Confirms the address (User#confirm), unless another account has
            # taken it since; signs nobody in.
            def show
              user = User.find_by_confirmation_token(params[:token].to_s)
              if user.nil?
                invalid_link
              elsif user.confirm
                flash[:notice] = t(".confirmed")
                redirect_to after_confirmation_path, status: :see_other
              else
                flash[:alert] = t(".taken")
                redirect_to after_confirmation_path, status: :see_other
              end
            end

            private

            # A browser signed in already (a new address, confirmed from the
            # account page's browser) goes back to the account page; any other to
            # the sign-in page.
            def after_confirmation_path
              authenticated? ? edit_account_path : new_session_path
            end

            # Browsers send no Referer from the link's page, whose address holds
            # the token.
            def no_referrer
              response.set_header("Referrer-Policy", "no-referrer")
              nil
            end

            # A token that is wrong, expired or used: to the form that mails a new
            # link. Not an action, so its key is written in full (show's).
            def invalid_link
              flash[:alert] = t("confirmations.show.invalid")
              redirect_to new_confirmation_path, status: :see_other
              nil
            end

            # What a client past the rate limit gets (the key is create's).
            def rate_limited
              flash[:alert] = t("confirmations.create.rate_limited")
              redirect_to new_confirmation_path, status: :see_other
              nil
            end
          end
        RUBY
      end

      # app/mailers/confirmations_mailer.rb: as PasswordsMailer, the link
      # given (the concern's send_confirmation_mail builds it).
      def self.confirmations_mailer
        <<~'RUBY'
          # The confirmation mail (cybertrain generate authentication --confirmable):
          # its HTML is app/views/mail/_confirmation.html.erb, its subject and text
          # come from the dictionary (confirmations_mailer.confirmation_instructions.subject,
          # mail.confirmation.*), in the locale of the request that asked for it.
          #
          # Written by the generator; it is yours to change.
          module ConfirmationsMailer
            # The mail with url, the link that confirms user's address: the new one
            # waiting (unconfirmed_email) when there is one, else the account's own.
            # It goes to that address. Its sender is Config#smtp_from
            # (CYBERTRAIN_SMTP_FROM).
            def self.confirmation_instructions(user, url)
              pending = user.unconfirmed_email.to_s
              address = pending.empty? ? user.email_address.to_s : pending
              html = Cybertrain::Views.render_mail("mail/confirmation", address: address, url: url)
              greeting = I18n.t("mail.confirmation.greeting", { email_address: address })
              text = +""
              text << greeting << "\n\n"
              text << I18n.t("mail.confirmation.intro") << "\n" << url << "\n\n"
              text << I18n.t("mail.confirmation.ignore") << "\n"
              subject = I18n.t("confirmations_mailer.confirmation_instructions.subject")
              Cybertrain::MailMessage.new(to: address, subject: subject, body: text, html: html)
            end
          end
        RUBY
      end

      def self.confirmations_new_view
        <<~ERB
          <h1><%= t(".title") %></h1>

          <p><%= t(".intro") %></p>

          <%= form_with(url: confirmations_path) do |f| %>
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

      # The mail's HTML (Views.render_mail); its lazy keys are
      # mail.confirmation.* (D8).
      def self.confirmation_mail_view
        <<~ERB
          <%# locals: (address:, url:) %>
          <p><%= t(".greeting", email_address: address) %></p>
          <p><%= t(".intro") %></p>
          <p><%= link_to t(".link"), url %></p>
          <p><%= t(".ignore") %></p>
        ERB
      end

      # ---- the account page ---------------------------------------------

      # app/controllers/accounts_controller.rb: the signed-in user's own
      # page. Every change asks for the current password; a wrong one is
      # rate limited per client address as a sign-in is, and per user (it
      # does not count toward the lockout, which guards signing in). A new
      # password restarts this browser's session through
      # start_new_session_for with the row's own remember flag, so "keep me
      # signed in" survives it (pre-flight finding 9). With `confirmable` a
      # new address waits in unconfirmed_email for the link mailed to it.
      def self.accounts_controller(confirmable = false)
        text = <<~'RUBY'
          # The signed-in user's account (cybertrain generate authentication): a new
          # email address, a new password, or both, each only with the current
          # password; and the account deleted, also only with the password.
          #
          # Written by the generator; it is yours to change.
          class AccountsController < ApplicationController
            # Ten changes or deletions per client address every three minutes, as for
            # signing in, and ten per user whatever the address (account_key): a
            # current password is guessed here no faster than there, from one
            # address or from many.
            rate_limit to: 10, within: 3 * 60, only: [:update, :destroy], with: :rate_limited
            rate_limit to: 10, within: 3 * 60, only: [:update, :destroy], by: :account_key, name: "user", with: :rate_limited
            before_action :set_user

            # GET /account/edit
            def edit
            end

            # PATCH/PUT /account
            # The current password first, for any change.
            @ADDRESS_COMMENT@
            # A new password ends every other session of the user and starts this
            # browser's again (restart_sessions). A new password or address ends
            # every password reset link sent before (they are bound to both).
            def update
              fields = params.expect(user: [:current_password, :email_address, :password, :password_confirmation])
              digest = @user.password_digest
              if @user.authenticate(fields["current_password"].to_s)
                # What authenticate left saved: digest, or a new hash of the same
                # password when the cost was raised (User#authenticate).
                verified = @user.password_digest
                @ADDRESS@
                password = fields["password"].to_s
                unless password.empty?
                  @user.password = password
                  @user.password_confirmation = fields["password_confirmation"].to_s
                end
                if @user.save
                  restart_sessions if @user.password_digest != digest
                  @SAVED@
                  redirect_to edit_account_path, status: :see_other
                else
                  # A new hash saved by authenticate stays: this browser's key
                  # follows it, or the browser would be signed out next time.
                  session[:password_key] = Cybertrain::Password.session_key(verified) if verified != digest
                  render :edit, status: :unprocessable_entity
                end
              else
                flash.now[:alert] = t(".wrong_password")
                render :edit, status: :unprocessable_entity
              end
            end

            # DELETE /account
            # With the password: the user's sessions (every browser's) and the user
            # are deleted together, and this browser's cookie session is emptied.
            # When the database refuses (a row of another table still refers to
            # the user), nothing is deleted and the page says so.
            def destroy
              if @user.authenticate(params[:password].to_s)
                if delete_user_and_sessions
                  terminate_session
                  flash[:notice] = t(".deleted")
                  redirect_to "/", status: :see_other
                else
                  flash.now[:alert] = t(".not_deleted")
                  render :edit, status: :unprocessable_entity
                end
              else
                flash.now[:alert] = t(".wrong_password")
                render :edit, status: :unprocessable_entity
              end
            end
            @CANCEL_EMAIL_CHANGE@

            private

            # A copy of the signed-in user for the forms, so that a change that does
            # not pass leaves @current_user, which the nav shows, as it is.
            def set_user
              @user = User.find(@current_user.id)
              @PENDING@
            end

            # The second rate limit's key: the signed-in user's id
            # (require_authentication has run first).
            def account_key
              @current_user.id.to_s
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

            # The user's Session rows and the user, in one transaction: true once
            # both are gone. When the database refuses the delete (a foreign key
            # from another table: give that association a `dependent:`), both
            # stay, so this browser stays signed in, and the log says why.
            def delete_user_and_sessions
              user = @user
              User.transaction do |c|
                Session.where(user_id: user.id).delete_all
                user.destroy
              end
              true
            rescue Cybertrain::DB::Error => e
              Cybertrain.logger.error("account not deleted: #{e.message}")
              false
            end

            # What a client past the rate limit gets (the key is update's).
            def rate_limited
              flash[:alert] = t("accounts.update.rate_limited")
              redirect_to edit_account_path, status: :see_other
              nil
            end
          end
        RUBY
        if confirmable
          text = splice(text, "@ADDRESS_COMMENT@", "  # A new address waits for the link mailed to it, and takes the old\n" \
                                                   "  # one's place once that is opened (ConfirmationsController#show).\n")
          text = splice(text, "@ADDRESS@", accounts_pending_address_lines)
          text = splice(text, "@SAVED@", accounts_pending_address_saved_lines)
          text = splice(text, "@CANCEL_EMAIL_CHANGE@", accounts_cancel_email_change)
          return splice(text, "@PENDING@", "    # The new address waiting, as saved: the page shows it.\n" \
                                           "    @pending_email = @user.unconfirmed_email.to_s\n")
        end
        text = splice(text, "@ADDRESS_COMMENT@", "  # A new address takes effect at once.\n")
        text = splice(text, "@ADDRESS@", margin("@user.email_address = fields[\"email_address\"].to_s if fields.key?(\"email_address\")\n", 6))
        text = splice(text, "@SAVED@", margin("flash[:notice] = t(\".updated\")\n", 8))
        text = splice(text, "@CANCEL_EMAIL_CHANGE@", "")
        splice(text, "@PENDING@", "")
      end

      # --confirmable's action that withdraws the new address waiting.
      def self.accounts_cancel_email_change
        indent(<<~'RUBY')

          # DELETE /account/pending_email
          # Withdraws the new address waiting (a mistyped one, say): its link stops
          # working, as the token is bound to unconfirmed_email. No password is
          # asked: withdrawing only keeps the account where it is. A new password
          # on this page leaves the address waiting as it was; this and a
          # password reset (PasswordsController#update) end it.
          def cancel_email_change
            @user.update_columns(unconfirmed_email: nil)
            flash[:notice] = t(".cancelled")
            redirect_to edit_account_path, status: :see_other
          end
        RUBY
      end

      # --confirmable's AccountsController#update: a new address goes into
      # unconfirmed_email (the address in use is no change).
      def self.accounts_pending_address_lines
        margin(<<~'RUBY', 6)
          address_changed = false
          if fields.key?("email_address")
            address = User.normalize_email_address(fields["email_address"].to_s)
            # The address in use, sent back as the form fills it in, is no change:
            # a new address waiting stays.
            unless address == @user.email_address
              @user.request_email_change(address)
              address_changed = true
            end
          end
        RUBY
      end

      # ...and, once saved, the link to it by mail.
      def self.accounts_pending_address_saved_lines
        margin(<<~'RUBY', 8)
          if address_changed
            token = @user.confirmation_token
            send_confirmation_mail(@user, token, true)
            flash[:notice] = t(".confirm")
          else
            flash[:notice] = t(".updated")
          end
        RUBY
      end

      # Two forms: the details (address, new password, current password)
      # and the deletion (the password); with `confirmable`, the new address
      # waiting for its confirmation under the address field.
      def self.accounts_edit_view(confirmable = false)
        text = <<~ERB
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
              @PENDING_HINT@
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
          @CANCEL_PENDING_BUTTON@

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
        text = splice(text, "@PENDING_HINT@", confirmable ? accounts_pending_hint : "")
        button = "\n<% unless @pending_email.empty? %>\n" \
                 "  <p><%= button_to t(\".cancel_pending\"), account_pending_email_path, method: :delete %></p>\n<% end %>\n"
        splice(text, "@CANCEL_PENDING_BUTTON@", confirmable ? button : "")
      end

      def self.accounts_pending_hint
        margin(<<~'ERB', 4)
          <% unless @pending_email.empty? %>
            <p class="hint"><%= t(".pending", email_address: @pending_email) %></p>
          <% end %>
        ERB
      end

      # test/accounts.rb: the account page through the stack. The same tests
      # in every mode: with `confirmable` a new address takes effect once its
      # link is opened, which confirm_new_address does.
      def self.accounts_test(confirmable = false)
        text = <<~'RUBY'
          # The account page (cybertrain generate authentication): a new address or
          # password only with the current password, what a new password ends and
          # keeps, deleting the account, and the limits on guessing the password.
          # Run with `cybertrain spin test`; its snapshot comes from the compiled
          # binary (the database is FFI).
          require "stringio"
          require_relative "support/app_test"
          require_relative "support/authentication_helpers"

          WRONG_PASSWORD = "<p class=\"alert\">That is not your current password.</p>"
          UPDATED = "<p class=\"notice\">Your account has been updated.</p>"
          DELETED = "<p class=\"notice\">Your account has been deleted.</p>"
          NOT_DELETED = "<p class=\"alert\">Your account could not be deleted. Nothing has changed.</p>"
          NEW_PASSWORD = "n3w-s3cr3t-n3w"
          @ADDRESS_HELPERS@

          def new_client
            Session.all.delete_all
            User.all.delete_all
            Cybertrain::Test::Client.new(APP)
          end

          # Sends the account form as a browser would: the current password and the
          # fields given, each as user[name]. The rate limit's counts are forgotten
          # first, as AppTest.sign_in does.
          def update_account(client, current_password, fields)
            Cybertrain::RateLimit.reset_all!
            client.get("/account/edit")
            form = { "authenticity_token" => AppTest.form_token(client), "user[current_password]" => current_password }
            fields.each { |name, value| form["user[#{name}]"] = value }
            client.patch("/account", form)
          end

          # Sends the delete form with this password.
          def delete_account(client, password)
            Cybertrain::RateLimit.reset_all!
            client.get("/account/edit")
            client.delete("/account", { "authenticity_token" => AppTest.form_token(client), "password" => password })
          end

          # Whether client is signed in as email_address: the nav names them.
          def signed_in?(client, email_address = "ann@example.com")
            client.get("/session/new").body.include?("<span>#{email_address}</span>")
          end

          # The Set-Cookie line of the session cookie in res ("" when none).
          def session_cookie(res)
            prefix = "#{Cybertrain.config.session_cookie_name}="
            found = ""
            res.cookies.each { |line| found = line if line.start_with?(prefix) }
            found
          end

          # A table of the app's own whose rows refer to users (as a migration's
          # `t.references :user` makes one), with a row for user: the database
          # then refuses to delete that user.
          def add_note_for(user)
            Cybertrain::DB.with do |c|
              c.execute("CREATE TABLE account_notes (id INTEGER PRIMARY KEY, user_id INTEGER NOT NULL REFERENCES users (id))")
              c.execute("INSERT INTO account_notes (user_id) VALUES (#{user.id})")
            end
            nil
          end

          def drop_notes
            Cybertrain::DB.with { |c| c.execute("DROP TABLE IF EXISTS account_notes") }
            nil
          end

          test "changing email or password requires the current password" do
            client = new_client
            ann = AppTest.user
            AppTest.user("bob@example.com")
            AppTest.sign_in(client)
            digest = ann.password_digest
            reset_token = ann.password_reset_token
            # A wrong current password: nothing changes, and the page says why.
            res = update_account(client, "wrong-password", { "email_address" => "ann@new.example", "password" => NEW_PASSWORD, "password_confirmation" => NEW_PASSWORD })
            assert_response res, :unprocessable_entity
            assert_includes res.body, WRONG_PASSWORD
            same = User.find(ann.id)
            assert_equal "ann@example.com", same.email_address
            assert_equal digest, same.password_digest
            # None at all, for the address alone: the same.
            res = update_account(client, "", { "email_address" => "ann@new.example" })
            assert_response res, :unprocessable_entity
            assert_includes res.body, WRONG_PASSWORD
            assert_equal "ann@example.com", User.find(ann.id).email_address
            # A wrong password ends no session.
            assert signed_in?(client)
            assert_equal 1, Session.count
            session_id = Session.first.id
            # The right one: the new address (normalized), once it takes effect;
            # the password and the session stay as they were.
            res = update_account(client, "s3cr3t-s3cr3t", { "email_address" => " Ann@New.Example ", "password" => "", "password_confirmation" => "" })
            assert_redirected_to res, "/account/edit"
            assert_includes client.follow_redirect!.body, ADDRESS_CHANGED
            confirm_new_address(ann)
            assert_includes client.get("/account/edit").body, "<span>ann@new.example</span>"
            changed = User.find(ann.id)
            assert_equal "ann@new.example", changed.email_address
            assert_equal digest, changed.password_digest
            assert_equal 1, Session.count
            assert_equal session_id, Session.first.id
            # A password reset link sent to the old address no longer works.
            assert_nil User.find_by_password_reset_token(reset_token)
            # Signing in takes the new address, not the old one.
            other = Cybertrain::Test::Client.new(APP)
            assert_redirected_to AppTest.sign_in(other, "ann@example.com"), "/session/new"
            assert_redirected_to AppTest.sign_in(other, "ann@new.example"), "/"
            # A taken address does not pass: the errors, and the nav still shows
            # the address in use.
            res = update_account(client, "s3cr3t-s3cr3t", { "email_address" => "bob@example.com" })
            assert_response res, :unprocessable_entity
            assert_includes res.body, "<li>Email address has already been taken</li>"
            assert_includes res.body, "<span>ann@new.example</span>"
            assert_equal "ann@new.example", User.find(ann.id).email_address
            # Nor does an address list (two mailboxes for one account), and no
            # link is mailed for it.
            res = update_account(client, "s3cr3t-s3cr3t", { "email_address" => "ann@new.example,eve@evil.example" })
            assert_response res, :unprocessable_entity
            assert_includes res.body, "<li>Email address is invalid</li>"
            assert_equal "ann@new.example", User.find(ann.id).email_address
            # Nor an address the mailer would refuse (Cybertrain::Mailer.address_problem).
            ["ann@new.example\u00A0", "ann\u3000@new.example", "ann\u0085@new.example", "ann@new\u2028.example", "ann;x@new.example", "ann(x)@new.example"].each do |address|
              res = update_account(client, "s3cr3t-s3cr3t", { "email_address" => address })
              assert_response res, :unprocessable_entity
              assert_includes res.body, "<li>Email address is invalid</li>"
              assert_equal "ann@new.example", User.find(ann.id).email_address
            end
            # A new password that does not pass: nothing changes.
            res = update_account(client, "s3cr3t-s3cr3t", { "password" => "short", "password_confirmation" => "short" })
            assert_response res, :unprocessable_entity
            assert_includes res.body, "<li>Password is too short (minimum is 8 characters)</li>"
            res = update_account(client, "s3cr3t-s3cr3t", { "password" => NEW_PASSWORD, "password_confirmation" => "something-else" })
            assert_response res, :unprocessable_entity
            assert_includes res.body, "<li>Password confirmation doesn&#39;t match Password</li>"
            assert_equal digest, User.find(ann.id).password_digest
            # The right current password and a new one: only the new one signs in.
            res = update_account(client, "s3cr3t-s3cr3t", { "password" => NEW_PASSWORD, "password_confirmation" => NEW_PASSWORD })
            assert_redirected_to res, "/account/edit"
            refute User.find(ann.id).password_digest == digest
            assert_redirected_to AppTest.sign_in(other, "ann@new.example"), "/session/new"
            assert_redirected_to AppTest.sign_in(other, "ann@new.example", NEW_PASSWORD), "/"
          end

          test "a password change ends other sessions and keeps this one" do
            laptop = new_client
            ann = AppTest.user
            bob = AppTest.user("bob@example.com")
            # The laptop asked to stay signed in; the phone did not.
            Cybertrain::RateLimit.reset_all!
            laptop.get("/session/new")
            laptop.post("/session", { "authenticity_token" => AppTest.form_token(laptop), "email_address" => "ann@example.com",
                                      "password" => "s3cr3t-s3cr3t", "remember_me" => "1" })
            laptop_id = Session.first.id
            assert_equal true, Session.first.remember
            phone = Cybertrain::Test::Client.new(APP)
            AppTest.sign_in(phone)
            bobs = Cybertrain::Test::Client.new(APP)
            AppTest.sign_in(bobs, "bob@example.com")
            assert_equal 2, Session.where(user_id: ann.id).count
            token = ann.password_reset_token
            refute User.find_by_password_reset_token(token).nil?
            res = update_account(laptop, "s3cr3t-s3cr3t", { "password" => NEW_PASSWORD, "password_confirmation" => NEW_PASSWORD })
            assert_redirected_to res, "/account/edit"
            # This browser is signed in again at once, still remembered (the cookie
            # keeps its Max-Age), on a new Session row with the new password key.
            assert session_cookie(res).end_with?("; Max-Age=2592000"), session_cookie(res)
            assert_includes laptop.follow_redirect!.body, UPDATED
            rows = Session.where(user_id: ann.id).to_a
            assert_equal 1, rows.size
            refute rows[0].id == laptop_id
            assert_equal true, rows[0].remember
            assert signed_in?(laptop)
            refute signed_in?(phone)
            assert signed_in?(bobs, "bob@example.com")
            assert_equal 1, Session.where(user_id: bob.id).count
            # A reset link sent before no longer works.
            assert_nil User.find_by_password_reset_token(token)
            # A browser that did not ask to stay signed in still has not: no Max-Age.
            AppTest.sign_in(phone, "ann@example.com", NEW_PASSWORD)
            assert signed_in?(phone)
            res = update_account(phone, NEW_PASSWORD, { "password" => "th1rd-s3cr3t", "password_confirmation" => "th1rd-s3cr3t" })
            assert_redirected_to res, "/account/edit"
            refute session_cookie(res).empty?
            refute session_cookie(res).include?("Max-Age")
            rows = Session.where(user_id: ann.id).to_a
            assert_equal 1, rows.size
            assert_equal false, rows[0].remember
            assert signed_in?(phone)
            refute signed_in?(laptop)
            # A new address alone ends no session.
            AppTest.sign_in(laptop, "ann@example.com", "th1rd-s3cr3t")
            assert_equal 2, Session.where(user_id: ann.id).count
            res = update_account(phone, "th1rd-s3cr3t", { "email_address" => "ann@new.example" })
            assert_redirected_to res, "/account/edit"
            confirm_new_address(ann)
            assert_equal 2, Session.where(user_id: ann.id).count
            assert signed_in?(laptop, "ann@new.example")
            assert signed_in?(phone, "ann@new.example")
          end

          test "deleting the account requires the password and removes the user and sessions" do
            client = new_client
            ann = AppTest.user
            AppTest.user("bob@example.com")
            AppTest.sign_in(client)
            phone = Cybertrain::Test::Client.new(APP)
            AppTest.sign_in(phone)
            bobs = Cybertrain::Test::Client.new(APP)
            AppTest.sign_in(bobs, "bob@example.com")
            assert_equal 3, Session.count
            # A wrong password, or none: nothing is deleted.
            res = delete_account(client, "wrong-password")
            assert_response res, :unprocessable_entity
            assert_includes res.body, WRONG_PASSWORD
            res = delete_account(client, "")
            assert_response res, :unprocessable_entity
            assert_includes res.body, WRONG_PASSWORD
            refute User.find_by(id: ann.id).nil?
            assert_equal 3, Session.count
            assert signed_in?(client)
            # The right one: the user, every session of theirs, and this browser's
            # cookie session.
            res = delete_account(client, "s3cr3t-s3cr3t")
            assert_redirected_to res, "/"
            assert_includes client.get("/session/new").body, DELETED
            assert_nil User.find_by(id: ann.id)
            assert_equal 0, Session.where(user_id: ann.id).count
            assert_equal 1, Session.count
            assert_equal 1, User.all.count
            refute signed_in?(client)
            refute signed_in?(phone)
            assert signed_in?(bobs, "bob@example.com")
            # The address signs in no more.
            assert_redirected_to AppTest.sign_in(client), "/session/new"
            assert_redirected_to client.get("/account/edit"), "/session/new"
          end

          test "a visitor is sent to sign in" do
            client = new_client
            ann = AppTest.user
            assert_redirected_to client.get("/account/edit"), "/session/new"
            # The forms' requests too, with a valid token and the right password:
            # nothing changes.
            client.get("/session/new")
            token = AppTest.form_token(client)
            res = client.patch("/account", { "authenticity_token" => token, "user[current_password]" => "s3cr3t-s3cr3t",
                                             "user[email_address]" => "eve@example.com" })
            assert_redirected_to res, "/session/new"
            res = client.delete("/account", { "authenticity_token" => token, "password" => "s3cr3t-s3cr3t" })
            assert_redirected_to res, "/session/new"
            assert_equal "ann@example.com", User.find(ann.id).email_address
            assert_equal 1, User.all.count
            # Signed in, the browser comes back to the page it asked for, which the
            # nav links to.
            assert_redirected_to AppTest.sign_in(client), "/account/edit"
            res = client.get("/account/edit")
            assert_response res, :ok
            assert_includes res.body, "<h1>Account</h1>"
            assert_includes res.body, "<a href=\"/account/edit\">Account</a>"
            assert_includes res.body, "<form action=\"/account\" method=\"post\"><input type=\"hidden\" name=\"_method\" value=\"patch\">"
            assert_includes res.body, "<input type=\"email\" name=\"user[email_address]\" id=\"user_email_address\" value=\"ann@example.com\" autocomplete=\"username\">"
            assert_includes res.body, "<label for=\"user_current_password\">Current password</label>"
            assert_includes res.body, "<form action=\"/account\" method=\"post\"><input type=\"hidden\" name=\"_method\" value=\"delete\">"
          end

          test "PATCH /account past ten requests is refused for a while" do
            client = new_client
            ann = AppTest.user
            AppTest.sign_in(client)
            client.get("/account/edit")
            token = AppTest.form_token(client)
            Cybertrain::RateLimit.reset_all!
            count = 0
            while count < 10
              res = client.patch("/account", { "authenticity_token" => token, "user[current_password]" => "wrong-password" })
              assert_response res, :unprocessable_entity
              count += 1
            end
            # Wrong passwords here do not count toward the lockout, which guards
            # signing in (a stolen session could lock the owner out).
            assert_equal 0, User.find(ann.id).failed_attempts
            assert_nil User.find(ann.id).locked_until
            # The right password now gets the limit's answer and changes nothing; a
            # deletion counts in the same window.
            res = client.patch("/account", { "authenticity_token" => token, "user[current_password]" => "s3cr3t-s3cr3t",
                                             "user[email_address]" => "ann@new.example" })
            assert_redirected_to res, "/account/edit"
            assert_includes client.follow_redirect!.body, "<p class=\"alert\">Try again later.</p>"
            assert_equal "ann@example.com", User.find(ann.id).email_address
            res = client.delete("/account", { "authenticity_token" => token, "password" => "s3cr3t-s3cr3t" })
            assert_redirected_to res, "/account/edit"
            refute User.find_by(id: ann.id).nil?
            # Once the window is over (its counts forgotten), the same change passes.
            Cybertrain::RateLimit.reset_all!
            res = client.patch("/account", { "authenticity_token" => token, "user[current_password]" => "s3cr3t-s3cr3t",
                                             "user[email_address]" => "ann@new.example" })
            assert_redirected_to res, "/account/edit"
            confirm_new_address(ann)
            assert_equal "ann@new.example", User.find(ann.id).email_address
            Cybertrain::RateLimit.reset_all!
          end

          test "wrong current passwords are limited per user too, from any address" do
            client = new_client
            ann = AppTest.user
            AppTest.user("bob@example.com")
            AppTest.sign_in(client)
            bobs = Cybertrain::Test::Client.new(APP)
            AppTest.sign_in(bobs, "bob@example.com")
            client.get("/account/edit")
            token = AppTest.form_token(client)
            Cybertrain::RateLimit.reset_all!
            # Ten wrong guesses, each from another address: the per-address limit
            # never fills.
            count = 0
            while count < 10
              client.peer_address = "203.0.113.#{count + 1}"
              res = client.patch("/account", { "authenticity_token" => token, "user[current_password]" => "wrong-password" })
              assert_response res, :unprocessable_entity
              count += 1
            end
            # The eleventh, from yet another address and with the right password:
            # the per-user limit answers, and nothing changes.
            client.peer_address = "203.0.113.99"
            res = client.patch("/account", { "authenticity_token" => token, "user[current_password]" => "s3cr3t-s3cr3t",
                                             "user[email_address]" => "ann@new.example" })
            assert_redirected_to res, "/account/edit"
            assert_includes client.follow_redirect!.body, "<p class=\"alert\">Try again later.</p>"
            assert_equal "ann@example.com", User.find(ann.id).email_address
            # Another user, from that same address, is not held back by ann's count.
            bobs.get("/account/edit")
            bobs.peer_address = "203.0.113.99"
            res = bobs.patch("/account", { "authenticity_token" => AppTest.form_token(bobs), "user[current_password]" => "s3cr3t-s3cr3t",
                                           "user[password]" => NEW_PASSWORD, "user[password_confirmation]" => NEW_PASSWORD })
            assert_redirected_to res, "/account/edit"
            assert_includes bobs.follow_redirect!.body, UPDATED
            Cybertrain::RateLimit.reset_all!
          end

          test "the form's fields are the only ones a change takes" do
            client = new_client
            ann = AppTest.user
            AppTest.sign_in(client)
            # Fields the form does not have, sent with the right password: ignored.
            res = update_account(client, "s3cr3t-s3cr3t", { "password" => NEW_PASSWORD, "password_confirmation" => NEW_PASSWORD,
                                                            "admin" => "1", "failed_attempts" => "7", "locked_until" => "2099-01-01 00:00:00" })
            assert_redirected_to res, "/account/edit"
            changed = User.find(ann.id)
            assert changed.authenticate(NEW_PASSWORD)
            assert_equal false, changed.admin?
            assert_equal 0, changed.failed_attempts
            assert_nil changed.locked_until
          end

          test "PATCH and DELETE /account without the form's token are refused" do
            client = new_client
            ann = AppTest.user
            AppTest.sign_in(client)
            res = client.patch("/account", { "user[current_password]" => "s3cr3t-s3cr3t", "user[email_address]" => "eve@example.com" })
            assert_response res, :forbidden
            res = client.delete("/account", { "password" => "s3cr3t-s3cr3t" })
            assert_response res, :forbidden
            # Nor with another browser's token.
            other = Cybertrain::Test::Client.new(APP)
            other.get("/session/new")
            foreign = AppTest.form_token(other)
            res = client.patch("/account", { "authenticity_token" => foreign, "user[current_password]" => "s3cr3t-s3cr3t",
                                             "user[email_address]" => "eve@example.com" })
            assert_response res, :forbidden
            res = client.delete("/account", { "authenticity_token" => foreign, "password" => "s3cr3t-s3cr3t" })
            assert_response res, :forbidden
            assert_equal "ann@example.com", User.find(ann.id).email_address
            refute User.find_by(id: ann.id).nil?
            assert signed_in?(client)
          end

          test "a new hash of the password stays with this browser when the change fails" do
            client = new_client
            ann = AppTest.user
            AppTest.user("bob@example.com")
            AppTest.sign_in(client)
            digest = ann.password_digest
            begin
              # The cost raised since ann's digest was made: checking her password
              # saves a new hash of it (User#authenticate).
              Cybertrain::Password.iterations = Cybertrain::Password::TEST_ITERATIONS + 1
              res = update_account(client, "s3cr3t-s3cr3t", { "email_address" => "bob@example.com" })
              assert_response res, :unprocessable_entity
              assert_includes res.body, "<li>Email address has already been taken</li>"
              rehashed = User.find(ann.id).password_digest
              refute rehashed == digest
              assert Cybertrain::Password.verify?("s3cr3t-s3cr3t", rehashed)
              # This browser is still signed in on its row.
              assert signed_in?(client)
              assert_equal 1, Session.where(user_id: ann.id).count
            ensure
              Cybertrain::Password.iterations = Cybertrain::Password::TEST_ITERATIONS
            end
          end

          test "a deletion the database refuses changes nothing and says so" do
            client = new_client
            ann = AppTest.user
            AppTest.sign_in(client)
            phone = Cybertrain::Test::Client.new(APP)
            AppTest.sign_in(phone)
            add_note_for(ann)
            log = StringIO.new
            begin
              with_config("test", NO_HOSTS, "", log) do
                refused = delete_account(client, "s3cr3t-s3cr3t")
                assert_response refused, :unprocessable_entity
                assert_includes refused.body, NOT_DELETED
              end
              # The user and both sessions are kept (one transaction), and the
              # log says why.
              refute User.find_by(id: ann.id).nil?
              assert_equal 2, Session.where(user_id: ann.id).count
              assert signed_in?(client)
              assert signed_in?(phone)
              assert_includes log.string, "[ERROR] account not deleted: FOREIGN KEY constraint failed"
            ensure
              drop_notes
            end
            # Once nothing refers to the user, the same deletion passes.
            res = delete_account(client, "s3cr3t-s3cr3t")
            assert_redirected_to res, "/"
            assert_nil User.find_by(id: ann.id)
            assert_equal 0, Session.where(user_id: ann.id).count
          end

          Cybertrain::Test.run!
        RUBY
        splice(text, "@ADDRESS_HELPERS@", confirmable ? accounts_test_confirm_helpers : accounts_test_address_helpers)
      end

      # What a new address does on the account page, in test/accounts.rb:
      # it takes effect at once.
      def self.accounts_test_address_helpers
        <<~'RUBY'
          # What the page says after a new address, which takes effect at once.
          ADDRESS_CHANGED = UPDATED

          # Nothing more to do for a new address to take effect (with
          # --confirmable, its link is opened here).
          def confirm_new_address(user)
            nil
          end
        RUBY
      end

      # --confirmable's: it takes effect once the link mailed to it is opened.
      def self.accounts_test_confirm_helpers
        <<~'RUBY'
          # What the page says after a new address (--confirmable): it takes
          # effect once the link mailed to it is opened.
          ADDRESS_CHANGED = "<p class=\"notice\">A link to confirm the new address was sent to it. The address changes once the link is opened.</p>"

          # Opens the link of the new address user is waiting for (from a browser
          # that is not signed in, as a mail reader's would be), so it takes the
          # old one's place. test/confirmations.rb follows the mailed link itself.
          def confirm_new_address(user)
            token = User.find(user.id).confirmation_token
            res = Cybertrain::Test::Client.new(APP).get("/confirmations/#{token}")
            assert_redirected_to res, "/session/new"
            nil
          end
        RUBY
      end

      # ---- --invite-only ------------------------------------------------

      # The first user's page (--invite-only); with `confirmable` the user
      # it creates is confirmed, as nothing mails them.
      def self.setup_controller(app, confirmable = false)
        env = setup_env(app)
        text = <<~RUBY
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
              @CONFIRMED_AT_CREATION@
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
        chunk = margin("# Nothing mails the first user a link: the address counts as\n" \
                       "# confirmed (--confirmable).\n@user.confirmed_at = Time.now\n", 4)
        splice(text, "@CONFIRMED_AT_CREATION@", confirmable ? chunk : "")
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
      def self.user_command(app, invite_only = false, confirmable = false)
        head = user_command_head(app, invite_only, confirmable)
        warning = invite_only ? user_command_warning(app) : ""
        tail = <<~RUBY
          end

          Cybertrain::Main.command("user", "EMAIL [PASSWORD] | admin EMAIL | unadmin EMAIL: create a user or set its password, or grant or revoke admin") do |argv|
            UserCommand.run(argv)
          end
        RUBY
        join_three(head, warning, tail)
      end

      # The command's file up to the end of its last method, in both modes;
      # with `confirmable` a user it creates is confirmed, as nothing mails
      # them (pre-flight finding 6).
      def self.user_command_head(app, invite_only, confirmable = false)
        mode = invite_only ? " --invite-only" : ""
        warned = invite_only ? ", which also calls UserCommand.warn_if_no_user before serving" : ""
        text = <<~RUBY
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
              @CONFIRMED_AT_CREATION@
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
        chunk = margin("# A user made here gets no mail with a link: the address counts as\n" \
                       "# confirmed from the start (--confirmable).\nuser.confirmed_at = Time.now if created\n", 4)
        splice(text, "@CONFIRMED_AT_CREATION@", confirmable ? chunk : "")
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
          # #{env}=https://#{app}.example.com: set it, with https, wherever the
          # app is served. Unset, they take the address the request came to,
          # which is trusted only in development, in tests, or when
          # CYBERTRAIN_HOSTS lists the app's hosts; anywhere else a reset mail
          # is not sent and the log says why.
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
      def self.routes_block(invite_only = false, confirmable = false)
        confirmations = confirmable ? "#{CONFIRMATIONS_ROUTE}\n" : ""
        pending = confirmable ? "\n#{PENDING_EMAIL_ROUTE}" : ""
        if invite_only
          return <<~RUBY
            resource :session, only: [:new, :create, :destroy]
            #{PASSWORDS_ROUTE}
            #{confirmations}#{ACCOUNT_ROUTE}#{pending}
            get "/setup", to: "setup#new", as: "setup"
            post "/setup", to: "setup#create"
          RUBY
        end

        <<~RUBY
          resource :session, only: [:new, :create, :destroy]
          #{PASSWORDS_ROUTE}
          #{confirmations}#{ACCOUNT_ROUTE}#{pending}
          get "/sign_up", to: "registrations#new", as: "sign_up"
          post "/sign_up", to: "registrations#create"
        RUBY
      end

      # ---- tests --------------------------------------------------------

      # The same shape as examples/blog/test/support/blog_test.rb: boots the
      # app on a fresh test database. Shared by every test file; copy
      # helpers into it as the app grows. With `confirmable`, AppTest.user's
      # users have confirmed their address.
      def self.app_test_support(confirmable = false)
        text = <<~RUBY
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
              @CONFIRMED@
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
        chunk = margin("# Confirmed, as a user who signs in has to be (--confirmable;\n" \
                       "# test/confirmations.rb makes the unconfirmed ones).\nuser.confirmed_at = Time.now\n", 4)
        splice(text, "@CONFIRMED@", confirmable ? chunk : "")
      end

      # test/authentication.rb: the head (requires, new_client, the sign-in
      # form), the sign-up or first-run tests, then the sign-in and sign-out
      # tests both variants share.
      # The pieces go through locals and `<<`: an interpolation of three
      # method calls could free one result while building the next under
      # Spinel (spikes/NOTES.md rule 65), and the CLI compiles there too.
      def self.authentication_test(confirmable = false)
        head = authentication_test_head(false)
        middle = sign_up_tests(confirmable)
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

          # A cookie that already carries a start (a browser that signed in
          # before, or the account page's restart after a new password, on day
          # 13 of its sign-in) starts again: SessionStore stamps this request's
          # time, so the new sign-in gets its whole limit.
          test "a sign-in restarts the lifetime of a cookie that already has one" do
            new_client
            user = AppTest.user
            ctx = Cybertrain::Context.new(Cybertrain::Request.new("POST", "/session", {}, ""))
            ctx.session = Cybertrain::Session.new
            ctx.session["_issued_at"] = Time.now.to_i - 13 * DAY
            assert ctx.session.issued_at > 0
            LifetimeProbeController.new(ctx).probe_start(user, false)
            assert_equal 0, ctx.session.issued_at
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
          # receiver and puts the settings back, also when the block fails (an
          # assertion raises). A mail sent with deliver_later goes out when the
          # test runs the jobs (perform_enqueued_jobs).
          def with_smtp_receiver
            receiver = Cybertrain::Test::SmtpReceiver.new
            port = receiver.start
            c = Cybertrain.config
            host = c.smtp_host
            given_port = c.smtp_port
            tls = c.smtp_tls
            from = c.smtp_from
            begin
              c.smtp_host = "127.0.0.1"
              c.smtp_port = port
              c.smtp_tls = "none"
              c.smtp_from = "noreply@example.com"
              yield receiver
            ensure
              receiver.stop
              c.smtp_host = host
              c.smtp_port = given_port
              c.smtp_tls = tls
              c.smtp_from = from
            end
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

          # Runs the block with Config#env, hosts_from_env and the base_url
          # setting given (and Cybertrain.logger writing errors to log, unless it
          # is nil), then puts them back, also when the block fails.
          def with_config(env, hosts, base_url, log = nil)
            c = Cybertrain.config
            saved_env = c.env
            saved_hosts = c.hosts_from_env
            saved_base_url = c.string_setting(:base_url)
            saved_logger = Cybertrain.logger
            begin
              c.env = env
              c.hosts_from_env = hosts
              c.set_string_setting(:base_url, base_url)
              Cybertrain.logger = Cybertrain::Logger.new(log, :error) unless log.nil?
              yield
            ensure
              c.env = saved_env
              c.hosts_from_env = saved_hosts
              c.set_string_setting(:base_url, saved_base_url)
              Cybertrain.logger = saved_logger
            end
            nil
          end

          # with_config's `hosts` for an app that lists none (CYBERTRAIN_HOSTS unset).
          NO_HOSTS = Array.new(0) { "" }
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
          # (15 minutes, bound to the password and the address) and what a reset
          # ends. Run with `cybertrain spin test`; its snapshot comes from the
          # compiled binary (the database is FFI).
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
            with_config("test", NO_HOSTS, "https://shop.example") do
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
            end
            with_smtp_receiver do |receiver|
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
          end

          test "without base_url a link takes the request's address only where that is safe" do
            client = new_client
            AppTest.user
            # Tests: the address the request came to.
            with_config("test", NO_HOSTS, "") do
              request_reset(client, "ann@example.com", "www.example.com")
            end
            with_smtp_receiver do |receiver|
              assert_equal 1, perform_enqueued_jobs
              link = last_mail_link(receiver)
              assert link.start_with?("http://www.example.com/passwords/"), link
            end
            # Development checks the Host header: the request's address.
            with_config("development", NO_HOSTS, "") do
              assert Cybertrain.config.host_check?
              assert_redirected_to request_reset(client, "ann@example.com", "localhost:3000"), "/session/new"
            end
            with_smtp_receiver do |receiver|
              assert_equal 1, perform_enqueued_jobs
              link = last_mail_link(receiver)
              assert link.start_with?("http://localhost:3000/passwords/"), link
            end
            # Production with CYBERTRAIN_HOSTS (the Host header is checked): the
            # request's address too.
            with_config("production", ["shop.example"], "") do
              assert Cybertrain.config.host_check?
              assert_redirected_to request_reset(client, "ann@example.com", "shop.example"), "/session/new"
            end
            with_smtp_receiver do |receiver|
              assert_equal 1, perform_enqueued_jobs
              link = last_mail_link(receiver)
              assert link.start_with?("http://shop.example/passwords/"), link
            end
            # Production with base_url: base_url, whatever the Host.
            with_config("production", NO_HOSTS, "https://shop.example") do
              assert_redirected_to request_reset(client, "ann@example.com", "evil.example"), "/session/new"
            end
            with_smtp_receiver do |receiver|
              assert_equal 1, perform_enqueued_jobs
              link = last_mail_link(receiver)
              assert link.start_with?("https://shop.example/passwords/"), link
            end
            # Production with neither: no mail, an [ERROR] line, the same answer.
            log = StringIO.new
            with_config("production", NO_HOSTS, "", log) do
              refute Cybertrain.config.host_check?
              res = request_reset(client, "ann@example.com", "evil.example")
              assert_redirected_to res, "/session/new"
              assert_includes client.follow_redirect!.body, SENT
            end
            assert_no_enqueued_jobs "cybertrain mail"
            assert_includes log.string, "[ERROR] password reset mail not sent: set @BASE_URL_ENV@ (or CYBERTRAIN_HOSTS)\n"
          end

          test "any other environment without base_url sends no mail and answers the same" do
            client = new_client
            AppTest.user
            log = StringIO.new
            # A staging server reached with a forged Host: not production, but
            # nothing checks its Host header either.
            with_config("staging", NO_HOSTS, "", log) do
              refute Cybertrain.config.host_check?
              known = request_reset(client, "ann@example.com", "evil.example")
              known_status = known.status
              known_location = known.header("Location")
              known_body = known.body
              assert_includes client.follow_redirect!.body, SENT
              unknown = request_reset(client, "nobody@example.com", "evil.example")
              assert_equal 303, known_status
              assert_equal known_status, unknown.status
              assert_equal "/session/new", known_location
              assert_equal known_location, unknown.header("Location")
              assert_equal known_body, unknown.body
              assert_includes client.follow_redirect!.body, SENT
            end
            assert_no_enqueued_jobs "cybertrain mail"
            assert_includes log.string, "[ERROR] password reset mail not sent: set @BASE_URL_ENV@ (or CYBERTRAIN_HOSTS)\n"
            assert log.string.index("evil.example").nil?
          end

          # Such an address is refused at entry now (User.email_address_format?),
          # so this one was saved before that check existed.
          test "an address the mailer refuses gets the same answer, and the log says why" do
            client = new_client
            AppTest.user("jose@example.com").update_columns(email_address: "josé@example.com")
            log = StringIO.new
            with_config("test", NO_HOSTS, "https://shop.example", log) do
              refused = request_reset(client, "josé@example.com")
              refused_status = refused.status
              refused_location = refused.header("Location")
              refused_body = refused.body
              assert_includes client.follow_redirect!.body, SENT
              unknown = request_reset(client, "nobody@example.com")
              assert_equal 303, refused_status
              assert_equal refused_status, unknown.status
              assert_equal "/session/new", refused_location
              assert_equal refused_location, unknown.header("Location")
              assert_equal refused_body, unknown.body
            end
            assert_no_enqueued_jobs "cybertrain mail"
            assert_includes log.string, "[ERROR] password reset mail not sent: the to address contains a space, a control character or a non-ASCII byte\n"
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
            assert_equal "no-referrer", res.header("Referrer-Policy")
            assert_includes client.follow_redirect!.body, INVALID
            res = reset_with(client, stale, NEW_PASSWORD)
            assert_redirected_to res, "/passwords/new"
            assert_equal "no-referrer", res.header("Referrer-Policy")
            assert_equal user.password_digest, User.find_by(id: user.id).password_digest
            res = client.get("/passwords/#{fresh}/edit")
            assert_response res, :ok
            # The page's address holds the token: no Referer leaves it.
            assert_equal "no-referrer", res.header("Referrer-Policy")
            # The address form's page is not the link's.
            assert_nil client.get("/passwords/new").header("Referrer-Policy")
            assert_includes res.body, "<form action=\"/passwords/#{fresh}\" method=\"post\"><input type=\"hidden\" name=\"_method\" value=\"put\">"
          end

          test "the token stops working once the password changed" do
            client = new_client
            ann = AppTest.user
            bob = AppTest.user("bob@example.com")
            token = ann.password_reset_token
            earlier = ann.password_reset_token(Time.now.to_i - 60)
            # A token names its user and is bound to that user's password and
            # address: one with bob's id and ann's binding, ann's id and her
            # password alone, or another purpose, is no one's.
            assert_equal "#{ann.password_digest}:ann@example.com", ann.password_reset_binding
            assert_equal ann.id, User.find_by_password_reset_token(token).id
            assert_equal bob.id, User.find_by_password_reset_token(bob.password_reset_token).id
            assert_nil User.find_by_password_reset_token(Cybertrain::Token.issue("password_reset", bob.id, 15 * 60, ann.password_reset_binding))
            assert_nil User.find_by_password_reset_token(Cybertrain::Token.issue("password_reset", ann.id, 15 * 60, ann.password_digest))
            assert_nil User.find_by_password_reset_token(Cybertrain::Token.issue("confirmation", ann.id, 15 * 60, ann.password_reset_binding))
            assert_nil User.find_by_password_reset_token("")
            # A new password that does not pass: the token still holds.
            res = reset_with(client, token, NEW_PASSWORD, "something-else")
            assert_redirected_to res, "/passwords/#{token}/edit"
            assert_equal "no-referrer", res.header("Referrer-Policy")
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
            # And so does a new address (test/accounts.rb changes it through the page).
            fresh = changed.password_reset_token
            refute User.find_by_password_reset_token(fresh).nil?
            changed.email_address = "ann@new.example"
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
            with_config("test", NO_HOSTS, "https://shop.example/") do
              request_reset(client, "ann@example.com")
            end
            assert_enqueued_jobs 1, "cybertrain mail"
            with_smtp_receiver do |receiver|
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

      # test/confirmations.rb (--confirmable): the mail through the SMTP
      # receiver, sign-in refused until the address is confirmed, the link,
      # a new address, the send-again form, and the users that /setup and the
      # user command make. Its first test is the mode's: sign-up's mail, or
      # (--invite-only) /setup's confirmed first user.
      def self.confirmations_test(app, invite_only = false)
        text = confirmations_test_body
        text = splice(text, "@FIRST_USER_TEST@", invite_only ? confirmations_setup_test : confirmations_sign_up_test)
        text = text.gsub(BASE_URL_ENV_MARK, base_url_env(app))
        text.gsub("@APP@", app)
      end

      def self.confirmations_test_body
        <<~'RUBY'
          # Confirming the email address (cybertrain generate authentication
          # --confirmable): the mail with the link (through an SMTP receiver in this
          # process), sign-in refused until the link is opened, the link itself
          # (three days, once, signing nobody in), a new address that takes effect
          # only once its own link is opened, and the form that mails the link
          # again. Run with `cybertrain spin test`; its snapshot comes from the
          # compiled binary (the database is FFI).
          require "stringio"
          require_relative "support/app_test"
          require_relative "support/authentication_helpers"
          require_relative "../app/commands/user_command"

          WRONG = "<p class=\"alert\">Try another email address or password.</p>"
          UNCONFIRMED = "<p class=\"alert\">Confirm your email address first: open the link in the mail we sent you.</p>"
          SEND_AGAIN_LINK = "<a href=\"/confirmations/new\">Send the confirmation link again</a>"
          CONFIRMED = "<p class=\"notice\">Your email address has been confirmed.</p>"
          INVALID = "<p class=\"alert\">That confirmation link is invalid or has expired.</p>"
          TAKEN = "<p class=\"alert\">That email address belongs to another account now, so it was not changed.</p>"
          SENT = "<p class=\"notice\">If that address is registered and not confirmed yet, a link to confirm it was sent to it.</p>"
          ADDRESS_CHANGED = "<p class=\"notice\">A link to confirm the new address was sent to it. The address changes once the link is opened.</p>"
          UPDATED = "<p class=\"notice\">Your account has been updated.</p>"
          CANCELLED = "<p class=\"notice\">The change of address was cancelled; its link no longer works.</p>"
          CANCEL_BUTTON = "<form class=\"button_to\" method=\"post\" action=\"/account/pending_email\">"

          def new_client
            Session.all.delete_all
            User.all.delete_all
            clear_enqueued_jobs
            Cybertrain::Test::Client.new(APP)
          end

          # A user who has not confirmed the address yet, as a sign-up leaves one
          # (AppTest.user's are confirmed).
          def unconfirmed_user(email_address = "ann@example.com")
            user = User.new(email_address: email_address)
            user.password = "s3cr3t-s3cr3t"
            user.save!
            user
          end

          # The token in a link ("http://.../confirmations/<token>").
          def token_in(link)
            start = link.index("/confirmations/").to_i + 15
            link[start, link.size - start].to_s
          end

          # Whether client is signed in as email_address: the nav names them.
          def signed_in?(client, email_address = "ann@example.com")
            client.get("/session/new").body.include?("<span>#{email_address}</span>")
          end

          # Sends the form that mails the link again, the rate limit's counts
          # forgotten first (as AppTest.sign_in does).
          def send_again(client, email_address)
            Cybertrain::RateLimit.reset_all!
            client.get("/confirmations/new")
            client.post("/confirmations", { "authenticity_token" => AppTest.form_token(client), "email_address" => email_address })
          end

          # Sends the new-password form of a password reset link with this token.
          def reset_with(client, token, password)
            client.get("/passwords/new")
            client.put("/passwords/#{token}", { "authenticity_token" => AppTest.form_token(client),
                                                "password" => password, "password_confirmation" => password })
          end

          # A trigger that, just before ann's row gets a new address, inserts
          # another account with that address: what a sign-up that lands
          # between User#confirm's check and its write does.
          def add_race_trigger
            Cybertrain::DB.with do |c|
              c.execute("CREATE TRIGGER confirmation_race BEFORE UPDATE OF email_address ON users " \
                        "WHEN NEW.email_address <> OLD.email_address BEGIN " \
                        "INSERT INTO users (email_address, password_digest, created_at, updated_at) " \
                        "VALUES (NEW.email_address, 'x', NEW.updated_at, NEW.updated_at); END")
            end
            nil
          end

          def drop_race_trigger
            Cybertrain::DB.with { |c| c.execute("DROP TRIGGER IF EXISTS confirmation_race") }
            nil
          end

          # Sends the account form with the current password and a new address.
          def change_address(client, email_address)
            Cybertrain::RateLimit.reset_all!
            client.get("/account/edit")
            client.patch("/account", { "authenticity_token" => AppTest.form_token(client), "user[current_password]" => "s3cr3t-s3cr3t",
                                       "user[email_address]" => email_address })
          end

          @FIRST_USER_TEST@

          test "./@APP@ user makes a confirmed user, and mails nothing" do
            client = new_client
            assert_equal 0, UserCommand.run(["Dee@Example.com", "s3cr3t-s3cr3t"])
            dee = User.find_by(email_address: "dee@example.com")
            refute dee.nil?
            assert_equal true, dee.confirmed?
            assert_no_enqueued_jobs "cybertrain mail"
            assert_redirected_to AppTest.sign_in(client, "dee@example.com"), "/"
            # A new password for a user who exists leaves the confirmation as it was.
            ann = unconfirmed_user
            assert_equal 0, UserCommand.run(["ann@example.com", "an0ther-s3cr3t"])
            assert_equal false, User.find(ann.id).confirmed?
            assert_redirected_to AppTest.sign_in(client, "ann@example.com", "an0ther-s3cr3t"), "/session/new"
            assert_includes client.follow_redirect!.body, UNCONFIRMED
          end

          test "sign-in is refused until confirmed, with the send-again link" do
            client = new_client
            ann = unconfirmed_user
            # A wrong password, or an address no user has: the usual message, which
            # says nothing of the address.
            assert_redirected_to AppTest.sign_in(client, "ann@example.com", "wrong-password"), "/session/new"
            page = client.follow_redirect!.body
            assert_includes page, WRONG
            refute page.include?(UNCONFIRMED)
            assert_redirected_to AppTest.sign_in(client, "nobody@example.com"), "/session/new"
            page = client.follow_redirect!.body
            assert_includes page, WRONG
            refute page.include?(UNCONFIRMED)
            # The right password: refused all the same, with the reason, and the
            # sign-in page links to the form that mails the link again.
            assert_redirected_to AppTest.sign_in(client), "/session/new"
            page = client.follow_redirect!.body
            assert_includes page, UNCONFIRMED
            refute page.include?(WRONG)
            assert_includes page, SEND_AGAIN_LINK
            assert_equal 0, Session.count
            refute signed_in?(client)
            # As any right password does, it cleared the wrong one's count.
            assert_equal 0, User.find(ann.id).failed_attempts
            # Confirmed, the same password signs in.
            assert_redirected_to client.get("/confirmations/#{ann.confirmation_token}"), "/session/new"
            assert_redirected_to AppTest.sign_in(client), "/"
            assert_equal 1, Session.count
            assert signed_in?(client)
          end

          # start_new_session_for is private (the Authentication concern's): a
          # controller made for these tests calls it, as any action could.
          class SessionStartProbeController < ApplicationController
            def probe_start(user)
              start_new_session_for(user)
            end
          end

          test "the concern itself starts no session for an unconfirmed account" do
            new_client
            ann = unconfirmed_user
            ctx = Cybertrain::Context.new(Cybertrain::Request.new("POST", "/session", {}, ""))
            ctx.session = Cybertrain::Session.new
            SessionStartProbeController.new(ctx).probe_start(ann)
            assert_equal 0, Session.count
            assert_nil ctx.session[:session_id]
            assert_nil ctx.session[:password_key]
            # Confirmed, the same call signs in.
            ann.update_columns(confirmed_at: Time.now)
            SessionStartProbeController.new(ctx).probe_start(User.find(ann.id))
            assert_equal 1, Session.count
            assert_equal Session.first.id, ctx.session[:session_id].to_i
          end

          test "the link confirms, and the user can then sign in" do
            client = new_client
            ann = unconfirmed_user
            token = ann.confirmation_token
            before = Time.now.to_i
            res = client.get("/confirmations/#{token}")
            after = Time.now.to_i
            assert_redirected_to res, "/session/new"
            # The page's address holds the token: no Referer leaves it.
            assert_equal "no-referrer", res.header("Referrer-Policy")
            page = client.follow_redirect!.body
            assert_includes page, CONFIRMED
            # A link opened from a mail signs nobody in.
            refute page.include?("<span>ann@example.com</span>")
            assert_equal 0, Session.count
            confirmed = User.find(ann.id)
            assert confirmed.confirmed?
            assert confirmed.confirmed_at.to_i >= before
            assert confirmed.confirmed_at.to_i <= after
            assert_equal "ann@example.com", confirmed.email_address
            # Used once, the link confirms nothing more.
            assert_nil User.find_by_confirmation_token(token)
            res = client.get("/confirmations/#{token}")
            assert_redirected_to res, "/confirmations/new"
            assert_equal "no-referrer", res.header("Referrer-Policy")
            assert_includes client.follow_redirect!.body, INVALID
            assert_equal confirmed.confirmed_at.to_i, User.find(ann.id).confirmed_at.to_i
            # The user then signs in, with the password.
            assert_redirected_to AppTest.sign_in(client), "/"
            assert signed_in?(client)
          end

          test "the link lasts three days and belongs to its user and address" do
            client = new_client
            ann = unconfirmed_user
            bob = unconfirmed_user("bob@example.com")
            assert_equal 259_200, User::CONFIRMATION_TOKEN_TTL
            now = Time.now.to_i
            assert ann.confirmation_token(now).start_with?("#{ann.id}--#{now + 259_200}--")
            assert_equal ":ann@example.com:0", ann.confirmation_binding
            stale = ann.confirmation_token(now - 259_200 - 60)
            fresh = ann.confirmation_token(now - 259_200 + 60)
            assert_nil User.find_by_confirmation_token(stale)
            assert_equal ann.id, User.find_by_confirmation_token(fresh).id
            assert_redirected_to client.get("/confirmations/#{stale}"), "/confirmations/new"
            assert_equal false, User.find(ann.id).confirmed?
            # Another user's id with ann's binding, another purpose, or nothing at
            # all: no one's.
            assert_nil User.find_by_confirmation_token(Cybertrain::Token.issue("confirmation", bob.id, 900, ann.confirmation_binding))
            assert_nil User.find_by_confirmation_token(ann.password_reset_token)
            assert_nil User.find_by_password_reset_token(ann.confirmation_token)
            assert_nil User.find_by_confirmation_token("")
            assert_redirected_to client.get("/confirmations/not-a-token"), "/confirmations/new"
            assert_equal bob.id, User.find_by_confirmation_token(bob.confirmation_token).id
            assert_equal false, User.find(bob.id).confirmed?
          end

          test "an email change takes effect only when the new address confirms" do
            client = new_client
            ann = AppTest.user
            AppTest.user("bob@example.com")
            AppTest.sign_in(client)
            reset_token = ann.password_reset_token
            res = change_address(client, " Ann@New.Example ")
            assert_redirected_to res, "/account/edit"
            page = client.follow_redirect!.body
            assert_includes page, ADDRESS_CHANGED
            # Not yet: the old address is in use, the new one waits.
            assert_includes page, "<span>ann@example.com</span>"
            assert_includes page, "<p class=\"hint\">Waiting for confirmation: ann@new.example</p>"
            waiting = User.find(ann.id)
            assert_equal "ann@example.com", waiting.email_address
            assert_equal "ann@new.example", waiting.unconfirmed_email
            other = Cybertrain::Test::Client.new(APP)
            assert_redirected_to AppTest.sign_in(other, "ann@new.example"), "/session/new"
            assert_redirected_to AppTest.sign_in(other), "/"
            refute User.find_by_password_reset_token(reset_token).nil?
            # A taken address is refused when it is asked for; the one waiting stays.
            res = change_address(client, "bob@example.com")
            assert_response res, :unprocessable_entity
            assert_includes res.body, "<li>Email address has already been taken</li>"
            assert_includes res.body, "<p class=\"hint\">Waiting for confirmation: ann@new.example</p>"
            assert_equal "ann@new.example", User.find(ann.id).unconfirmed_email
            # The mail goes to the new address.
            assert_enqueued_jobs 1, "cybertrain mail"
            with_smtp_receiver do |receiver|
              assert_equal 1, perform_enqueued_jobs
              mail = receiver.received_message
              refute mail.nil?
              assert_equal ["ann@new.example"], mail.envelope_recipients
              assert_includes mail.message_parts["text"], "Hello ann@new.example,\r\n"
              link = last_mail_link(receiver)
              assert link.start_with?("http://www.example.com/confirmations/"), link
              # Opened in the browser that asked: back to the account page, with
              # the new address in use.
              path = "/confirmations/#{token_in(link)}"
              opened = client.get(path)
              assert_redirected_to opened, "/account/edit"
              account_page = client.follow_redirect!.body
              assert_includes account_page, CONFIRMED
              assert_includes account_page, "<span>ann@new.example</span>"
              refute account_page.include?("Waiting for confirmation")
              # The link is used up.
              assert_redirected_to client.get(path), "/confirmations/new"
            end
            changed = User.find(ann.id)
            assert_equal "ann@new.example", changed.email_address
            assert_nil changed.unconfirmed_email
            assert changed.confirmed?
            # Both sessions go on; the old address signs in no more, the new one does.
            assert_equal 2, Session.where(user_id: ann.id).count
            assert_redirected_to AppTest.sign_in(other, "ann@example.com"), "/session/new"
            assert_redirected_to AppTest.sign_in(other, "ann@new.example"), "/"
            # A password reset link sent to the old address is spent.
            assert_nil User.find_by_password_reset_token(reset_token)
          end

          test "a new address someone takes before its link is opened is not moved in" do
            client = new_client
            ann = AppTest.user
            AppTest.sign_in(client)
            assert_redirected_to change_address(client, "carol@example.com"), "/account/edit"
            token = User.find(ann.id).confirmation_token
            # Meanwhile carol signs up with it: an address that only waits is free.
            carol = unconfirmed_user("carol@example.com")
            # A pending address someone has taken since blocks nothing else of
            # ann's account: the user command and the rehash a sign-in makes after
            # the cost was raised save, and leave it waiting (a password reset
            # saves too, below, and withdraws it).
            assert_equal 0, UserCommand.run(["ann@example.com", "an0ther-s3cr3t"])
            assert User.find(ann.id).authenticate("an0ther-s3cr3t")
            assert_equal 0, UserCommand.run(["ann@example.com", "s3cr3t-s3cr3t"])
            assert User.find(ann.id).authenticate("s3cr3t-s3cr3t")
            assert_equal "carol@example.com", User.find(ann.id).unconfirmed_email
            digest = User.find(ann.id).password_digest
            begin
              Cybertrain::Password.iterations = Cybertrain::Password::TEST_ITERATIONS + 1
              assert_redirected_to AppTest.sign_in(client), "/"
              refute User.find(ann.id).password_digest == digest
              refute Cybertrain::Password.needs_rehash?(User.find(ann.id).password_digest)
            ensure
              Cybertrain::Password.iterations = Cybertrain::Password::TEST_ITERATIONS
            end
            # The link: the address is not moved in, and the one waiting is
            # forgotten (it can never be confirmed now).
            res = client.get("/confirmations/#{token}")
            assert_redirected_to res, "/account/edit"
            page = client.follow_redirect!.body
            assert_includes page, TAKEN
            refute page.include?("Waiting for confirmation")
            assert_equal "ann@example.com", User.find(ann.id).email_address
            assert_nil User.find(ann.id).unconfirmed_email
            assert_equal "carol@example.com", User.find(carol.id).email_address
            # Another new address ends the link to the one before.
            assert_redirected_to change_address(client, "ann@other.example"), "/account/edit"
            other_token = User.find(ann.id).confirmation_token
            assert_redirected_to change_address(client, "ann@third.example"), "/account/edit"
            assert_nil User.find_by_confirmation_token(other_token)
            assert_equal "ann@third.example", User.find(ann.id).unconfirmed_email
            # A password reset saves with a taken address waiting, and withdraws it.
            assert_redirected_to change_address(client, "zed@example.com"), "/account/edit"
            unconfirmed_user("zed@example.com")
            stranger = Cybertrain::Test::Client.new(APP)
            assert_redirected_to reset_with(stranger, User.find(ann.id).password_reset_token, "an0ther-s3cr3t"), "/session/new"
            assert User.find(ann.id).authenticate("an0ther-s3cr3t")
            assert_nil User.find(ann.id).unconfirmed_email
          end

          test "a password-only change keeps the new address waiting" do
            client = new_client
            ann = AppTest.user
            AppTest.sign_in(client)
            assert_redirected_to change_address(client, "ann@new.example"), "/account/edit"
            token = User.find(ann.id).confirmation_token
            # The form sends the address in use back (it is pre-filled) with a new
            # password: no change of address, so the one waiting stays.
            client.get("/account/edit")
            res = client.patch("/account", { "authenticity_token" => AppTest.form_token(client), "user[current_password]" => "s3cr3t-s3cr3t",
                                             "user[email_address]" => "ann@example.com",
                                             "user[password]" => "n3w-s3cr3t-n3w", "user[password_confirmation]" => "n3w-s3cr3t-n3w" })
            assert_redirected_to res, "/account/edit"
            page = client.follow_redirect!.body
            assert_includes page, UPDATED
            assert_includes page, "<p class=\"hint\">Waiting for confirmation: ann@new.example</p>"
            kept = User.find(ann.id)
            assert_equal "ann@example.com", kept.email_address
            assert_equal "ann@new.example", kept.unconfirmed_email
            assert kept.authenticate("n3w-s3cr3t-n3w")
            # The address alone, sent again unchanged: nothing changes either.
            client.get("/account/edit")
            res = client.patch("/account", { "authenticity_token" => AppTest.form_token(client), "user[current_password]" => "n3w-s3cr3t-n3w",
                                             "user[email_address]" => " Ann@Example.com " })
            assert_redirected_to res, "/account/edit"
            assert_equal "ann@new.example", User.find(ann.id).unconfirmed_email
            # The link still confirms it.
            assert_equal ann.id, User.find_by_confirmation_token(token).id
            assert_redirected_to client.get("/confirmations/#{token}"), "/account/edit"
            assert_equal "ann@new.example", User.find(ann.id).email_address
          end

          test "a new address waiting can be withdrawn, and its link then moves nothing" do
            client = new_client
            ann = AppTest.user
            AppTest.sign_in(client)
            # Nothing waits: no button to withdraw it.
            page = client.get("/account/edit").body
            refute page.include?("/account/pending_email")
            refute page.include?("Cancel this change")
            # A mistyped address, a stranger's mailbox: the page offers to withdraw it.
            assert_redirected_to change_address(client, "ann@stranger.example"), "/account/edit"
            token = User.find(ann.id).confirmation_token
            page = client.follow_redirect!.body
            assert_includes page, CANCEL_BUTTON
            assert_includes page, "Cancel this change"
            # Without the form's token: refused, and still waiting.
            res = client.delete("/account/pending_email", { "x" => "1" })
            assert_response res, :forbidden
            assert_equal "ann@stranger.example", User.find(ann.id).unconfirmed_email
            # A visitor is sent to sign in, and nothing changes.
            visitor = Cybertrain::Test::Client.new(APP)
            visitor.get("/session/new")
            res = visitor.delete("/account/pending_email", { "authenticity_token" => AppTest.form_token(visitor) })
            assert_redirected_to res, "/session/new"
            assert_equal "ann@stranger.example", User.find(ann.id).unconfirmed_email
            # The button, with no password (withdrawing is the safe direction).
            client.get("/account/edit")
            res = client.delete("/account/pending_email", { "authenticity_token" => AppTest.form_token(client) })
            assert_redirected_to res, "/account/edit"
            page = client.follow_redirect!.body
            assert_includes page, CANCELLED
            refute page.include?("Waiting for confirmation")
            refute page.include?("Cancel this change")
            withdrawn = User.find(ann.id)
            assert_nil withdrawn.unconfirmed_email
            assert_equal "ann@example.com", withdrawn.email_address
            # The stranger's link: invalid now, and the account stays where it was.
            assert_nil User.find_by_confirmation_token(token)
            stranger = Cybertrain::Test::Client.new(APP)
            res = stranger.get("/confirmations/#{token}")
            assert_redirected_to res, "/confirmations/new"
            assert_includes stranger.follow_redirect!.body, INVALID
            assert_equal "ann@example.com", User.find(ann.id).email_address
            assert_nil User.find(ann.id).unconfirmed_email
            assert signed_in?(client)
          end

          test "two confirmations racing for one address: the second gets the taken answer" do
            client = new_client
            ann = AppTest.user
            AppTest.sign_in(client)
            assert_redirected_to change_address(client, "carol@example.com"), "/account/edit"
            token = User.find(ann.id).confirmation_token
            # Another account takes the address between confirm's check and its
            # write (a trigger inserts it just before the UPDATE): the unique index
            # refuses the write, and the answer is the taken one, not a 500.
            add_race_trigger
            begin
              res = client.get("/confirmations/#{token}")
              assert_redirected_to res, "/account/edit"
              assert_includes client.follow_redirect!.body, TAKEN
            ensure
              drop_race_trigger
            end
            raced = User.find(ann.id)
            assert_equal "ann@example.com", raced.email_address
            assert_nil raced.unconfirmed_email
            assert raced.confirmed?
            assert signed_in?(client)
          end

          test "a password reset confirms a new account's address, and withdraws a new address waiting" do
            client = new_client
            ann = unconfirmed_user
            # The reset link went to ann's own address: it proves that mailbox, as
            # the confirmation link does (and someone who signed up first with that
            # address loses the account to its owner).
            assert_redirected_to reset_with(client, ann.password_reset_token, "an0ther-s3cr3t"), "/session/new"
            assert User.find(ann.id).confirmed?
            assert_redirected_to AppTest.sign_in(client, "ann@example.com", "an0ther-s3cr3t"), "/"
            # A new address waiting for bob: a reset proves only bob's old
            # mailbox, so it never confirms it; it withdraws it, and its link
            # (whoever asked for it may be who bob takes the account back from).
            bob = AppTest.user("bob@example.com")
            confirmed_at = User.find(bob.id).confirmed_at.to_i
            bobs = Cybertrain::Test::Client.new(APP)
            AppTest.sign_in(bobs, "bob@example.com")
            assert_redirected_to change_address(bobs, "bob@new.example"), "/account/edit"
            pending_token = User.find(bob.id).confirmation_token
            refute User.find_by_confirmation_token(pending_token).nil?
            assert_redirected_to reset_with(client, bob.password_reset_token, "an0ther-s3cr3t"), "/session/new"
            reset = User.find(bob.id)
            assert_equal "bob@example.com", reset.email_address
            assert_nil reset.unconfirmed_email
            assert_equal confirmed_at, reset.confirmed_at.to_i
            assert_nil User.find_by_confirmation_token(pending_token)
            res = Cybertrain::Test::Client.new(APP).get("/confirmations/#{pending_token}")
            assert_redirected_to res, "/confirmations/new"
            assert_equal "bob@example.com", User.find(bob.id).email_address
            assert_redirected_to AppTest.sign_in(client, "bob@new.example", "an0ther-s3cr3t"), "/session/new"
          end

          test "send again answers the same for unknown addresses" do
            client = new_client
            ann = unconfirmed_user
            AppTest.user("bob@example.com")
            res = client.get("/confirmations/new")
            assert_response res, :ok
            assert_includes res.body, "<h1>Send the confirmation link again</h1>"
            assert_includes res.body, "<form action=\"/confirmations\" method=\"post\">"
            known = send_again(client, " Ann@Example.com ")
            known_status = known.status
            known_location = known.header("Location")
            known_body = known.body
            assert_includes client.follow_redirect!.body, SENT
            unknown = send_again(client, "nobody@example.com")
            unknown_status = unknown.status
            unknown_location = unknown.header("Location")
            unknown_body = unknown.body
            assert_includes client.follow_redirect!.body, SENT
            # An address confirmed already: the same answer too.
            confirmed = send_again(client, "bob@example.com")
            assert_equal 303, known_status
            assert_equal "/session/new", known_location
            assert_equal known_status, unknown_status
            assert_equal known_location, unknown_location
            assert_equal known_body, unknown_body
            assert_equal known_status, confirmed.status
            assert_equal known_location, confirmed.header("Location")
            assert_equal known_body, confirmed.body
            assert_includes client.follow_redirect!.body, SENT
            # One mail, to the address that waits; its link confirms it.
            assert_enqueued_jobs 1, "cybertrain mail"
            with_smtp_receiver do |receiver|
              assert_equal 1, perform_enqueued_jobs
              mail = receiver.received_message
              refute mail.nil?
              assert_equal ["ann@example.com"], mail.envelope_recipients
              link = last_mail_link(receiver)
              assert_redirected_to client.get("/confirmations/#{token_in(link)}"), "/session/new"
            end
            assert User.find(ann.id).confirmed?
            # Confirmed now, ann gets the same answer and no mail.
            clear_enqueued_jobs
            res = send_again(client, "ann@example.com")
            assert_equal known_location, res.header("Location")
            assert_equal known_body, res.body
            assert_no_enqueued_jobs "cybertrain mail"
          end

          test "send again: a refused address, no safe base and the rate limit" do
            client = new_client
            # Refused at entry now (User.email_address_format?), so saved
            # before that check existed.
            unconfirmed_user("jose@example.com").update_columns(email_address: "josé@example.com")
            unconfirmed_user
            # An address the mailer refuses: the same answer, and the log says why.
            log = StringIO.new
            with_config("test", NO_HOSTS, "", log) do
              refused = send_again(client, "josé@example.com")
              refused_location = refused.header("Location")
              refused_body = refused.body
              unknown = send_again(client, "nobody@example.com")
              assert_equal 303, unknown.status
              assert_equal "/session/new", refused_location
              assert_equal refused_location, unknown.header("Location")
              assert_equal refused_body, unknown.body
            end
            assert_no_enqueued_jobs "cybertrain mail"
            assert_includes log.string, "[ERROR] confirmation mail not sent: the to address contains a space, a control character or a non-ASCII byte\n"
            # Production with neither base_url nor CYBERTRAIN_HOSTS: no mail, an
            # [ERROR] line, the same answer.
            log = StringIO.new
            with_config("production", NO_HOSTS, "", log) do
              answer = send_again(client, "ann@example.com")
              assert_redirected_to answer, "/session/new"
              assert_includes client.follow_redirect!.body, SENT
            end
            assert_no_enqueued_jobs "cybertrain mail"
            assert_includes log.string, "[ERROR] confirmation mail not sent: set @BASE_URL_ENV@ (or CYBERTRAIN_HOSTS)\n"
            # Ten requests per client address, then the form again for a while.
            Cybertrain::RateLimit.reset_all!
            client.get("/confirmations/new")
            token = AppTest.form_token(client)
            count = 0
            while count < 10
              res = client.post("/confirmations", { "authenticity_token" => token, "email_address" => "nobody@example.com" })
              assert_redirected_to res, "/session/new"
              count += 1
            end
            res = client.post("/confirmations", { "authenticity_token" => token, "email_address" => "ann@example.com" })
            assert_redirected_to res, "/confirmations/new"
            assert_includes client.follow_redirect!.body, "<p class=\"alert\">Try again later.</p>"
            assert_no_enqueued_jobs "cybertrain mail"
            Cybertrain::RateLimit.reset_all!
          end

          Cybertrain::Test.run!
        RUBY
      end

      # Sign-up mode's first test: the mail, and nobody signed in.
      def self.confirmations_sign_up_test
        <<~'RUBY'
          test "sign-up sends a confirmation mail and signs nobody in" do
            client = new_client
            client.get("/sign_up")
            res = client.post("/sign_up", { "authenticity_token" => AppTest.form_token(client),
                                            "user[email_address]" => " Ann@Example.com ",
                                            "user[password]" => "s3cr3t-s3cr3t",
                                            "user[password_confirmation]" => "s3cr3t-s3cr3t" })
            assert_redirected_to res, "/session/new"
            page = client.follow_redirect!.body
            assert_includes page, "<p class=\"notice\">Welcome! A link to confirm your email address was sent to it. Open it, then sign in.</p>"
            refute page.include?("<span>ann@example.com</span>")
            user = User.first
            assert_equal "ann@example.com", user.email_address
            assert_equal false, user.confirmed?
            assert_nil user.confirmed_at
            assert_nil user.unconfirmed_email
            assert_equal 0, Session.count
            assert_enqueued_jobs 1, "cybertrain mail"
            with_smtp_receiver do |receiver|
              assert_equal 1, perform_enqueued_jobs
              mail = receiver.received_message
              refute mail.nil?
              assert_equal "Confirm your email address", mail.message_header("Subject")
              assert_equal I18n.t("confirmations_mailer.confirmation_instructions.subject"), mail.message_header("Subject")
              assert_equal ["ann@example.com"], mail.envelope_recipients
              assert_equal "noreply@example.com", mail.envelope_from
              link = last_mail_link(receiver)
              assert link.start_with?("http://www.example.com/confirmations/#{user.id}--"), link
              assert_equal "Hello ann@example.com,\r\n\r\nOpen this link within the next 3 days to confirm your email address:\r\n" \
                           "#{link}\r\n\r\nIf you did not ask for this, ignore this mail: nothing changes.\r\n", mail.message_parts["text"]
              assert_includes mail.message_parts["html"], "<p>Hello ann@example.com,</p>"
              assert_includes mail.message_parts["html"], "<p><a href=\"#{link}\">Confirm my email address</a></p>"
              # The mailed link is the one that confirms this user.
              assert_equal user.id, User.find_by_confirmation_token(token_in(link)).id
            end
            # Until it is opened, the right password signs nobody in.
            assert_redirected_to AppTest.sign_in(client), "/session/new"
            assert_equal 0, Session.count
          end
        RUBY
      end

      # --invite-only's first test: /setup's user is confirmed and signed in.
      def self.confirmations_setup_test
        <<~'RUBY'
          test "/setup makes a confirmed first user, and mails nothing" do
            client = new_client
            client.get("/setup?token=#{SetupController.setup_token}")
            res = client.post("/setup", { "authenticity_token" => AppTest.form_token(client),
                                          "token" => SetupController.setup_token,
                                          "user[email_address]" => "ann@example.com",
                                          "user[password]" => "s3cr3t-s3cr3t",
                                          "user[password_confirmation]" => "s3cr3t-s3cr3t" })
            assert_redirected_to res, "/"
            assert_equal true, User.first.confirmed?
            assert signed_in?(client)
            assert_no_enqueued_jobs "cybertrain mail"
            # Signed out, the same password signs in again.
            client.get("/session/new")
            client.post("/session", { "_method" => "delete", "authenticity_token" => AppTest.form_token(client) })
            assert_redirected_to AppTest.sign_in(client), "/"
          end
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

          test "POST /setup and ./#{app} user refuse an address list or a malformed address" do
            client = new_client
            client.get(setup_link)
            form = setup_form(AppTest.form_token(client), "s3cr3t-s3cr3t", "s3cr3t-s3cr3t")
            form["user[email_address]"] = "ann@example.com,eve@evil.example"
            res = client.post("/setup", form)
            assert_response res, :unprocessable_entity
            assert_includes res.body, "<li>Email address is invalid</li>"
            assert_equal 0, User.count
            assert_equal 1, run_command(["user", "ann@example.com,eve@evil.example", "s3cr3t-s3cr3t"])
            assert_equal 1, run_command(["user", "ann", "s3cr3t-s3cr3t"])
            assert_equal 0, User.count
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

      # With `confirmable` the first test's sign-up signs nobody in (the
      # mail it sends is test/confirmations.rb's).
      def self.sign_up_tests(confirmable = false)
        text = <<~RUBY
          @SIGN_UP_TEST@

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

          # One address only: Cybertrain::Mailer reads a comma as a second
          # recipient, so the account would have two mailboxes. Nor any address
          # the mailer would refuse (Cybertrain::Mailer.address_problem: a
          # Unicode space or control character, ";", "(" and the like), which
          # could never be sent its mails.
          test "POST /sign_up refuses an address list or a malformed address" do
            client = new_client
            client.get("/sign_up")
            ["ann@example.com,eve@evil.example", "ann@example.com eve@evil.example", "<ann@example.com>", "ann", "@example.com", "ann@", "a@b@example.com",
             "ann@example.com\\u00A0", "ann\\u3000@example.com", "ann\\u0085@example.com", "ann@exa\\u2028mple.com", "ann;x@example.com", "ann(x)@example.com"].each do |address|
              Cybertrain::RateLimit.reset_all!
              res = client.post("/sign_up", { "authenticity_token" => AppTest.form_token(client),
                                              "user[email_address]" => address,
                                              "user[password]" => "s3cr3t-s3cr3t",
                                              "user[password_confirmation]" => "s3cr3t-s3cr3t" })
              assert_response res, :unprocessable_entity
              assert_includes res.body, "<li>Email address is invalid</li>"
            end
            assert_equal 0, User.count
            assert_equal 0, Session.count
            # A plus-address is one address the mailer sends to.
            Cybertrain::RateLimit.reset_all!
            client.post("/sign_up", { "authenticity_token" => AppTest.form_token(client),
                                      "user[email_address]" => "ann+news@example.com",
                                      "user[password]" => "s3cr3t-s3cr3t",
                                      "user[password_confirmation]" => "s3cr3t-s3cr3t" })
            assert_equal 1, User.count
            assert_equal "ann+news@example.com", User.first.email_address
          end

          # RegistrationsController's rate_limit: ten sign-ups per client
          # address, then the form again until the window closes (the cache's
          # clock held still, as in POST /session's test). The ten send no
          # password, so none of them costs a hash.
          test "POST /sign_up past ten requests is refused for a while" do
            client = new_client
            Cybertrain::RateLimit.reset_all!
            Cybertrain::Cache.clock = -> { 2_000_000_000 }
            begin
              client.get("/sign_up")
              token = AppTest.form_token(client)
              empty = { "authenticity_token" => token, "user[email_address]" => "nobody@example.com",
                        "user[password]" => "", "user[password_confirmation]" => "" }
              right = { "authenticity_token" => token, "user[email_address]" => "ann@example.com",
                        "user[password]" => "s3cr3t-s3cr3t", "user[password_confirmation]" => "s3cr3t-s3cr3t" }
              10.times { client.post("/sign_up", empty) }
              res = client.post("/sign_up", right)
              assert_redirected_to res, "/sign_up"
              assert_equal 0, User.count
              res = client.follow_redirect!
              assert_includes res.body, "<p class=\\"alert\\">Try again later.</p>"
              Cybertrain::Cache.clock = -> { 2_000_000_000 + 3 * 60 }
              client.post("/sign_up", right)
              assert_equal 1, User.count
            ensure
              # The system clock again, even when an assertion fails.
              Cybertrain::Cache.clock = -> { Time.now.to_i }
            end
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
        splice(text, "@SIGN_UP_TEST@", confirmable ? sign_up_confirm_test : sign_up_sign_in_test)
      end

      def self.sign_up_sign_in_test
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
        RUBY
      end

      # --confirmable's: the user, unconfirmed, and no session.
      def self.sign_up_confirm_test
        <<~RUBY
          # --confirmable: nobody is signed in until the address is confirmed
          # (test/confirmations.rb follows the mail's link).
          test "POST /sign_up creates the user and asks them to confirm the address" do
            client = new_client
            client.get("/sign_up")
            res = client.post("/sign_up", { "authenticity_token" => AppTest.form_token(client),
                                            "user[email_address]" => " Ann@Example.com ",
                                            "user[password]" => "s3cr3t-s3cr3t",
                                            "user[password_confirmation]" => "s3cr3t-s3cr3t" })
            assert_redirected_to res, "/session/new"
            assert_equal 1, User.count
            assert_equal "ann@example.com", User.first.email_address
            assert User.first.password_digest.start_with?("$pbkdf2-sha256$")
            assert_equal false, User.first.confirmed?
            assert_equal 0, Session.count
            res = client.follow_redirect!
            refute res.body.include?("<span>ann@example.com</span>")
            assert_includes res.body, "<a href=\\"/session/new\\">Sign in</a>"
          end
        RUBY
      end

      def self.authentication_test_tail
        <<~RUBY
          # User.email_address_format?: one address, whatever the mail
          # standards allow beyond that.
          test "an address is one address: one @, nothing around it that splits it" do
            ["ann@example.com", "ann+news@example.com", "ann.lee+news@mail.example.co.jp", "a@b", "o'brien@example.com"].each do |address|
              assert User.email_address_format?(address), address
            end
            ["", "ann", "@example.com", "ann@", "a@b@example.com", "ann@example.com,eve@evil.example",
             "ann@example.com eve@evil.example", "ann @example.com", "<ann@example.com>", "Ann <ann@example.com>",
             "ann@example.com\\n", "ann@exa\\tmple.com", "\\"ann lee\\"@example.com",
             "ann@example.com\\u00A0", "ann\\u3000@example.com", "ann\\u0085@example.com", "ann@exa\\u2028mple.com",
             "ann;x@example.com", "ann(x)@example.com", "ann@[example].com", "ann:x@example.com"].each do |address|
              refute User.email_address_format?(address), address
            end
          end

          # An address saved before the check existed (an older release's) is not
          # checked again: its owner can still reset the password.
          test "an address saved before the format check still saves" do
            new_client
            ann = AppTest.user
            ann.update_columns(email_address: "ann@example.com,old@example.com")
            kept = User.find(ann.id)
            kept.password = "an0ther-s3cr3t"
            assert kept.save
            kept.email_address = "ann@example.com,new@example.com"
            refute kept.save
            assert_includes kept.errors.full_messages, "Email address is invalid"
          end

          # Every form that signs in, out or resets carries the page's token
          # (Cybertrain's CSRF check): without it, a 403 and nothing done.
          test "POST /session, PUT /passwords/:token and DELETE /session without the form's token are refused" do
            client = new_client
            user = AppTest.user
            res = client.post("/session", { "email_address" => "ann@example.com", "password" => "s3cr3t-s3cr3t" })
            assert_response res, :forbidden
            assert_equal 0, Session.count
            token = user.password_reset_token
            res = client.put("/passwords/\#{token}", { "password" => "an0ther-s3cr3t", "password_confirmation" => "an0ther-s3cr3t" })
            assert_response res, :forbidden
            refute User.find_by_password_reset_token(token).nil?
            AppTest.sign_in(client)
            assert_equal 1, Session.count
            res = client.post("/session", { "_method" => "delete" })
            assert_response res, :forbidden
            assert_equal 1, Session.count
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
