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
#   test/fixtures/users.yml, test/support/session_test_helper.rb
#   (sign_in_as, included into ActionDispatch::IntegrationTest by
#   test/test_helper.rb) and the class-form tests cybertrain test runs:
#   test/models/user_test.rb, test/controllers/sessions_controller_test.rb,
#   registrations_controller_test.rb, passwords_controller_test.rb,
#   accounts_controller_test.rb, test/integration/remember_me_test.rb,
#   lockout_test.rb, admin_test.rb (cli/authentication_tests.rb)
#
# and these edits: `include Authentication` into
# app/controllers/application_controller.rb, the routes into
# config/routes.rb (and the jobs page's line, a comment until now, drawn
# behind require_admin), the nav partial into the layout, the user command
# into bin/<app>.rb, the base_url setting (<APP>_BASE_URL, where links in
# mails start) into config/app.rb (plus a sign-in in any
# test/integration/*_attachment_test.rb, and in a scaffold's
# test/controllers/*_controller_test.rb, written before it, which now
# need one). Every file is written once
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
# D85), so it adds their lines to bin/<app>.rb and bin/db.rb, each unless
# it or `require "cybertrain"` is there (Templates.add_requires), in every
# mode and on the upgrade path: `cybertrain/jobs` (the jobs page it draws,
# the job thread that sends the mails), `cybertrain/mailer` (the mailers,
# and User's address check, Mailer.address_problem), `cybertrain/mailer/later`
# (the mails' deliver_later) and `cybertrain/rate_limit` (the rate_limit
# lines of the sign-in, sign-up, reset and account controllers). With
# cybertrain/jobs it uncomments config/deploy.yml's worker role
# (Templates.enable_worker_role), as `generate job` does.
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
#   app/views/mail/_confirmation.html.erb,
#   test/controllers/confirmations_controller_test.rb
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
require "cybertrain/cli/authentication_tests"

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
      # The setup line of an ActionDispatch::IntegrationTest (the
      # attachment's, the scaffold's controller test): `generate attachment`
      # writes test_sign_in_lines after it when app/models/user.rb exists;
      # add_sign_in_to_attachment_tests and add_sign_in_to_controller_tests
      # add a sign-in to a test written before this generator ran.
      TEST_SETUP_LINE = "  setup do"
      # The sign-in line (SessionTestHelper#sign_in_as of the fixture user
      # `one`); a test that has it signs in already.
      TEST_SIGN_IN_POST = "sign_in_as users(:one)"
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
      # overwrote (--force), the paths it deleted (--force: an earlier
      # generator's test files, TEST_FILES_REPLACED) and the changes to make
      # by hand, each a heading line (`manual  <path>: ...`) and a unified
      # diff (LineDiff.unified) that `patch -p1` applies: one per file it
      # writes whole that exists with other content, and one each for
      # ApplicationController and the jobs page's route of an application
      # 0.4 generated; or, for an earlier generator's test file, the one
      # line `manual  <path>: replaced by <new path>; delete it`.
      class GenerateResult
        # @return [Array<String>] each one's path from the app's root
        #   (`manual`: each one's heading and diff)
        attr_reader :created, :forced, :manual, :removed

        def initialize(created, forced, manual, removed)
          @created = created
          @forced = forced
          @manual = manual
          @removed = removed
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

        result = GenerateResult.new(Array.new(0) { "" }, Array.new(0) { "" }, Array.new(0) { "" }, Array.new(0) { "" })
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
        record_file(result, root, "test/fixtures/users.yml", users_fixture(confirmable), force)
        record_file(result, root, Templates::SESSION_TEST_HELPER, session_test_helper, force)
        record_file(result, root, "test/models/user_test.rb", user_model_test, force)
        record_file(result, root, "test/controllers/sessions_controller_test.rb", sessions_controller_test(invite_only), force)
        if invite_only
          record_file(result, root, "test/integration/first_run_test.rb", first_run_test(app), force)
        else
          record_file(result, root, "test/controllers/registrations_controller_test.rb", registrations_controller_test(confirmable), force)
        end
        record_file(result, root, "test/controllers/passwords_controller_test.rb", passwords_controller_test(app), force)
        record_file(result, root, "test/controllers/accounts_controller_test.rb", accounts_controller_test(confirmable), force)
        record_file(result, root, "test/controllers/confirmations_controller_test.rb", confirmations_controller_test(app, invite_only), force) if confirmable
        record_file(result, root, "test/integration/remember_me_test.rb", remember_me_integration_test, force)
        record_file(result, root, "test/integration/lockout_test.rb", lockout_integration_test, force)
        record_file(result, root, "test/integration/admin_test.rb", admin_integration_test(app), force)
        record_replaced_tests(result, root, force)
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
        add_session_helper(result, root)
        add_sign_in_to_attachment_tests(root)
        add_sign_in_to_controller_tests(root)
        add_command_to_bin(bin_path, app, invite_only)
        add_setting_to_config(config_path, app, invite_only)
        Templates.add_requires(root, SUBSYSTEM_REQUIRES)
        # The mails go out from a job thread: config/deploy.yml's worker role,
        # commented by `cybertrain new`, can run now.
        Templates.enable_worker_role(root)
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

      # The setup line of the attachment test in an app with
      # authentication: the fixture user `one` signed in through the form
      # (SessionTestHelper#sign_in_as), as a browser would, before each test.
      def self.test_sign_in_lines
        out = +""
        out << "    # A user signed in through the form: the controller's actions need one.\n"
        out << "    #{TEST_SIGN_IN_POST}\n"
        out
      end

      # A test/integration/*_attachment_test.rb written by `generate
      # attachment` before this generator ran drives the forms anonymously,
      # which every action now redirects to the sign-in page. Its setup gets
      # the sign-in line, once (TEST_SIGN_IN_POST marks a test that has
      # it); a setup rewritten past recognition is left alone with a note.
      def self.add_sign_in_to_attachment_tests(root)
        Dir.glob(File.join(root, "test/integration/*_attachment_test.rb")).sort.each do |path|
          name = "test/integration/#{File.basename(path)}"
          source = File.read(path)
          unless source.index(TEST_SIGN_IN_POST).nil?
            puts "identical #{name} (signs in already)"
            next
          end
          if source.index("\n#{TEST_SETUP_LINE}\n").nil?
            puts "skip #{name} (no setup do): sign in there before each test"
            next
          end

          File.write(path, insert_after_line(source, "#{TEST_SETUP_LINE}\n", test_sign_in_lines))
          puts "insert #{name} (sign in first)"
        end
        # An earlier generator's top-level-form attachment test
        # (test/attachment_<model>_<field>.rb) is not rewritten: it is named,
        # with what it needs, since its forms now redirect to the sign-in page.
        unsigned_attachment_tests(root).each do |name|
          puts "note   #{name}: its requests now need a signed-in user; sign one in before them " \
               "(post \"/session\" with a user's email_address and password), or move it to the class form " \
               "(an ActionDispatch::IntegrationTest with `#{TEST_SIGN_IN_POST}` in its setup)"
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
            def locked? = !locked_until.nil? && locked_until > Time.current

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
              ends = Time.current + Cybertrain.config.auth_lockout_period
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
            def password_reset_token(now = Time.current.to_i)
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
          def confirmation_token(now = Time.current.to_i)
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
            self.confirmed_at = Time.current
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
              now = Time.current.to_i
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
              found.update_columns(last_active_at: Time.current) if now - active >= 60
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
                                       remember: remember, last_active_at: Time.current)
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
            # environment (production, staging, ...) "" and an ERROR line: the
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
                       "user.update_columns(confirmed_at: Time.current) unless user.confirmed?\n", 8)
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
            # Printed only by the boot WARN line (UserCommand.warn_if_no_user) and
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
                       "# confirmed (--confirmable).\n@user.confirmed_at = Time.current\n", 4)
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
                       "# confirmed from the start (--confirmable).\nuser.confirmed_at = Time.current if created\n", 4)
        splice(text, "@CONFIRMED_AT_CREATION@", confirmable ? chunk : "")
      end

      # --invite-only: the boot warning and the question it asks, indented
      # into the module.
      def self.user_command_warning(app)
        text = <<~RUBY

          # Called by bin/#{app}.rb before the server boots: a WARN line while no
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
            # `./#{app} user unadmin EMAIL`, and a WARN line at boot while no user exists
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

      # first + second + third through `<<` on locals: an interpolation of
      # three method calls could free one result while building the next
      # under Spinel (spikes/NOTES.md rule 65), and the CLI compiles there
      # too.
      def self.join_three(first, second, third)
        out = +""
        out << first << second << third
        out
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
    end
  end
end
