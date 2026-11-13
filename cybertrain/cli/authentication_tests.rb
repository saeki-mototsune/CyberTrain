# The tests `cybertrain generate authentication` writes (spec section 11,
# third bullet): Rails-shaped classes that `cybertrain test` runs in one
# program, on the fixtures of test/fixtures/users.yml, signing in with
# SessionTestHelper#sign_in_as (test/support/session_test_helper.rb, which
# test/test_helper.rb includes into ActionDispatch::IntegrationTest).
#
#   test/fixtures/users.yml                         one (an admin) and two
#   test/support/session_test_helper.rb             sign_in_as, sign_out, open_session, authenticity_token_in
#   test/models/user_test.rb                        the address format
#   test/controllers/sessions_controller_test.rb    sign-in and sign-out
#   test/controllers/registrations_controller_test.rb   sign-up (not --invite-only)
#   test/integration/first_run_test.rb              /setup and the user command (--invite-only)
#   test/controllers/passwords_controller_test.rb   the reset, its mail and link
#   test/controllers/accounts_controller_test.rb    the account page
#   test/controllers/confirmations_controller_test.rb   --confirmable
#   test/integration/remember_me_test.rb            day 15 and day 30, the idle limit
#   test/integration/lockout_test.rb                the lock and its hour
#   test/integration/admin_test.rb                  require_admin, user admin
#
# Time moves with travel_to and travel (no Session row is moved back in
# time), and mail is read from Cybertrain::Mailer.deliveries (the test
# environment stores it) with assert_emails and perform_enqueued_jobs.
# Phase 4b's top-level test files these replace (TEST_FILES_REPLACED) are
# named on a re-run, and deleted with --force (plan decision D15).
require "digest"
require "base64"

module Cybertrain
  module CLI
    module Authentication
      # The test files an earlier generator wrote (phase 4b, and 0.4's
      # test/authentication.rb and test/support/app_test.rb), each with what
      # replaces it: a re-run names them (`manual  <path>: replaced by ...;
      # delete it`) and --force deletes them. Pairs of [old, new].
      TEST_FILES_REPLACED = [
        ["test/authentication.rb", "test/controllers/sessions_controller_test.rb"],
        ["test/admin.rb", "test/integration/admin_test.rb"],
        ["test/remember_me.rb", "test/integration/remember_me_test.rb"],
        ["test/lockout.rb", "test/integration/lockout_test.rb"],
        ["test/passwords.rb", "test/controllers/passwords_controller_test.rb"],
        ["test/accounts.rb", "test/controllers/accounts_controller_test.rb"],
        ["test/confirmations.rb", "test/controllers/confirmations_controller_test.rb"],
        ["test/support/app_test.rb", "test/test_helper.rb"],
        ["test/support/authentication_helpers.rb", Templates::SESSION_TEST_HELPER]
      ].freeze

      # The password of every user in test/fixtures/users.yml.
      FIXTURE_PASSWORD = "password"

      # What test/test_helper.rb gets after the class that holds
      # Templates::TEST_HELPER_MARKER: SessionTestHelper in every
      # integration and controller test.
      TEST_HELPER_INCLUDE = "class ActionDispatch::IntegrationTest\n  include SessionTestHelper\nend\n"

      # The scaffold's controller test setup line (Templates.controller_test):
      # `    @product = products(:one)`, after which an app with
      # authentication signs in.
      SIGN_IN_LINE = "    sign_in_as users(:one)\n"

      # Cybertrain::Password's test-environment cost (Password::TEST_ITERATIONS),
      # salt length and algorithm name. The gem's CLI does not load the
      # framework's password.rb (it needs the configuration), so the digest
      # is made here, in the same format; test/cli_authentication.rb checks
      # it with Password.verify?.
      FIXTURE_ITERATIONS = 1000
      FIXTURE_SALT_BYTES = 16

      # The password_digest of a fixture user: Cybertrain::Password's
      # format (`$pbkdf2-sha256$i=N$salt$key`) for FIXTURE_PASSWORD at the
      # test environment's cost (so no sign-in rehashes it), with a salt
      # taken from the label so that a re-run writes the same file (fixtures
      # are not ERB: the digest is written out).
      def self.fixture_digest(label)
        salt = Digest::SHA256.digest("cybertrain fixture users #{label}")[0, FIXTURE_SALT_BYTES].to_s
        key = fixture_pbkdf2(FIXTURE_PASSWORD, salt, FIXTURE_ITERATIONS)
        "$pbkdf2-sha256$i=#{FIXTURE_ITERATIONS}$#{Base64.urlsafe_encode64(salt, padding: false)}$#{Base64.urlsafe_encode64(key, padding: false)}"
      end

      # PBKDF2-HMAC-SHA256, one 32-byte block, for a password of at most 64
      # bytes (Cybertrain::Password.pbkdf2_sha256's loop).
      def self.fixture_pbkdf2(password, salt, iterations)
        ipad = ("6" * 64).b
        opad = ("\\" * 64).b
        n = password.bytesize
        i = 0
        while i < n
          b = password.getbyte(i)
          ipad.setbyte(i, b ^ 0x36)
          opad.setbyte(i, b ^ 0x5c)
          i += 1
        end
        u = Digest::SHA256.digest(opad + Digest::SHA256.digest(ipad + salt.b + "\x00\x00\x00\x01".b))
        out = u.dup
        c = 1
        while c < iterations
          u = Digest::SHA256.digest(opad + Digest::SHA256.digest(ipad + u))
          j = 0
          while j < 32
            out.setbyte(j, out.getbyte(j) ^ u.getbyte(j))
            j += 1
          end
          c += 1
        end
        out
      end

      # test/fixtures/users.yml: `one` (an admin) and `two`, both with the
      # password FIXTURE_PASSWORD; with `confirmable`, both confirmed.
      def self.users_fixture(confirmable = false)
        confirmed = confirmable ? "  confirmed_at: 2026-11-11 12:00:00\n" : ""
        out = +""
        out << "# The users every test starts with (cybertrain generate authentication).\n"
        out << "# Their password is \"#{FIXTURE_PASSWORD}\": each digest is Cybertrain::Password's,\n"
        out << "# made when the generator ran (a fixture is not ERB, so it is written\n"
        out << "# out). Sign one in with `sign_in_as users(:one)`.\n"
        out << "one:\n"
        out << "  email_address: one@example.com\n"
        out << "  password_digest: #{fixture_digest("one")}\n"
        out << "  admin: true\n"
        out << "  failed_attempts: 0\n"
        out << confirmed
        out << "\n"
        out << "two:\n"
        out << "  email_address: two@example.com\n"
        out << "  password_digest: #{fixture_digest("two")}\n"
        out << "  admin: false\n"
        out << "  failed_attempts: 0\n"
        out << confirmed
        out
      end

      # test/support/session_test_helper.rb, as Rails 8's generator writes
      # test/test_helpers/session_test_helper.rb (here it signs in through
      # the form).
      def self.session_test_helper
        <<~'RUBY'
          # Signing in and out in tests (cybertrain generate authentication), as
          # Rails 8's generator writes it: test/test_helper.rb includes it into
          # ActionDispatch::IntegrationTest, so every controller and integration
          # test can sign in a fixture user (test/fixtures/users.yml).
          #
          # Written by the generator; it is yours to change.
          module SessionTestHelper
            # Signs user in through the sign-in form, as a browser would: every
            # fixture user's password is "password". `remember: true` checks the
            # form's "Keep me signed in" box.
            def sign_in_as(user, remember: false)
              fields = { email_address: user.email_address, password: "password" }
              # A browser sends an unchecked box not at all.
              fields[:remember_me] = "1" if remember
              post session_path, params: fields
              nil
            end

            # Signs this browser out.
            def sign_out = delete(session_path)

            # The authenticity_token of the first form in a page (body), for a
            # request sent inside with_forgery_protection.
            def authenticity_token_in(body)
              marker = "name=\"authenticity_token\" value=\""
              at = body.index(marker)
              raise "no authenticity_token in the page" if at.nil?

              start = at + marker.size
              stop = body.index("\"", start).to_i
              body[start, stop - start].to_s
            end

            # Another browser, with cookies of its own, as Rails' open_session
            # gives: `phone = open_session`, then `phone.sign_in_as users(:one)`,
            # `phone.get ...` and `phone.assert_response :success`.
            def open_session = ActionDispatch::IntegrationTest.new
          end
        RUBY
      end

      # test/test_helper.rb with SessionTestHelper included into
      # ActionDispatch::IntegrationTest, after the end of the class that
      # holds Templates::TEST_HELPER_MARKER, together with the require of
      # its file; "" when the marker or that end is not there.
      def self.helper_with_session(source)
        at = source.index("#{Templates::TEST_HELPER_MARKER}\n")
        return "" if at.nil?

        stop = source.index("\nend\n", at)
        return "" if stop.nil?

        cut = stop + 5
        out = +""
        out << source[0, cut].to_s
        out << "\nrequire_relative \"support/session_test_helper\"\n\n"
        out << TEST_HELPER_INCLUDE
        out << source[cut, source.size - cut].to_s
        out
      end

      # The helper every test file requires (`require "test_helper"`).
      TEST_HELPER = "test/test_helper.rb"

      # test/test_helper.rb (Templates.test_helper, written when missing, as
      # in an application 0.4 generated) gets SessionTestHelper included into
      # ActionDispatch::IntegrationTest, once; a helper without the marker
      # is left alone with the lines to add.
      def self.add_session_helper(result, root)
        path = File.join(root, TEST_HELPER)
        unless File.exist?(path)
          Templates.write(root, TEST_HELPER, Templates.test_helper)
          result.created << TEST_HELPER
        end
        source = File.read(path)
        unless source.index("include SessionTestHelper").nil?
          puts "identical #{TEST_HELPER} (includes SessionTestHelper)"
          return nil
        end

        changed = helper_with_session(source)
        if changed.empty?
          puts "skip #{TEST_HELPER} (no `#{Templates::TEST_HELPER_MARKER.strip}` line): add require_relative \"support/session_test_helper\""
          puts "  and #{TEST_HELPER_INCLUDE.gsub("\n", "; ").delete_suffix("; ")} to it"
          return nil
        end

        File.write(path, changed)
        puts "insert #{TEST_HELPER} (include SessionTestHelper)"
        nil
      end

      # Phase 4b's (and 0.4's) test files that the class-form ones replace
      # (TEST_FILES_REPLACED), where they exist: named in result.manual, or
      # with `force` deleted (result.removed). They would otherwise run in
      # `cybertrain test` beside the new ones, each defining its own
      # top-level new_client, which the bundle refuses.
      def self.record_replaced_tests(result, root, force)
        if File.exist?(File.join(root, "test/support/app_test.rb"))
          app_test_users(root).each do |user|
            puts "note   #{user} uses test/support/app_test.rb (AppTest), which test/test_helper.rb replaces: " \
                 "move it to the class form (require \"test_helper\", sign_in_as users(:one)) before deleting it"
          end
        end
        TEST_FILES_REPLACED.each do |pair|
          old = pair[0]
          path = File.join(root, old)
          next unless File.exist?(path)

          if force
            File.delete(path)
            puts "remove  #{old} (replaced by #{pair[1]})"
            result.removed << old
          else
            puts "manual  #{old} (replaced by #{pair[1]})"
            result.manual << "manual  #{old}: replaced by #{pair[1]}; delete it\n"
          end
        end
        nil
      end

      # The test files (other than TEST_FILES_REPLACED) that require
      # test/support/app_test.rb or call AppTest: an application's own tests
      # written in phase 4b's shape, which lose their helper with it.
      def self.app_test_users(root)
        replaced = Array.new(0) { "" }
        TEST_FILES_REPLACED.each { |pair| replaced << pair[0] }
        out = Array.new(0) { "" }
        Dir.glob(File.join(root, "test/**/*.rb")).sort.each do |path|
          rel = path.delete_prefix("#{root}/")
          next if replaced.include?(rel)

          text = File.read(path)
          out << rel unless text.index("support/app_test").nil? && text.index("AppTest").nil?
        end
        out
      end

      # The earlier generator's top-level-form attachment tests
      # (test/attachment_<model>_<field>.rb) that sign nobody in: named by
      # add_sign_in_to_attachment_tests, never rewritten.
      def self.unsigned_attachment_tests(root)
        out = Array.new(0) { "" }
        Dir.glob(File.join(root, "test/attachment_*.rb")).sort.each do |path|
          out << "test/#{File.basename(path)}" if File.read(path).index("/session").nil?
        end
        out
      end

      # A scaffold's controller test written before this generator ran
      # (Templates.controller_test: `  setup do` then `    @x = xs(:one)`)
      # meets the sign-in page at every action now: it signs in first,
      # once. Any other controller test is left as it is.
      def self.add_sign_in_to_controller_tests(root)
        Dir.glob(File.join(root, "test/controllers/*_controller_test.rb")).sort.each do |path|
          source = File.read(path)
          next unless source.index(SIGN_IN_LINE).nil?

          at = source.index("\n#{TEST_SETUP_LINE}\n")
          next if at.nil?

          line_at = at + TEST_SETUP_LINE.size + 2
          stop = source.index("\n", line_at)
          next if stop.nil?
          next unless Templates.scaffold_setup_line?(source[line_at, stop - line_at].to_s)

          File.write(path, insert_after_line(source, "#{TEST_SETUP_LINE}\n", SIGN_IN_LINE))
          puts "insert test/controllers/#{File.basename(path)} (sign_in_as users(:one))"
        end
        nil
      end

      # ---- the test files ---------------------------------------------

      # test/models/user_test.rb: the address User accepts.
      def self.user_model_test
        <<~'RUBY'
          # The User model's address check (cybertrain generate authentication).
          require "test_helper"

          class UserTest < ActiveSupport::TestCase
            # User.email_address_format?: one address, whatever the mail
            # standards allow beyond that.
            test "an address is one address: one @, nothing around it that splits it" do
              ["ann@example.com", "ann+news@example.com", "ann.lee+news@mail.example.co.jp", "a@b", "o'brien@example.com"].each do |address|
                assert User.email_address_format?(address), address
              end
              ["", "ann", "@example.com", "ann@", "a@b@example.com", "ann@example.com,eve@evil.example",
               "ann@example.com eve@evil.example", "ann @example.com", "<ann@example.com>", "Ann <ann@example.com>",
               "ann@example.com\n", "ann@exa\tmple.com", "\"ann lee\"@example.com",
               "ann@example.com\u00A0", "ann\u3000@example.com", "ann\u0085@example.com", "ann@exa\u2028mple.com",
               "ann;x@example.com", "ann(x)@example.com", "ann@[example].com", "ann:x@example.com"].each do |address|
                refute User.email_address_format?(address), address
              end
            end

            # An address saved before the check existed (an older release's) is
            # not checked again: its owner can still reset the password.
            test "an address saved before the format check still saves" do
              user = users(:one)
              user.update_columns(email_address: "one@example.com,old@example.com")
              kept = User.find(user.id)
              kept.password = "an0ther-s3cr3t"
              assert kept.save
              kept.email_address = "one@example.com,new@example.com"
              refute kept.save
              assert_includes kept.errors.full_messages, "Email address is invalid"
            end
          end
        RUBY
      end

      # test/controllers/sessions_controller_test.rb; with --invite-only the
      # sign-in page links to no sign-up page.
      def self.sessions_controller_test(invite_only = false)
        link = if invite_only
                 "refute response.body.include?(\"/sign_up\")\n"
               else
                 "assert_includes response.body, \"<a href=\\\"/sign_up\\\">Sign up</a>\"\n"
               end
        open_actions = invite_only ? "sign-in and setup" : "sign-in and sign-up"
        text = sessions_controller_test_body.sub("@OPEN_ACTIONS@", open_actions)
        splice(text, "@SIGN_UP_LINK@", margin(link, 4))
      end

      def self.sessions_controller_test_body
        <<~'RUBY'
          # Signing in and out (cybertrain generate authentication) through the
          # full stack: the session cookie, the router, the Authentication
          # concern, the CSRF check.
          require "test_helper"

          # after_authentication_url is private (the Authentication concern's): a
          # controller made for these tests reads it.
          class ReturnPathProbeController < ApplicationController
            def probe_after_authentication_url
              after_authentication_url
            end
          end

          class SessionsControllerTest < ActionDispatch::IntegrationTest
            # Every action but @OPEN_ACTIONS@ needs a user: DELETE /session is
            # the one such action this test can rely on before the app has pages
            # of its own (a `root` route, a scaffold).
            test "a visitor is sent to the sign-in page" do
              delete "/session"
              assert_redirected_to "/session/new"
              assert_response :see_other
            end

            test "GET /session/new renders the sign-in form" do
              get "/session/new"
              assert_response :ok
              assert_includes response.body, "<h1>Sign in</h1>"
              assert_includes response.body, "<form action=\"/session\" method=\"post\">"
              assert_includes response.body, "name=\"email_address\""
              assert_includes response.body, "type=\"password\" name=\"password\""
              @SIGN_UP_LINK@
            end

            # Every form that signs in, out or resets carries the page's token
            # (Cybertrain's CSRF check, off in tests until with_forgery_protection
            # turns it on): without it, a 403 and nothing done.
            test "POST /session, PUT /passwords/:token and DELETE /session without the form's token are refused" do
              user = users(:one)
              token = user.password_reset_token
              with_forgery_protection do
                post "/session", params: { email_address: "one@example.com", password: "password" }
                assert_response :forbidden
                assert_equal 0, Session.count
                put "/passwords/#{token}", params: { password: "an0ther-s3cr3t", password_confirmation: "an0ther-s3cr3t" }
                assert_response :forbidden
                refute User.find_by_password_reset_token(token).nil?
              end
              # The sign-in form's own token is accepted.
              with_forgery_protection do
                get "/session/new"
                post "/session", params: { authenticity_token: authenticity_token_in(response.body), email_address: "one@example.com", password: "password" }
                assert_redirected_to "/"
              end
              assert_equal 1, Session.count
              with_forgery_protection do
                delete "/session"
                assert_response :forbidden
                assert_equal 1, Session.count
              end
            end

            test "POST /session signs in with the right password" do
              sign_in_as users(:one)
              assert_redirected_to "/"
              assert_response :see_other
              assert_equal 1, Session.count
              assert_equal "127.0.0.1", Session.first.ip_address
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
                        "/\\evil.example/", "/products\\evil", " //evil.example/", "/記事", "/" + "a" * 2048]
              (0..32).each { |byte| unsafe << "/#{Cybertrain::Test.binary([byte])}/evil.example/" }
              unsafe << "/#{Cybertrain::Test.binary([127])}/evil.example/"
              unsafe.each do |path|
                controller.session[:return_to_after_authenticating] = path
                assert_equal "/", controller.probe_after_authentication_url
                refute controller.session.key?(:return_to_after_authenticating)
              end
            end

            test "POST /session with the wrong password shows an alert" do
              post "/session", params: { email_address: "one@example.com", password: "wrong-password" }
              assert_redirected_to "/session/new"
              follow_redirect!
              assert_includes response.body, "<p class=\"alert\">Try another email address or password.</p>"
              assert_equal 0, Session.count
              post "/session", params: { email_address: "nobody@example.com", password: "password" }
              assert_redirected_to "/session/new"
            end

            # SessionsController's rate_limit: ten attempts per address, then even
            # the right password goes back to the form until the window closes.
            # The counts live in Cybertrain::Cache, in windows aligned to the
            # epoch: travel_to holds the clock still, so the attempts share one
            # window, then travel moves it a whole window on. The ten go to an
            # address no user has: the limit counts per client, whatever the
            # address, and there is no account for lockout
            # (test/integration/lockout_test.rb) to lock.
            test "POST /session past ten attempts is refused for a while" do
              travel_to(Time.at(2_000_000_000)) do
                wrong_password = { email_address: "nobody@example.com", password: "wrong-password" }
                right_password = { email_address: "one@example.com", password: "password" }
                10.times { post "/session", params: wrong_password }
                post "/session", params: right_password
                assert_redirected_to "/session/new"
                assert_equal 0, Session.count
                follow_redirect!
                assert_includes response.body, "<p class=\"alert\">Try again later.</p>"
                travel 3.minutes
                post "/session", params: right_password
                assert_redirected_to "/"
                assert_equal 1, Session.count
              end
            end

            test "DELETE /session signs out and drops the Session row" do
              sign_in_as users(:one)
              sign_out
              assert_redirected_to "/session/new"
              assert_equal 0, Session.count
              follow_redirect!
              assert_includes response.body, "<p class=\"notice\">You have been signed out.</p>"
              assert_includes response.body, "<a href=\"/session/new\">Sign in</a>"
            end

            test "a session the database no longer has signs the browser out" do
              sign_in_as users(:one)
              Session.all.delete_all
              delete "/session"
              assert_redirected_to "/session/new"
            end

            test "changing the password signs out the sessions started before" do
              user = users(:one)
              sign_in_as user
              get "/session/new"
              assert_includes response.body, "<span>one@example.com</span>"
              user.password = "another-s3cr3t"
              user.save!
              get "/session/new"
              refute response.body.include?("<span>one@example.com</span>")
              assert_equal 0, Session.count
              post "/session", params: { email_address: "one@example.com", password: "another-s3cr3t" }
              get "/session/new"
              assert_includes response.body, "<span>one@example.com</span>"
            end

            # The Session row's own limit, apart from the cookie's: signed in for
            # two minutes, then the limit lowered to one, so that a minute later
            # the cookie is still within its own two (SessionStore keeps it) and
            # only the row's check can end the sign-in. The row is saved at that
            # moment, which moves its updated_at: neither that nor a rewritten
            # cookie extends authentication (the limit counts from created_at).
            test "an expired cookie cannot restore its user or reach a protected action" do
              max_age = Cybertrain.config.session_absolute_max_age
              begin
                freeze_time
                Cybertrain.config.session_absolute_max_age = 120
                sign_in_as users(:one)
                name = Cybertrain.config.session_cookie_name
                cookie = "#{name}=#{cookies[name]}"
                get "/session/new", headers: { "cookie" => cookie }
                assert_includes response.body, "<span>one@example.com</span>"

                Cybertrain.config.session_absolute_max_age = 60
                travel 1.minute
                row = Session.first
                row.user_agent = "saved at the limit"
                row.save!
                assert_equal Time.current.to_i, Session.first.updated_at.to_i
                get "/session/new", headers: { "cookie" => cookie }
                refute response.body.include?("<span>one@example.com</span>")
                assert_equal 0, Session.count
                delete "/session", headers: { "cookie" => cookie }
                assert_redirected_to "/session/new"
                get "/session/new"
                refute response.body.include?("<span>one@example.com</span>")
                assert_includes response.body, "<a href=\"/session/new\">Sign in</a>"

                # Replaying the original credential again still fails, even
                # after the server removed its id from the browser's cookie.
                get "/session/new", headers: { "cookie" => cookie }
                refute response.body.include?("<span>one@example.com</span>")
              ensure
                Cybertrain.config.session_absolute_max_age = max_age
              end
            end

          end
        RUBY
      end

      # test/controllers/registrations_controller_test.rb (the sign-up
      # page; not --invite-only). With `confirmable` the first test's
      # sign-up signs nobody in (the mail it sends is
      # confirmations_controller_test.rb's).
      def self.registrations_controller_test(confirmable = false)
        text = registrations_controller_test_body
        splice(text, "@SIGN_UP_TEST@", margin(confirmable ? sign_up_confirm_test : sign_up_sign_in_test, 2))
      end

      def self.registrations_controller_test_body
        <<~'RUBY'
          # Signing up (cybertrain generate authentication): the form, the
          # address and password checks, and the rate limit.
          require "test_helper"

          class RegistrationsControllerTest < ActionDispatch::IntegrationTest
            @SIGN_UP_TEST@

            test "POST /sign_up with a short or mismatched password re-renders the form" do
              assert_no_difference(-> { User.count }) do
                post "/sign_up", params: { user: { email_address: "ann@example.com", password: "short", password_confirmation: "other" } }
              end
              assert_response :unprocessable_entity
              assert_includes response.body, "<li>Password is too short (minimum is 8 characters)</li>"
              assert_includes response.body, "<li>Password confirmation doesn&#39;t match Password</li>"
              post "/sign_up", params: { user: { email_address: "ann@example.com", password: "", password_confirmation: "" } }
              assert_includes response.body, "<li>Password can&#39;t be blank</li>"
            end

            # One address only: Cybertrain::Mailer reads a comma as a second
            # recipient, so the account would have two mailboxes. Nor any address
            # the mailer would refuse (Cybertrain::Mailer.address_problem: a
            # Unicode space or control character, ";", "(" and the like), which
            # could never be sent its mails.
            test "POST /sign_up refuses an address list or a malformed address" do
              assert_no_difference(-> { User.count }) do
                ["ann@example.com,eve@evil.example", "ann@example.com eve@evil.example", "<ann@example.com>", "ann", "@example.com", "ann@", "a@b@example.com",
                 "ann@example.com\u00A0", "ann\u3000@example.com", "ann\u0085@example.com", "ann@exa\u2028mple.com", "ann;x@example.com", "ann(x)@example.com"].each do |address|
                  Cybertrain::RateLimit.reset_all!
                  post "/sign_up", params: { user: { email_address: address, password: "s3cr3t-s3cr3t", password_confirmation: "s3cr3t-s3cr3t" } }
                  assert_response :unprocessable_entity
                  assert_includes response.body, "<li>Email address is invalid</li>"
                end
              end
              assert_equal 0, Session.count
              # A plus-address is one address the mailer sends to.
              Cybertrain::RateLimit.reset_all!
              assert_difference(-> { User.count }, 1) do
                post "/sign_up", params: { user: { email_address: "ann+news@example.com", password: "s3cr3t-s3cr3t", password_confirmation: "s3cr3t-s3cr3t" } }
              end
              assert_equal "ann+news@example.com", User.last.email_address
            end

            # RegistrationsController's rate_limit: ten sign-ups per client
            # address, then the form again until the window closes (the clock
            # held still by travel_to, as in POST /session's test). The ten send no
            # password, so none of them costs a hash.
            test "POST /sign_up past ten requests is refused for a while" do
              travel_to(Time.at(2_000_000_000)) do
                empty = { user: { email_address: "nobody@example.com", password: "", password_confirmation: "" } }
                right = { user: { email_address: "ann@example.com", password: "s3cr3t-s3cr3t", password_confirmation: "s3cr3t-s3cr3t" } }
                10.times { post "/sign_up", params: empty }
                assert_no_difference(-> { User.count }) do
                  post "/sign_up", params: right
                end
                assert_redirected_to "/sign_up"
                follow_redirect!
                assert_includes response.body, "<p class=\"alert\">Try again later.</p>"
                travel 3.minutes
                assert_difference(-> { User.count }, 1) do
                  post "/sign_up", params: right
                end
              end
            end

            test "an email address can be registered once" do
              assert_no_difference(-> { User.count }) do
                post "/sign_up", params: { user: { email_address: "ONE@example.com", password: "another-one", password_confirmation: "another-one" } }
              end
              assert_response :unprocessable_entity
              assert_includes response.body, "<li>Email address has already been taken</li>"
            end
          end
        RUBY
      end

      def self.sign_up_sign_in_test
        <<~'RUBY'
          test "POST /sign_up creates the user and signs them in" do
            assert_difference(-> { User.count }, 1) do
              post "/sign_up", params: { user: { email_address: " Ann@Example.com ", password: "s3cr3t-s3cr3t", password_confirmation: "s3cr3t-s3cr3t" } }
            end
            assert_redirected_to "/"
            user = User.last
            assert_equal "ann@example.com", user.email_address
            assert user.password_digest.start_with?("$pbkdf2-sha256$")
            assert_equal 1, Session.count
            get "/session/new"
            assert_includes response.body, "<span>ann@example.com</span>"
            assert_includes response.body, "Sign out"
          end
        RUBY
      end

      # --confirmable's: the user, unconfirmed, and no session.
      def self.sign_up_confirm_test
        <<~'RUBY'
          # --confirmable: nobody is signed in until the address is confirmed
          # (confirmations_controller_test.rb follows the mail's link).
          test "POST /sign_up creates the user and asks them to confirm the address" do
            assert_difference(-> { User.count }, 1) do
              post "/sign_up", params: { user: { email_address: " Ann@Example.com ", password: "s3cr3t-s3cr3t", password_confirmation: "s3cr3t-s3cr3t" } }
            end
            assert_redirected_to "/session/new"
            user = User.last
            assert_equal "ann@example.com", user.email_address
            assert user.password_digest.start_with?("$pbkdf2-sha256$")
            assert_equal false, user.confirmed?
            assert_equal 0, Session.count
            follow_redirect!
            refute response.body.include?("<span>ann@example.com</span>")
            assert_includes response.body, "<a href=\"/session/new\">Sign in</a>"
          end
        RUBY
      end

      # test/integration/first_run_test.rb (--invite-only): /setup, the
      # boot warning and `./<app> user`.
      def self.first_run_test(app)
        first_run_test_body.gsub("@APP@", app).gsub("@SETUP_ENV@", setup_env(app))
      end

      def self.first_run_test_body
        <<~'RUBY'
          # The first run of an invitation-only application (cybertrain generate
          # authentication --invite-only): /setup, the first user's page, only from
          # this machine and with the token the boot warning prints, while no user
          # exists; then `./@APP@ user`.
          require "test_helper"
          require_relative "../../app/commands/user_command"

          class FirstRunTest < ActionDispatch::IntegrationTest
            # /setup answers only while no user exists: these tests start without
            # the fixtures' users.
            setup do
              User.all.delete_all
            end

            test "GET /setup with the token shows the form to this machine while no user exists" do
              get setup_link
              assert_response :ok
              assert_includes response.body, "<h1>Set up</h1>"
              assert_includes response.body, "<form action=\"/setup\" method=\"post\">"
              assert_includes response.body, "<input type=\"hidden\" name=\"token\" value=\"#{SetupController.setup_token}\">"
              assert_includes response.body, "name=\"user[password_confirmation]\""
            end

            test "/setup without the token, or with a wrong one, is a 404" do
              assert_equal 32, SetupController.setup_token.size
              get "/setup"
              assert_response :not_found
              get "/setup?token="
              assert_response :not_found
              get "/setup?token=0123456789abcdef0123456789abcdef"
              assert_response :not_found
              get "/setup?token=#{SetupController.setup_token}x"
              assert_response :not_found
              refute response.body.include?(SetupController.setup_token)
            end

            test "/setup is a 404 to another machine, through a proxy, and once a user exists" do
              res = browser_at("203.0.113.7").get(setup_link)
              assert_equal 404, res.status
              get setup_link, headers: { "x-forwarded-for" => "203.0.113.7" }
              assert_response :not_found
              get setup_link
              assert_response :ok
              create_user
              get setup_link
              assert_response :not_found
            end

            test "POST /setup from another machine, or without the token, creates nothing" do
              res = browser_at("203.0.113.7").post("/setup", Cybertrain::Test.flatten_params(setup_form("s3cr3t-s3cr3t", "s3cr3t-s3cr3t")))
              assert_equal 404, res.status
              user = { email_address: " Ann@Example.com ", password: "s3cr3t-s3cr3t", password_confirmation: "s3cr3t-s3cr3t" }
              post "/setup", params: { token: "0123456789abcdef0123456789abcdef", user: user }
              assert_response :not_found
              post "/setup", params: { user: user }
              assert_response :not_found
              assert_equal 0, User.count
            end

            test "@SETUP_ENV@ opens /setup to any address with the token until a user exists" do
              browser = browser_at("203.0.113.7")
              Cybertrain.config.set_bool_setting(:setup_open, true)
              res = browser.get(setup_link)
              without = browser.get("/setup")
              Cybertrain.config.set_bool_setting(:setup_open, false)
              assert_equal 200, res.status
              assert_equal 404, without.status
              create_user
              Cybertrain.config.set_bool_setting(:setup_open, true)
              res = browser.get(setup_link)
              Cybertrain.config.set_bool_setting(:setup_open, false)
              assert_equal 404, res.status
            end

            # With forgery protection on, the page's own token is accepted.
            test "POST /setup with the token creates the first user and signs them in" do
              with_forgery_protection do
                get setup_link
                post "/setup", params: { authenticity_token: authenticity_token_in(response.body), token: SetupController.setup_token,
                                         user: { email_address: " Ann@Example.com ", password: "s3cr3t-s3cr3t", password_confirmation: "s3cr3t-s3cr3t" } }
                assert_redirected_to "/"
              end
              assert_equal 1, User.count
              assert_equal "ann@example.com", User.first.email_address
              assert_equal 1, Session.count
              get "/session/new"
              assert_includes response.body, "<span>ann@example.com</span>"
              get setup_link
              assert_response :not_found
            end

            test "POST /setup with a short or mismatched password re-renders the form" do
              post "/setup", params: setup_form("short", "other")
              assert_response :unprocessable_entity
              assert_includes response.body, "<li>Password is too short (minimum is 8 characters)</li>"
              assert_includes response.body, "<li>Password confirmation doesn&#39;t match Password</li>"
              assert_includes response.body, "<input type=\"hidden\" name=\"token\" value=\"#{SetupController.setup_token}\">"
              assert_equal 0, User.count
            end

            test "./@APP@ user creates a user, then sets its password" do
              assert_equal 0, run_command(["user", "Bob@Example.com", "s3cr3t-s3cr3t"])
              assert_equal 1, User.count
              assert_equal "bob@example.com", User.first.email_address
              assert User.first.authenticate("s3cr3t-s3cr3t")
              assert_equal 0, run_command(["user", "bob@example.com", "another-s3cr3t"])
              assert_equal 1, User.count
              assert User.first.authenticate("another-s3cr3t")
              refute User.first.authenticate("s3cr3t-s3cr3t")
            end

            test "POST /setup and ./@APP@ user refuse an address list or a malformed address" do
              post "/setup", params: { token: SetupController.setup_token,
                                       user: { email_address: "ann@example.com,eve@evil.example", password: "s3cr3t-s3cr3t", password_confirmation: "s3cr3t-s3cr3t" } }
              assert_response :unprocessable_entity
              assert_includes response.body, "<li>Email address is invalid</li>"
              assert_equal 0, User.count
              assert_equal 1, run_command(["user", "ann@example.com,eve@evil.example", "s3cr3t-s3cr3t"])
              assert_equal 1, run_command(["user", "ann", "s3cr3t-s3cr3t"])
              assert_equal 0, User.count
            end

            test "./@APP@ user refuses bad arguments and an empty or short password" do
              assert_equal 1, run_command(["user"])
              assert_equal 1, run_command(["user", "ann@example.com", "s3cr3t-s3cr3t", "extra"])
              assert_equal 1, run_command(["user", "--help"])
              assert_equal 1, run_command(["user", "ann@example.com", ""])
              assert_equal 1, run_command(["user", "ann@example.com", "short"])
              assert_equal 0, User.count
            end

            test "a password read from standard input loses one trailing newline" do
              assert_equal "s3cr3t s3cr3t", UserCommand.password_from("s3cr3t s3cr3t\n")
              assert_equal "s3cr3t", UserCommand.password_from("s3cr3t\r\n")
              assert_equal "s3cr3t\n", UserCommand.password_from("s3cr3t\n\n")
              assert_equal "", UserCommand.password_from("")
            end

            test "the boot warning is due while no user exists" do
              assert UserCommand.no_user?
              reconnect
              create_user
              refute UserCommand.no_user?
              reconnect
            end

            private

            # The form /setup posts, filled in, with the page's one-time token in
            # its hidden field.
            def setup_form(password, confirmation)
              { token: SetupController.setup_token,
                user: { email_address: " Ann@Example.com ", password: password, password_confirmation: confirmation } }
            end

            # /setup with this process's token, the link the boot warning prints.
            def setup_link
              "/setup?token=#{SetupController.setup_token}"
            end

            # A browser on another machine: the test's own requests come from
            # 127.0.0.1, and an integration test cannot change that, so this one
            # is a Cybertrain::Test::Client (its responses are checked by status).
            def browser_at(address)
              browser = Cybertrain::Test::Client.new(Cybertrain::Test.app)
              browser.peer_address = address
              browser
            end

            # The first user, made as the user command makes one.
            def create_user
              user = User.new(email_address: "ann@example.com")
              user.password = "s3cr3t-s3cr3t"
              user.save!
              nil
            end

            # `./@APP@ ARGS...` in-process. Main.run connects a pool of one for
            # the command and disconnects it, so the tests' pool is connected
            # again afterwards (the database file is the same).
            def run_command(argv)
              status = Cybertrain::Main.run("@APP@", argv, router: Gen::Routes.build(Cybertrain::Router.new),
                                                         url_resolver: Gen::Routes.url_resolver,
                                                         views: Cybertrain::Application.no_views)
              reconnect
              status
            end

            def reconnect
              Cybertrain::DB.connect(Cybertrain.config.database_path, size: Cybertrain.config.pool_size)
              nil
            end
          end
        RUBY
      end

      # test/integration/admin_test.rb: the admin flag, require_admin
      # (through the jobs page config/routes.rb draws behind it) and the
      # user command's admin and unadmin.
      def self.admin_integration_test(app)
        <<~'RUBY'.gsub("@APP@", app)
          # The admin flag (cybertrain generate authentication): User#admin?,
          # require_admin (the Authentication concern's before_action, which the
          # jobs page in config/routes.rb names) and `./@APP@ user admin EMAIL`.
          require "test_helper"
          require_relative "../../app/commands/user_command"

          # require_admin is private (the Authentication concern's): a controller
          # made for this test calls it, as a before_action would.
          class AdminProbeController < ApplicationController
            def probe_require_admin
              require_admin
            end
          end

          class AdminTest < ActionDispatch::IntegrationTest
            test "user.admin? is false for a new user" do
              user = User.new(email_address: "new@example.com")
              user.password = "s3cr3t-s3cr3t"
              user.save!
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
              get "/admin/jobs"
              assert_response :not_found
              assert_equal "Not Found", response.body
              # Signed in, not an admin: 404, as if there were no such page; the
              # same body and type as a path no route has.
              user = users(:two)
              sign_in_as user
              get "/admin/jobs"
              assert_response :not_found
              assert_equal "Not Found", response.body
              refute response.body.include?("<h1>Jobs</h1>")
              jobs = response
              get "/admin/no-such-page"
              assert_response :not_found
              assert_equal response.body, jobs.body
              assert_equal response.header("content-type"), jobs.header("content-type")
              # Made an admin, the same browser sees the page.
              user.admin = true
              user.save!
              get "/admin/jobs"
              assert_response :ok
              assert_includes response.body, "<h1>Jobs</h1>"
              # And no more once that is taken back.
              user.admin = false
              user.save!
              get "/admin/jobs"
              assert_response :not_found
            end

            # users(:two) is not an admin; users(:one) is, and stays so.
            test "./@APP@ user admin and unadmin print what they did" do
              two = users(:two)
              assert_equal "admin two@example.com", UserCommand.admin_change("Two@Example.com", true)
              assert_equal true, User.find(two.id).admin?
              assert_equal "unadmin two@example.com", UserCommand.admin_change("two@example.com", false)
              assert_equal false, User.find(two.id).admin?
              assert_equal "error: no user bob@example.com", UserCommand.admin_change("bob@example.com", true)
              assert_equal 2, User.count
            end

            test "./@APP@ user admin and unadmin set the flag of an existing user" do
              two = users(:two)
              assert_equal 0, UserCommand.run(["admin", "Two@Example.com"])
              assert_equal true, User.find(two.id).admin?
              assert_equal 0, UserCommand.run(["unadmin", "two@example.com"])
              assert_equal false, User.find(two.id).admin?
              assert_equal 1, UserCommand.run(["admin", "bob@example.com"])
              assert_equal 1, UserCommand.run(["admin"])
              assert_equal 1, UserCommand.run(["unadmin", "two@example.com", "extra"])
              assert_equal 2, User.count
              assert_equal false, User.find(two.id).admin?
            end
          end
        RUBY
      end

      # test/integration/remember_me_test.rb: how long a sign-in lasts,
      # remembered or not, and the idle limit, with the clock moved by
      # travel_to (the cookie's own limit is the framework's test/session.rb).
      def self.remember_me_integration_test
        <<~'RUBY'
          # "Keep me signed in" and the idle limit (cybertrain generate
          # authentication): a sign-in lasts session_absolute_max_age (two weeks)
          # unless the box was checked (auth_remember_for, 30 days), and ends
          # either way after auth_idle_timeout (7 days) without a request. The
          # tests move the clock with travel_to rather than wait; it is frozen
          # first, so that `15.days.from_now` is fifteen days after the sign-in.
          # A session meant to live is used every six days, inside the idle limit.
          require "test_helper"

          # start_new_session_for is private (the Authentication concern's): a
          # controller made for these tests calls it, as an action would.
          class LifetimeProbeController < ApplicationController
            def probe_start(user, remember)
              start_new_session_for(user, remember: remember)
            end
          end

          class RememberMeTest < ActionDispatch::IntegrationTest
            setup do
              freeze_time
            end

            # A cookie that already carries a start (a browser that signed in
            # before, or the account page's restart after a new password, on day
            # 13 of its sign-in) starts again: SessionStore stamps this request's
            # time, so the new sign-in gets its whole limit.
            test "a sign-in restarts the lifetime of a cookie that already has one" do
              ctx = Cybertrain::Context.new(Cybertrain::Request.new("POST", "/session", {}, ""))
              ctx.session = Cybertrain::Session.new
              ctx.session["_issued_at"] = Time.current.to_i - 13.days
              assert ctx.session.issued_at > 0
              LifetimeProbeController.new(ctx).probe_start(users(:one), false)
              assert_equal 0, ctx.session.issued_at
            end

            # Signed in while auth_remember_for is 31 days, then set back to its
            # 30: the cookie holds 31, so on day 30 it is the Session row's own
            # limit that ends the sign-in, and the row is gone.
            test "a remembered session survives day 15 and ends after day 30" do
              remember_for = Cybertrain.config.auth_remember_for
              begin
                Cybertrain.config.auth_remember_for = 31.days
                sign_in_as users(:one), remember: true
                Cybertrain.config.auth_remember_for = remember_for
                assert_redirected_to "/"
                assert_equal true, Session.first.remember
                assert session_cookie_of(response).end_with?("; Max-Age=2678400"), session_cookie_of(response)
                travel_to 6.days.from_now do
                  assert signed_in?
                end
                travel_to 12.days.from_now do
                  assert signed_in?
                end
                travel_to 15.days.from_now do
                  assert signed_in?
                end
                travel_to 21.days.from_now do
                  assert signed_in?
                end
                travel_to 27.days.from_now do
                  assert signed_in?
                end
                cookie = cookie_header
                first = Session.last
                travel_to 30.days.from_now - 1.minute do
                  assert signed_in?
                end
                travel_to 30.days.from_now do
                  refute signed_in?
                  # Ended: the row is gone.
                  assert_nil Session.find_by(id: first.id)
                end
                travel_to 31.days.from_now do
                  refute replayed_signed_in?(cookie)
                end
                # A sign-in whose limit was lowered to 15 days since (the cookie
                # still holds its 30) ends on day 15, its row with it, and a longer
                # limit set afterwards does not bring back a copy of the cookie.
                sign_in_as users(:one), remember: true
                started = Session.last
                cookie = cookie_header
                Cybertrain.config.auth_remember_for = 15.days
                travel_to 6.days.from_now do
                  assert signed_in?
                end
                travel_to 12.days.from_now do
                  assert signed_in?
                end
                travel_to 15.days.from_now do
                  refute signed_in?
                  assert_nil Session.find_by(id: started.id)
                  Cybertrain.config.auth_remember_for = 60.days
                  refute replayed_signed_in?(cookie)
                end
              ensure
                Cybertrain.config.auth_remember_for = remember_for
              end
            end

            test "an unremembered session ends after day 14" do
              sign_in_as users(:one)
              assert_redirected_to "/"
              assert_equal false, Session.first.remember
              travel_to 6.days.from_now do
                assert signed_in?
              end
              travel_to 12.days.from_now do
                assert signed_in?
              end
              travel_to 14.days.from_now - 1.minute do
                assert signed_in?
              end
              travel_to 14.days.from_now do
                refute signed_in?
              end
              # Day 15, where a remembered one is alive.
              sign_in_as users(:one)
              travel_to 6.days.from_now do
                assert signed_in?
              end
              travel_to 12.days.from_now do
                assert signed_in?
              end
              travel_to 15.days.from_now do
                refute signed_in?
              end
            end

            test "an unremembered session still ends with session_absolute_max_age off" do
              absolute = Cybertrain.config.session_absolute_max_age
              max_age = Cybertrain.config.session_max_age
              remember_for = Cybertrain.config.auth_remember_for
              begin
                # Off (0): the limit is session_max_age (two weeks), stamped on
                # the cookie and checked on the row. Signed in while it is 15
                # days (the cookie's stamp), then lowered to 13, so that the
                # cookie still holds its 15 on day 13 and the row's check alone
                # ends the sign-in (13 days: not the two-week constant).
                Cybertrain.config.session_absolute_max_age = 0
                Cybertrain.config.session_max_age = 15.days
                user = users(:one)
                assert_equal 1_296_000, stamped_session(user, false).lifetime_limit
                sign_in_as user
                assert_redirected_to "/"
                started = Session.last
                Cybertrain.config.session_max_age = 13.days
                refute session_cookie_of(response).empty?
                refute session_cookie_of(response).include?("Max-Age")
                travel_to 6.days.from_now do
                  assert signed_in?
                end
                travel_to 12.days.from_now do
                  assert signed_in?
                end
                travel_to 13.days.from_now - 1.minute do
                  assert signed_in?
                end
                travel_to 13.days.from_now do
                  refute signed_in?
                  assert_nil Session.find_by(id: started.id)
                end
                # The cookie holds its 15 days: signed in again while it is 15,
                # then raised to 60 for the row, the cookie's own stamp ends the
                # sign-in on day 15 (a browser-session cookie, sent all along).
                Cybertrain.config.session_max_age = 15.days
                sign_in_as user
                started = Session.last
                Cybertrain.config.session_max_age = 60.days
                travel_to 6.days.from_now do
                  assert signed_in?
                end
                travel_to 12.days.from_now do
                  assert signed_in?
                end
                travel_to 15.days.from_now - 1.minute do
                  assert signed_in?
                end
                travel_to 15.days.from_now do
                  refute signed_in?
                  # The row is still there: the cookie alone ended it.
                  refute Session.find_by(id: started.id).nil?
                end
                # The stamp itself: session_max_age as it is (13 days), not the
                # two-week constant.
                Cybertrain.config.session_max_age = 13.days
                stamped = stamped_session(user, false)
                assert_equal 1_123_200, stamped.lifetime_limit
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

            # Used a minute short of seven days after the sign-in, then left
            # alone for seven days: ended (well inside the two weeks of an
            # unremembered sign-in).
            test "seven idle days end a session" do
              [true, false].each do |remember|
                sign_in_as users(:one), remember: remember
                started = Session.last
                travel_to 7.days.from_now - 1.minute do
                  assert signed_in?
                end
                cookie = cookie_header
                travel_to 14.days.from_now - 1.minute do
                  refute signed_in?
                  # Ended: the row is gone, so turning the idle limit off
                  # afterwards does not bring back a copy of the cookie.
                  assert_nil Session.find_by(id: started.id)
                  idle = Cybertrain.config.auth_idle_timeout
                  begin
                    Cybertrain.config.auth_idle_timeout = 0
                    refute replayed_signed_in?(cookie)
                  ensure
                    Cybertrain.config.auth_idle_timeout = idle
                  end
                end
              end
              # A row with no last_active_at is idle since created_at.
              sign_in_as users(:one), remember: true
              started = Session.last
              started.update_columns(last_active_at: nil)
              travel_to 7.days.from_now - 1.minute do
                assert signed_in?
                refute Session.find(started.id).last_active_at.nil?
              end
              Session.find(started.id).update_columns(last_active_at: nil)
              travel_to 7.days.from_now do
                refute signed_in?
                assert_nil Session.find_by(id: started.id)
              end
              # auth_idle_timeout 0: no idle limit, the absolute one alone (on
              # the row: lowered to 29 days after the sign-in, while the cookie
              # holds its 30).
              idle = Cybertrain.config.auth_idle_timeout
              remember_for = Cybertrain.config.auth_remember_for
              begin
                Cybertrain.config.auth_idle_timeout = 0
                sign_in_as users(:one), remember: true
                started = Session.last
                Cybertrain.config.auth_remember_for = 29.days
                travel_to 29.days.from_now - 1.minute do
                  assert signed_in?
                end
                travel_to 29.days.from_now do
                  refute signed_in?
                  assert_nil Session.find_by(id: started.id)
                end
              ensure
                Cybertrain.config.auth_idle_timeout = idle
                Cybertrain.config.auth_remember_for = remember_for
              end
            end

            test "last_active_at is touched at most once a minute" do
              before = Time.current.to_i
              sign_in_as users(:one)
              started = Session.first.last_active_at
              refute started.nil?
              assert started.to_i >= before
              # Used 30 seconds later: a request does not write the row.
              travel 30.seconds
              updated_at = Session.first.updated_at.to_i
              assert signed_in?
              assert_equal before, Session.first.last_active_at.to_i
              # 61 seconds after the last write: the request moves it to now, and
              # leaves updated_at alone.
              travel 31.seconds
              assert signed_in?
              assert_equal before + 61, Session.first.last_active_at.to_i
              assert_equal updated_at, Session.first.updated_at.to_i
            end

            test "an unremembered sign-in sets a cookie without Max-Age" do
              sign_in_as users(:one)
              assert_redirected_to "/"
              cookie = session_cookie_of(response)
              refute cookie.empty?
              refute cookie.include?("Max-Age")
              refute cookie.include?("Expires")
              # The box checked, the same cookie lasts auth_remember_for.
              sign_in_as users(:one), remember: true
              cookie = session_cookie_of(response)
              assert cookie.end_with?("; Max-Age=2592000"), cookie
              refute cookie.include?("Expires")
            end

            private

            # Whether this browser is signed in: the nav names the user.
            def signed_in?
              get "/session/new"
              response.body.include?("<span>one@example.com</span>")
            end

            # The session cookie this browser holds now, as a request header.
            def cookie_header
              name = Cybertrain.config.session_cookie_name
              "#{name}=#{cookies[name]}"
            end

            # Whether a copy of an old cookie (kept by whoever had it) signs in.
            def replayed_signed_in?(cookie)
              get "/session/new", headers: { "cookie" => cookie }
              response.body.include?("<span>one@example.com</span>")
            end

            # The Set-Cookie line of the session cookie in res ("" when none).
            def session_cookie_of(res)
              prefix = "#{Cybertrain.config.session_cookie_name}="
              found = ""
              res.cookies.each { |line| found = line if line.start_with?(prefix) }
              found
            end

            # The cookie session start_new_session_for leaves for user.
            def stamped_session(user, remember)
              ctx = Cybertrain::Context.new(Cybertrain::Request.new("POST", "/session", {}, ""))
              ctx.session = Cybertrain::Session.new
              LifetimeProbeController.new(ctx).probe_start(user, remember)
              ctx.session
            end
          end
        RUBY
      end

      # test/integration/lockout_test.rb: auth_lockout_attempts wrong
      # passwords lock the account for an hour (travel moves past it), the
      # lock answers as a wrong password does, and a successful sign-in
      # clears the count.
      def self.lockout_integration_test
        <<~'RUBY'
          # Account lockout (cybertrain generate authentication):
          # auth_lockout_attempts (10) wrong passwords in a row lock the account
          # for auth_lockout_period (an hour); while it is locked even the right
          # password gets the wrong-password message; a successful sign-in clears
          # the count. SessionsController's rate_limit (ten attempts per address
          # in three minutes) would answer the eleventh attempt first, so every
          # attempt here forgets its counts (Cybertrain::RateLimit.reset_all!).
          require "test_helper"
          require_relative "../../app/commands/user_command"

          class LockoutTest < ActionDispatch::IntegrationTest
            WRONG = "<p class=\"alert\">Try another email address or password.</p>"

            setup do
              @user = users(:one)
            end

            test "10 failures lock the account for an hour with the wrong-password message" do
              assert_equal 0, @user.failed_attempts
              9.times do |i|
                attempt_sign_in("wrong-password")
                assert_includes response.body, WRONG
                assert_equal i + 1, User.find(@user.id).failed_attempts
                assert_nil User.find(@user.id).locked_until
                refute User.find(@user.id).locked?
              end
              before = Time.current.to_i
              attempt_sign_in("wrong-password")
              after = Time.current.to_i
              assert_includes response.body, WRONG
              locked = User.find(@user.id)
              assert locked.locked?
              refute locked.locked_until.nil?
              assert locked.locked_until.to_i >= before + 3600
              assert locked.locked_until.to_i <= after + 3600
              assert_equal 0, locked.failed_attempts
              assert_equal 0, Session.count
            end

            test "ten failures lock the account until the hour passes" do
              freeze_time
              lock_out("one@example.com")
              ends = User.find(@user.id).locked_until.to_i
              # The eleventh attempt, the right password: the rate limit's counts
              # are forgotten, so it is the lock that answers, with the
              # wrong-password message.
              Cybertrain::RateLimit.reset_all!
              sign_in_as @user
              assert_redirected_to "/session/new"
              follow_redirect!
              assert_includes response.body, WRONG
              refute response.body.include?("Try again later.")
              assert_equal 0, Session.count
              # Refused while locked, neither counted nor extended.
              assert_equal 0, User.find(@user.id).failed_attempts
              assert_equal ends, User.find(@user.id).locked_until.to_i
              # A minute before the hour is over: still refused.
              travel 59.minutes do
                attempt_sign_in("password")
                assert_includes response.body, WRONG
                assert_equal 0, Session.count
              end
              # Once it has passed, the right password signs in and the lock is gone.
              travel 1.hour do
                Cybertrain::RateLimit.reset_all!
                sign_in_as @user
                assert_redirected_to "/"
                assert_equal 1, Session.count
                assert_nil User.find(@user.id).locked_until
                assert_equal 0, User.find(@user.id).failed_attempts
              end
            end

            test "a successful sign-in clears the count" do
              3.times { attempt_sign_in("wrong-password") }
              assert_equal 3, User.find(@user.id).failed_attempts
              Cybertrain::RateLimit.reset_all!
              sign_in_as @user
              assert_redirected_to "/"
              assert_equal 0, User.find(@user.id).failed_attempts
              assert_nil User.find(@user.id).locked_until
              # The count starts again: nine more wrong passwords do not lock.
              9.times { attempt_sign_in("wrong-password") }
              assert_equal 9, User.find(@user.id).failed_attempts
              assert_nil User.find(@user.id).locked_until
              refute User.find(@user.id).locked?
            end

            test "./APP user EMAIL PASSWORD clears a lock" do
              lock_out("one@example.com")
              assert User.find(@user.id).locked?
              assert_equal 0, UserCommand.run(["one@example.com", "an0ther-s3cr3t"])
              assert_nil User.find(@user.id).locked_until
              assert_equal 0, User.find(@user.id).failed_attempts
              Cybertrain::RateLimit.reset_all!
              post "/session", params: { email_address: "one@example.com", password: "an0ther-s3cr3t" }
              assert_redirected_to "/"
              assert_equal 1, Session.count
              # Some failures, no lock: the count is cleared too.
              two = users(:two)
              3.times { attempt_sign_in("wrong-password", "two@example.com") }
              assert_equal 0, UserCommand.run(["two@example.com", "an0ther-s3cr3t"])
              assert_equal 0, User.find(two.id).failed_attempts
            end

            test "with auth_lockout_attempts 0 an existing lock is not enforced" do
              lock_out("one@example.com")
              attempts = Cybertrain.config.auth_lockout_attempts
              begin
                Cybertrain.config.auth_lockout_attempts = 0
                # Lockout off: the lock no longer refuses the right password, and
                # the sign-in clears it.
                refute User.find(@user.id).locked_until.nil?
                Cybertrain::RateLimit.reset_all!
                sign_in_as @user
                assert_redirected_to "/"
                assert_equal 1, Session.count
                assert_nil User.find(@user.id).locked_until
              ensure
                Cybertrain.config.auth_lockout_attempts = attempts
              end
              # Lockout on again, a lock is enforced (made afresh, on two).
              two = users(:two)
              lock_out("two@example.com")
              Cybertrain::RateLimit.reset_all!
              sign_in_as two
              assert_redirected_to "/session/new"
              assert_equal 0, Session.where(user_id: two.id).count
            end

            test "auth_lockout_attempts 0 never locks" do
              attempts = Cybertrain.config.auth_lockout_attempts
              begin
                Cybertrain.config.auth_lockout_attempts = 0
                11.times { attempt_sign_in("wrong-password") }
                assert_equal 0, User.find(@user.id).failed_attempts
                assert_nil User.find(@user.id).locked_until
                Cybertrain::RateLimit.reset_all!
                sign_in_as @user
                assert_redirected_to "/"
                assert_equal 1, Session.count
              ensure
                Cybertrain.config.auth_lockout_attempts = attempts
              end
            end

            private

            # One sign-in attempt through the form, the rate limit's counts
            # forgotten first; the page the redirect leads to is the response.
            def attempt_sign_in(password, email_address = "one@example.com")
              Cybertrain::RateLimit.reset_all!
              post "/session", params: { email_address: email_address, password: password }
              assert_response :see_other
              follow_redirect!
              nil
            end

            # Ten wrong passwords: the account is locked.
            def lock_out(email_address)
              10.times { attempt_sign_in("wrong-password", email_address) }
              nil
            end
          end
        RUBY
      end

      # Stands for the app's base_url variable in the tests' texts.
      BASE_URL_ENV_MARK = "@BASE_URL_ENV@"

      # The private with_config helper (and NO_HOSTS) of the tests that
      # change the environment, the hosts and the base_url setting, each
      # line indented for a class body.
      def self.with_config_helper
        margin(<<~'RUBY', 2)
          # Runs the block with Config#env, hosts_from_env and the base_url
          # setting given (and Cybertrain.logger writing errors to log, unless
          # it is nil), then puts them back, also when the block fails.
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

          # The first http:// or https:// link in the text of the last mail
          # sent (Cybertrain::Mailer.deliveries, where the test environment
          # keeps it); "" when none was.
          def last_mail_link
            mail = Cybertrain::Mailer.deliveries.last
            text = mail.nil? ? "" : mail.mail_body
            start = text.index("https://")
            plain = text.index("http://")
            start = plain if start.nil? || (!plain.nil? && plain < start)
            found = ""
            unless start.nil?
              stop = start
              while stop < text.size && text[stop] != " " && text[stop] != "\r" && text[stop] != "\n"
                stop += 1
              end
              found = text[start, stop - start].to_s
            end
            found
          end

          # Whether another browser (open_session) is signed in as
          # email_address: the nav names them.
          def browser_signed_in?(browser, email_address = "one@example.com")
            browser.get "/session/new"
            browser.response.body.include?("<span>#{email_address}</span>")
          end
        RUBY
      end

      # test/controllers/passwords_controller_test.rb: the reset through the
      # stack, its mail from Cybertrain::Mailer.deliveries.
      def self.passwords_controller_test(app)
        text = passwords_controller_test_body.gsub(BASE_URL_ENV_MARK, base_url_env(app))
        splice(text, "@HELPERS@", with_config_helper)
      end

      def self.passwords_controller_test_body
        <<~'RUBY'
          # Password reset (cybertrain generate authentication): the address form,
          # the mail (kept in Cybertrain::Mailer.deliveries, as the test
          # environment does), the link's token (15 minutes, bound to the password
          # and the address) and what a reset ends.
          require "stringio"
          require "test_helper"

          class PasswordsControllerTest < ActionDispatch::IntegrationTest
            SENT = "<p class=\"notice\">If that address is registered, a link to reset the password was sent to it.</p>"
            INVALID = "<p class=\"alert\">That password reset link is invalid or has expired.</p>"
            UPDATED = "<p class=\"notice\">Your password has been reset. Sign in with the new one.</p>"
            NEW_PASSWORD = "n3w-s3cr3t-n3w"
            # with_config's `hosts` for an app that lists none (CYBERTRAIN_HOSTS unset).
            NO_HOSTS = Array.new(0) { "" }

            test "a reset mail is sent once and its link expires after 15 minutes" do
              freeze_time
              assert_emails(1) do
                request_reset("one@example.com")
              end
              assert_redirected_to "/session/new"
              assert_equal "one@example.com", Cybertrain::Mailer.deliveries.last.mail_to
              token = token_in(last_mail_link)
              travel 14.minutes do
                get "/passwords/#{token}/edit"
                assert_response :ok
              end
              travel 16.minutes do
                get "/passwords/#{token}/edit"
                assert_redirected_to "/passwords/new"
                reset_with(token, NEW_PASSWORD)
                assert_redirected_to "/passwords/new"
              end
              assert Cybertrain::Password.verify?("password", User.find(users(:one).id).password_digest)
            end

            test "reset answers the same for unknown addresses and links to base_url" do
              with_config("test", NO_HOSTS, "https://shop.example") do
                # A forged Host on both: the link takes base_url, never the header.
                request_reset("One@Example.com", "evil.example")
                known = response
                follow_redirect!
                known_page = response.body
                assert_enqueued_jobs 1, "cybertrain mail"
                request_reset("nobody@example.com", "evil.example")
                unknown = response
                assert_equal 303, known.status
                assert_equal known.status, unknown.status
                assert_equal "/session/new", known.header("Location")
                assert_equal known.header("Location"), unknown.header("Location")
                assert_equal known.body, unknown.body
                follow_redirect!
                assert_includes known_page, SENT
                assert_includes response.body, SENT
                # One mail, for the registered address only.
                assert_enqueued_jobs 1, "cybertrain mail"
              end
              assert_equal 1, perform_enqueued_jobs
              link = last_mail_link
              assert link.start_with?("https://shop.example/passwords/"), link
              assert link.end_with?("/edit"), link
              refute link.include?("evil.example")
              # The link works once.
              token = token_in(link)
              get "/passwords/#{token}/edit"
              assert_response :ok
              reset_with(token, NEW_PASSWORD)
              assert_redirected_to "/session/new"
              get "/passwords/#{token}/edit"
              assert_redirected_to "/passwords/new"
            end

            test "without base_url a link takes the request's address only where that is safe" do
              # Tests: the address the request came to.
              with_config("test", NO_HOSTS, "") do
                request_reset("one@example.com", "www.example.com")
              end
              assert_equal 1, perform_enqueued_jobs
              link = last_mail_link
              assert link.start_with?("http://www.example.com/passwords/"), link
              # Development checks the Host header: the request's address.
              with_config("development", NO_HOSTS, "") do
                assert Cybertrain.config.host_check?
                request_reset("one@example.com", "localhost:3000")
                assert_redirected_to "/session/new"
              end
              assert_equal 1, perform_enqueued_jobs
              link = last_mail_link
              assert link.start_with?("http://localhost:3000/passwords/"), link
              # Production with CYBERTRAIN_HOSTS (the Host header is checked): the
              # request's address too.
              with_config("production", ["shop.example"], "") do
                assert Cybertrain.config.host_check?
                request_reset("one@example.com", "shop.example")
                assert_redirected_to "/session/new"
              end
              assert_equal 1, perform_enqueued_jobs
              link = last_mail_link
              assert link.start_with?("http://shop.example/passwords/"), link
              # Production with base_url: base_url, whatever the Host.
              with_config("production", NO_HOSTS, "https://shop.example") do
                request_reset("one@example.com", "evil.example")
                assert_redirected_to "/session/new"
              end
              assert_equal 1, perform_enqueued_jobs
              link = last_mail_link
              assert link.start_with?("https://shop.example/passwords/"), link
              # Production with neither: no mail, an ERROR line, the same answer.
              log = StringIO.new
              with_config("production", NO_HOSTS, "", log) do
                refute Cybertrain.config.host_check?
                request_reset("one@example.com", "evil.example")
                assert_redirected_to "/session/new"
                follow_redirect!
                assert_includes response.body, SENT
              end
              assert_no_enqueued_jobs "cybertrain mail"
              assert_includes log.string, " ERROR "
              assert_includes log.string, "password reset mail not sent: set @BASE_URL_ENV@ (or CYBERTRAIN_HOSTS)\n"
            end

            test "any other environment without base_url sends no mail and answers the same" do
              log = StringIO.new
              # A staging server reached with a forged Host: not production, but
              # nothing checks its Host header either.
              with_config("staging", NO_HOSTS, "", log) do
                refute Cybertrain.config.host_check?
                request_reset("one@example.com", "evil.example")
                known = response
                follow_redirect!
                assert_includes response.body, SENT
                request_reset("nobody@example.com", "evil.example")
                unknown = response
                assert_equal 303, known.status
                assert_equal known.status, unknown.status
                assert_equal "/session/new", known.header("Location")
                assert_equal known.header("Location"), unknown.header("Location")
                assert_equal known.body, unknown.body
                follow_redirect!
                assert_includes response.body, SENT
              end
              assert_no_enqueued_jobs "cybertrain mail"
              assert_includes log.string, " ERROR "
              assert_includes log.string, "password reset mail not sent: set @BASE_URL_ENV@ (or CYBERTRAIN_HOSTS)\n"
              assert log.string.index("evil.example").nil?
            end

            # Such an address is refused at entry now (User.email_address_format?),
            # so this one was saved before that check existed.
            test "an address the mailer refuses gets the same answer, and the log says why" do
              users(:two).update_columns(email_address: "josé@example.com")
              log = StringIO.new
              with_config("test", NO_HOSTS, "https://shop.example", log) do
                request_reset("josé@example.com")
                refused = response
                follow_redirect!
                assert_includes response.body, SENT
                request_reset("nobody@example.com")
                assert_equal 303, refused.status
                assert_equal refused.status, response.status
                assert_equal "/session/new", refused.header("Location")
                assert_equal refused.header("Location"), response.header("Location")
                assert_equal refused.body, response.body
              end
              assert_no_enqueued_jobs "cybertrain mail"
              assert_includes log.string, " ERROR "
              assert_includes log.string, "password reset mail not sent: the to address contains a space, a control character or a non-ASCII byte\n"
            end

            test "the token expires after 15 minutes" do
              user = users(:one)
              now = Time.current.to_i
              assert user.password_reset_token(now).start_with?("#{user.id}--#{now + 15 * 60}--")
              stale = user.password_reset_token(now - 16 * 60)
              fresh = user.password_reset_token(now - 14 * 60)
              assert_nil User.find_by_password_reset_token(stale)
              found = User.find_by_password_reset_token(fresh)
              refute found.nil?
              assert_equal user.id, found.id
              get "/passwords/#{stale}/edit"
              assert_redirected_to "/passwords/new"
              assert_equal "no-referrer", response.header("Referrer-Policy")
              follow_redirect!
              assert_includes response.body, INVALID
              reset_with(stale, NEW_PASSWORD)
              assert_redirected_to "/passwords/new"
              assert_equal "no-referrer", response.header("Referrer-Policy")
              assert_equal user.password_digest, User.find_by(id: user.id).password_digest
              get "/passwords/#{fresh}/edit"
              assert_response :ok
              page = response
              # The page's address holds the token: no Referer leaves it.
              assert_equal "no-referrer", page.header("Referrer-Policy")
              # The address form's page is not the link's.
              get "/passwords/new"
              assert_nil response.header("Referrer-Policy")
              assert_includes page.body, "<form action=\"/passwords/#{fresh}\" method=\"post\"><input type=\"hidden\" name=\"_method\" value=\"put\">"
            end

            test "the token stops working once the password changed" do
              ann = users(:one)
              bob = users(:two)
              token = ann.password_reset_token
              earlier = ann.password_reset_token(Time.current.to_i - 60)
              # A token names its user and is bound to that user's password and
              # address: one with bob's id and ann's binding, ann's id and her
              # password alone, or another purpose, is no one's.
              assert_equal "#{ann.password_digest}:one@example.com", ann.password_reset_binding
              assert_equal ann.id, User.find_by_password_reset_token(token).id
              assert_equal bob.id, User.find_by_password_reset_token(bob.password_reset_token).id
              assert_nil User.find_by_password_reset_token(Cybertrain::Token.issue("password_reset", bob.id, 15 * 60, ann.password_reset_binding))
              assert_nil User.find_by_password_reset_token(Cybertrain::Token.issue("password_reset", ann.id, 15 * 60, ann.password_digest))
              assert_nil User.find_by_password_reset_token(Cybertrain::Token.issue("confirmation", ann.id, 15 * 60, ann.password_reset_binding))
              assert_nil User.find_by_password_reset_token("")
              # A new password that does not pass: the token still holds.
              reset_with(token, NEW_PASSWORD, "something-else")
              assert_redirected_to "/passwords/#{token}/edit"
              assert_equal "no-referrer", response.header("Referrer-Policy")
              follow_redirect!
              assert_includes response.body, "<p class=\"alert\">Password confirmation doesn&#39;t match Password</p>"
              refute User.find_by_password_reset_token(token).nil?
              reset_with(token, NEW_PASSWORD)
              assert_redirected_to "/session/new"
              # Used once, the link is spent, and so is every link sent before.
              get "/passwords/#{token}/edit"
              assert_redirected_to "/passwords/new"
              reset_with(earlier, "an0ther-s3cr3t")
              assert_redirected_to "/passwords/new"
              follow_redirect!
              assert_includes response.body, INVALID
              post "/session", params: { email_address: "one@example.com", password: NEW_PASSWORD }
              assert_redirected_to "/"
              # bob's link is not ann's change: it still works.
              refute User.find_by_password_reset_token(bob.password_reset_token).nil?
              # A password changed any other way ends a link too.
              changed = User.find_by(email_address: "one@example.com")
              fresh = changed.password_reset_token
              changed.password = "th1rd-s3cr3t-x"
              changed.save!
              assert_nil User.find_by_password_reset_token(fresh)
              # And so does a new address (accounts_controller_test.rb changes it
              # through the page).
              fresh = changed.password_reset_token
              refute User.find_by_password_reset_token(fresh).nil?
              changed.email_address = "one@new.example"
              changed.save!
              assert_nil User.find_by_password_reset_token(fresh)
            end

            test "updating the password ends every other session" do
              ann = users(:one)
              # The laptop (this browser) signed in a day ago.
              travel_to 1.day.ago do
                sign_in_as ann
              end
              assert Session.first.created_at.to_i <= Time.current.to_i - 24 * 60 * 60
              phone = open_session
              phone.sign_in_as ann
              bobs = open_session
              bobs.sign_in_as users(:two)
              assert_equal 2, Session.where(user_id: ann.id).count
              assert signed_in?
              assert browser_signed_in?(phone)
              stranger = open_session
              stranger.put "/passwords/#{ann.password_reset_token}", params: { password: NEW_PASSWORD, password_confirmation: NEW_PASSWORD }
              stranger.assert_redirected_to "/session/new"
              stranger.follow_redirect!
              assert_includes stranger.response.body, UPDATED
              assert_equal 0, Session.where(user_id: ann.id).count
              refute signed_in?
              refute browser_signed_in?(phone)
              # Another user's sessions are left alone.
              assert_equal 1, Session.count
              assert browser_signed_in?(bobs, "two@example.com")
              # The old password no longer signs in; the new one does.
              stranger.sign_in_as ann
              stranger.assert_redirected_to "/session/new"
              stranger.post "/session", params: { email_address: "one@example.com", password: NEW_PASSWORD }
              stranger.assert_redirected_to "/"
            end

            test "a reset clears a lockout" do
              ann = users(:one)
              attempts = 0
              while attempts < Cybertrain.config.auth_lockout_attempts
                Cybertrain::RateLimit.reset_all!
                post "/session", params: { email_address: "one@example.com", password: "wrong-password" }
                attempts += 1
              end
              locked = User.find_by(id: ann.id)
              assert locked.locked?
              # While locked, the right password is refused.
              Cybertrain::RateLimit.reset_all!
              sign_in_as ann
              assert_redirected_to "/session/new"
              reset_with(locked.password_reset_token, NEW_PASSWORD)
              assert_redirected_to "/session/new"
              cleared = User.find_by(id: ann.id)
              assert_nil cleared.locked_until
              assert_equal 0, cleared.failed_attempts
              refute cleared.locked?
              post "/session", params: { email_address: "one@example.com", password: NEW_PASSWORD }
              assert_redirected_to "/"
            end

            test "the mail is stored with the dictionary's subject" do
              with_config("test", NO_HOSTS, "https://shop.example/") do
                request_reset("one@example.com")
              end
              assert_enqueued_jobs 1, "cybertrain mail"
              # The sender is Config#smtp_from (CYBERTRAIN_SMTP_FROM): set here,
              # so that the mail's is pinned whatever the environment gives.
              from = Cybertrain.config.smtp_from
              begin
                Cybertrain.config.smtp_from = "set-by-this-test@example.org"
                assert_equal 1, perform_enqueued_jobs
              ensure
                Cybertrain.config.smtp_from = from
              end
              mail = Cybertrain::Mailer.deliveries.last
              refute mail.nil?
              assert_equal "Reset your password", mail.mail_subject
              assert_equal I18n.t("passwords_mailer.reset.subject"), mail.mail_subject
              assert_equal "one@example.com", mail.mail_to
              assert_equal "set-by-this-test@example.org", mail.mail_from
              link = last_mail_link
              # base_url's trailing slash is not doubled.
              assert link.start_with?("https://shop.example/passwords/"), link
              assert_equal "Hello one@example.com,\n\nYou can choose a new password within the next 15 minutes at this address:\n" \
                           "#{link}\n\nIf you did not ask for this, ignore this mail: your password stays as it is.\n", mail.mail_body
              assert_includes mail.mail_html, "<p>Hello one@example.com,</p>"
              assert_includes mail.mail_html, "<p><a href=\"#{link}\">Choose a new password</a></p>"
            end

            test "POST /passwords past ten requests is refused for a while" do
              Cybertrain::RateLimit.reset_all!
              count = 0
              while count < 10
                post "/passwords", params: { email_address: "nobody@example.com" }
                assert_redirected_to "/session/new"
                count += 1
              end
              post "/passwords", params: { email_address: "one@example.com" }
              assert_redirected_to "/passwords/new"
              follow_redirect!
              assert_includes response.body, "<p class=\"alert\">Try again later.</p>"
              assert_no_enqueued_jobs "cybertrain mail"
              Cybertrain::RateLimit.reset_all!
            end

            private

            # Sends the address form as a browser would, with the Host header
            # given. The rate limit's counts are forgotten first.
            def request_reset(email_address, host = "www.example.com")
              Cybertrain::RateLimit.reset_all!
              post "/passwords", params: { email_address: email_address }, headers: { "host" => host }
              nil
            end

            # Sends the new-password form of the link with this token.
            def reset_with(token, password, confirmation = password)
              put "/passwords/#{token}", params: { password: password, password_confirmation: confirmation }
              nil
            end

            # The token in a link ("https://.../passwords/<token>/edit").
            def token_in(link)
              start = link.index("/passwords/").to_i + 11
              stop = link.index("/edit").to_i
              link[start, stop - start].to_s
            end

            # Whether this browser is signed in as email_address: the nav names them.
            def signed_in?(email_address = "one@example.com")
              get "/session/new"
              response.body.include?("<span>#{email_address}</span>")
            end

            @HELPERS@
          end
        RUBY
      end

      # test/controllers/accounts_controller_test.rb: the account page.
      def self.accounts_controller_test(confirmable = false)
        text = splice(accounts_controller_test_body, "@ADDRESS_HELPERS@",
                      margin(confirmable ? accounts_test_confirm_helpers : accounts_test_address_helpers, 2))
        splice(text, "@HELPERS@", with_config_helper)
      end

      def self.accounts_controller_test_body
        <<~'RUBY'
          # The account page (cybertrain generate authentication): a new address or
          # password only with the current password, what a new password ends and
          # keeps, deleting the account, and the limits on guessing the password.
          require "stringio"
          require "test_helper"

          class AccountsControllerTest < ActionDispatch::IntegrationTest
            WRONG_PASSWORD = "<p class=\"alert\">That is not your current password.</p>"
            UPDATED = "<p class=\"notice\">Your account has been updated.</p>"
            DELETED = "<p class=\"notice\">Your account has been deleted.</p>"
            NOT_DELETED = "<p class=\"alert\">Your account could not be deleted. Nothing has changed.</p>"
            NEW_PASSWORD = "n3w-s3cr3t-n3w"
            # with_config's `hosts` for an app that lists none (CYBERTRAIN_HOSTS unset).
            NO_HOSTS = Array.new(0) { "" }
            @ADDRESS_HELPERS@

            test "changing email or password requires the current password" do
              ann = users(:one)
              sign_in_as ann
              digest = ann.password_digest
              reset_token = ann.password_reset_token
              # A wrong current password: nothing changes, and the page says why.
              update_account("wrong-password", { email_address: "one@new.example", password: NEW_PASSWORD, password_confirmation: NEW_PASSWORD })
              assert_response :unprocessable_entity
              assert_includes response.body, WRONG_PASSWORD
              same = User.find(ann.id)
              assert_equal "one@example.com", same.email_address
              assert_equal digest, same.password_digest
              # None at all, for the address alone: the same.
              update_account("", { email_address: "one@new.example" })
              assert_response :unprocessable_entity
              assert_includes response.body, WRONG_PASSWORD
              assert_equal "one@example.com", User.find(ann.id).email_address
              # A wrong password ends no session.
              assert signed_in?
              assert_equal 1, Session.count
              session_id = Session.first.id
              # The right one: the new address (normalized), once it takes effect;
              # the password and the session stay as they were.
              update_account("password", { email_address: " One@New.Example ", password: "", password_confirmation: "" })
              assert_redirected_to "/account/edit"
              follow_redirect!
              assert_includes response.body, ADDRESS_CHANGED
              confirm_new_address(ann)
              get "/account/edit"
              assert_includes response.body, "<span>one@new.example</span>"
              changed = User.find(ann.id)
              assert_equal "one@new.example", changed.email_address
              assert_equal digest, changed.password_digest
              assert_equal 1, Session.count
              assert_equal session_id, Session.first.id
              # A password reset link sent to the old address no longer works.
              assert_nil User.find_by_password_reset_token(reset_token)
              # Signing in takes the new address, not the old one.
              other = open_session
              other.post "/session", params: { email_address: "one@example.com", password: "password" }
              other.assert_redirected_to "/session/new"
              other.post "/session", params: { email_address: "one@new.example", password: "password" }
              other.assert_redirected_to "/"
              # A taken address does not pass: the errors, and the nav still shows
              # the address in use.
              update_account("password", { email_address: "two@example.com" })
              assert_response :unprocessable_entity
              assert_includes response.body, "<li>Email address has already been taken</li>"
              assert_includes response.body, "<span>one@new.example</span>"
              assert_equal "one@new.example", User.find(ann.id).email_address
              # Nor does an address list (two mailboxes for one account), and no
              # link is mailed for it.
              update_account("password", { email_address: "one@new.example,eve@evil.example" })
              assert_response :unprocessable_entity
              assert_includes response.body, "<li>Email address is invalid</li>"
              assert_equal "one@new.example", User.find(ann.id).email_address
              # Nor an address the mailer would refuse (Cybertrain::Mailer.address_problem).
              ["one@new.example\u00A0", "one\u3000@new.example", "one\u0085@new.example", "one@new\u2028.example", "one;x@new.example", "one(x)@new.example"].each do |address|
                update_account("password", { email_address: address })
                assert_response :unprocessable_entity
                assert_includes response.body, "<li>Email address is invalid</li>"
                assert_equal "one@new.example", User.find(ann.id).email_address
              end
              # A new password that does not pass: nothing changes.
              update_account("password", { password: "short", password_confirmation: "short" })
              assert_response :unprocessable_entity
              assert_includes response.body, "<li>Password is too short (minimum is 8 characters)</li>"
              update_account("password", { password: NEW_PASSWORD, password_confirmation: "something-else" })
              assert_response :unprocessable_entity
              assert_includes response.body, "<li>Password confirmation doesn&#39;t match Password</li>"
              assert_equal digest, User.find(ann.id).password_digest
              # The right current password and a new one: only the new one signs in.
              update_account("password", { password: NEW_PASSWORD, password_confirmation: NEW_PASSWORD })
              assert_redirected_to "/account/edit"
              refute User.find(ann.id).password_digest == digest
              other.post "/session", params: { email_address: "one@new.example", password: "password" }
              other.assert_redirected_to "/session/new"
              other.post "/session", params: { email_address: "one@new.example", password: NEW_PASSWORD }
              other.assert_redirected_to "/"
            end

            test "a password change ends other sessions and keeps this one" do
              ann = users(:one)
              bob = users(:two)
              # This browser (a laptop) asked to stay signed in; the phone did not.
              sign_in_as ann, remember: true
              laptop_id = Session.first.id
              assert_equal true, Session.first.remember
              phone = open_session
              phone.sign_in_as ann
              bobs = open_session
              bobs.sign_in_as bob
              assert_equal 2, Session.where(user_id: ann.id).count
              token = ann.password_reset_token
              refute User.find_by_password_reset_token(token).nil?
              update_account("password", { password: NEW_PASSWORD, password_confirmation: NEW_PASSWORD })
              assert_redirected_to "/account/edit"
              # This browser is signed in again at once, still remembered (the
              # cookie keeps its Max-Age), on a new Session row with the new
              # password key.
              assert session_cookie_of(response).end_with?("; Max-Age=2592000"), session_cookie_of(response)
              follow_redirect!
              assert_includes response.body, UPDATED
              rows = Session.where(user_id: ann.id).to_a
              assert_equal 1, rows.size
              refute rows[0].id == laptop_id
              assert_equal true, rows[0].remember
              assert signed_in?
              refute browser_signed_in?(phone)
              assert browser_signed_in?(bobs, "two@example.com")
              assert_equal 1, Session.where(user_id: bob.id).count
              # A reset link sent before no longer works.
              assert_nil User.find_by_password_reset_token(token)
              # A browser that did not ask to stay signed in still has not: no Max-Age.
              phone.post "/session", params: { email_address: "one@example.com", password: NEW_PASSWORD }
              assert browser_signed_in?(phone)
              Cybertrain::RateLimit.reset_all!
              phone.patch "/account", params: { user: { current_password: NEW_PASSWORD, password: "th1rd-s3cr3t", password_confirmation: "th1rd-s3cr3t" } }
              phone.assert_redirected_to "/account/edit"
              refute session_cookie_of(phone.response).empty?
              refute session_cookie_of(phone.response).include?("Max-Age")
              rows = Session.where(user_id: ann.id).to_a
              assert_equal 1, rows.size
              assert_equal false, rows[0].remember
              assert browser_signed_in?(phone)
              refute signed_in?
              # A new address alone ends no session.
              post "/session", params: { email_address: "one@example.com", password: "th1rd-s3cr3t" }
              assert_equal 2, Session.where(user_id: ann.id).count
              Cybertrain::RateLimit.reset_all!
              phone.patch "/account", params: { user: { current_password: "th1rd-s3cr3t", email_address: "one@new.example" } }
              phone.assert_redirected_to "/account/edit"
              confirm_new_address(ann)
              assert_equal 2, Session.where(user_id: ann.id).count
              assert signed_in?("one@new.example")
              assert browser_signed_in?(phone, "one@new.example")
            end

            # The user deleted here is one the test makes (account_holder): a
            # fixture of the app's own may point at users(:one) (a scaffold's
            # `user:references` writes `user: one`), and the database keeps a
            # user that rows point at.
            test "deleting the account requires the password and removes the user and sessions" do
              ann = account_holder
              sign_in_as ann
              phone = open_session
              phone.sign_in_as ann
              bobs = open_session
              bobs.sign_in_as users(:two)
              assert_equal 3, Session.count
              # A wrong password, or none: nothing is deleted.
              delete_account("wrong-password")
              assert_response :unprocessable_entity
              assert_includes response.body, WRONG_PASSWORD
              delete_account("")
              assert_response :unprocessable_entity
              assert_includes response.body, WRONG_PASSWORD
              refute User.find_by(id: ann.id).nil?
              assert_equal 3, Session.count
              assert signed_in?("ann@example.com")
              # The right one: the user, every session of theirs, and this
              # browser's cookie session.
              delete_account("password")
              assert_redirected_to "/"
              get "/session/new"
              assert_includes response.body, DELETED
              assert_nil User.find_by(id: ann.id)
              assert_equal 0, Session.where(user_id: ann.id).count
              assert_equal 1, Session.count
              # The fixtures' users are still there.
              assert_equal 2, User.all.count
              refute signed_in?("ann@example.com")
              refute browser_signed_in?(phone, "ann@example.com")
              assert browser_signed_in?(bobs, "two@example.com")
              # The address signs in no more.
              sign_in_as ann
              assert_redirected_to "/session/new"
              get "/account/edit"
              assert_redirected_to "/session/new"
            end

            test "a visitor is sent to sign in" do
              ann = users(:one)
              get "/account/edit"
              assert_redirected_to "/session/new"
              # The forms' requests too, with the right password: nothing changes.
              patch "/account", params: { user: { current_password: "password", email_address: "eve@example.com" } }
              assert_redirected_to "/session/new"
              delete "/account", params: { password: "password" }
              assert_redirected_to "/session/new"
              assert_equal "one@example.com", User.find(ann.id).email_address
              assert_equal 2, User.all.count
              # Signed in, the browser comes back to the page it asked for, which
              # the nav links to.
              sign_in_as ann
              assert_redirected_to "/account/edit"
              get "/account/edit"
              assert_response :ok
              assert_includes response.body, "<h1>Account</h1>"
              assert_includes response.body, "<a href=\"/account/edit\">Account</a>"
              assert_includes response.body, "<form action=\"/account\" method=\"post\"><input type=\"hidden\" name=\"_method\" value=\"patch\">"
              assert_includes response.body, "<input type=\"email\" name=\"user[email_address]\" id=\"user_email_address\" value=\"one@example.com\" autocomplete=\"username\">"
              assert_includes response.body, "<label for=\"user_current_password\">Current password</label>"
              assert_includes response.body, "<form action=\"/account\" method=\"post\"><input type=\"hidden\" name=\"_method\" value=\"delete\">"
            end

            test "PATCH /account past ten requests is refused for a while" do
              ann = users(:one)
              sign_in_as ann
              Cybertrain::RateLimit.reset_all!
              count = 0
              while count < 10
                patch "/account", params: { user: { current_password: "wrong-password" } }
                assert_response :unprocessable_entity
                count += 1
              end
              # Wrong passwords here do not count toward the lockout, which guards
              # signing in (a stolen session could lock the owner out).
              assert_equal 0, User.find(ann.id).failed_attempts
              assert_nil User.find(ann.id).locked_until
              # The right password now gets the limit's answer and changes nothing;
              # a deletion counts in the same window.
              patch "/account", params: { user: { current_password: "password", email_address: "one@new.example" } }
              assert_redirected_to "/account/edit"
              follow_redirect!
              assert_includes response.body, "<p class=\"alert\">Try again later.</p>"
              assert_equal "one@example.com", User.find(ann.id).email_address
              delete "/account", params: { password: "password" }
              assert_redirected_to "/account/edit"
              refute User.find_by(id: ann.id).nil?
              # Once the window is over (its counts forgotten), the same change passes.
              Cybertrain::RateLimit.reset_all!
              patch "/account", params: { user: { current_password: "password", email_address: "one@new.example" } }
              assert_redirected_to "/account/edit"
              confirm_new_address(ann)
              assert_equal "one@new.example", User.find(ann.id).email_address
              Cybertrain::RateLimit.reset_all!
            end

            # The browsers here are Cybertrain::Test::Clients, the client under an
            # integration test: each request of ann's comes from another address,
            # which an integration test cannot set. Their responses are checked by
            # status and Location.
            test "wrong current passwords are limited per user too, from any address" do
              ann = users(:one)
              browser = Cybertrain::Test::Client.new(Cybertrain::Test.app)
              browser.post("/session", { "email_address" => "one@example.com", "password" => "password" })
              bobs = Cybertrain::Test::Client.new(Cybertrain::Test.app)
              bobs.post("/session", { "email_address" => "two@example.com", "password" => "password" })
              Cybertrain::RateLimit.reset_all!
              # Ten wrong guesses, each from another address: the per-address limit
              # never fills.
              count = 0
              while count < 10
                browser.peer_address = "203.0.113.#{count + 1}"
                res = browser.patch("/account", { "user[current_password]" => "wrong-password" })
                assert_equal 422, res.status
                count += 1
              end
              # The eleventh, from yet another address and with the right password:
              # the per-user limit answers, and nothing changes.
              browser.peer_address = "203.0.113.99"
              res = browser.patch("/account", { "user[current_password]" => "password", "user[email_address]" => "one@new.example" })
              assert_equal 303, res.status
              assert_equal "/account/edit", res.header("Location")
              assert_includes browser.follow_redirect!.body, "<p class=\"alert\">Try again later.</p>"
              assert_equal "one@example.com", User.find(ann.id).email_address
              # Another user, from that same address, is not held back by ann's count.
              bobs.peer_address = "203.0.113.99"
              res = bobs.patch("/account", { "user[current_password]" => "password",
                                             "user[password]" => NEW_PASSWORD, "user[password_confirmation]" => NEW_PASSWORD })
              assert_equal 303, res.status
              assert_equal "/account/edit", res.header("Location")
              assert_includes bobs.follow_redirect!.body, UPDATED
              Cybertrain::RateLimit.reset_all!
            end

            # users(:two) is not an admin, has no failed attempt and no lock.
            test "the form's fields are the only ones a change takes" do
              two = users(:two)
              sign_in_as two
              # Fields the form does not have, sent with the right password: ignored.
              update_account("password", { password: NEW_PASSWORD, password_confirmation: NEW_PASSWORD,
                                           admin: "1", failed_attempts: "7", locked_until: "2099-01-01 00:00:00" })
              assert_redirected_to "/account/edit"
              changed = User.find(two.id)
              assert changed.authenticate(NEW_PASSWORD)
              assert_equal false, changed.admin?
              assert_equal 0, changed.failed_attempts
              assert_nil changed.locked_until
            end

            test "PATCH and DELETE /account without the form's token are refused" do
              ann = users(:one)
              sign_in_as ann
              with_forgery_protection do
                patch "/account", params: { user: { current_password: "password", email_address: "eve@example.com" } }
                assert_response :forbidden
                delete "/account", params: { password: "password" }
                assert_response :forbidden
                # Nor with another browser's token.
                other = open_session
                other.get "/session/new"
                foreign = authenticity_token_in(other.response.body)
                patch "/account", params: { authenticity_token: foreign, user: { current_password: "password", email_address: "eve@example.com" } }
                assert_response :forbidden
                delete "/account", params: { authenticity_token: foreign, password: "password" }
                assert_response :forbidden
              end
              assert_equal "one@example.com", User.find(ann.id).email_address
              refute User.find_by(id: ann.id).nil?
              assert signed_in?
            end

            test "a new hash of the password stays with this browser when the change fails" do
              ann = users(:one)
              sign_in_as ann
              digest = ann.password_digest
              begin
                # The cost raised since the fixture's digest was made: checking
                # the password saves a new hash of it (User#authenticate).
                Cybertrain::Password.iterations = Cybertrain::Password::TEST_ITERATIONS + 1
                update_account("password", { email_address: "two@example.com" })
                assert_response :unprocessable_entity
                assert_includes response.body, "<li>Email address has already been taken</li>"
                rehashed = User.find(ann.id).password_digest
                refute rehashed == digest
                assert Cybertrain::Password.verify?("password", rehashed)
                # This browser is still signed in on its row.
                assert signed_in?
                assert_equal 1, Session.where(user_id: ann.id).count
              ensure
                Cybertrain::Password.iterations = Cybertrain::Password::TEST_ITERATIONS
              end
            end

            test "a deletion the database refuses changes nothing and says so" do
              ann = account_holder
              sign_in_as ann
              phone = open_session
              phone.sign_in_as ann
              add_note_for(ann)
              log = StringIO.new
              begin
                with_config("test", NO_HOSTS, "", log) do
                  delete_account("password")
                  assert_response :unprocessable_entity
                  assert_includes response.body, NOT_DELETED
                end
                # The user and both sessions are kept (one transaction), and the
                # log says why.
                refute User.find_by(id: ann.id).nil?
                assert_equal 2, Session.where(user_id: ann.id).count
                assert signed_in?("ann@example.com")
                assert browser_signed_in?(phone, "ann@example.com")
                assert_includes log.string, " ERROR "
                assert_includes log.string, "account not deleted: FOREIGN KEY constraint failed"
              ensure
                drop_notes
              end
              # Once nothing refers to the user, the same deletion passes.
              delete_account("password")
              assert_redirected_to "/"
              assert_nil User.find_by(id: ann.id)
              assert_equal 0, Session.where(user_id: ann.id).count
            end

            private

            # Sends the account form as a browser would: the current password and
            # the fields given, each as user[name]. The rate limit's counts are
            # forgotten first.
            def update_account(current_password, fields)
              Cybertrain::RateLimit.reset_all!
              form = { current_password: current_password }
              fields.each { |name, value| form[name] = value }
              patch "/account", params: { user: form }
              nil
            end

            # Sends the delete form with this password.
            def delete_account(password)
              Cybertrain::RateLimit.reset_all!
              delete "/account", params: { password: password }
              nil
            end

            # Whether this browser is signed in as email_address: the nav names them.
            def signed_in?(email_address = "one@example.com")
              get "/session/new"
              response.body.include?("<span>#{email_address}</span>")
            end

            # The Set-Cookie line of the session cookie in res ("" when none).
            def session_cookie_of(res)
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

            @HELPERS@
          end
        RUBY
      end

      # What a new address does on the account page, in
      # accounts_controller_test.rb: it takes effect at once.
      def self.accounts_test_address_helpers
        <<~'RUBY'
          # What the page says after a new address, which takes effect at once.
          ADDRESS_CHANGED = UPDATED

          # A user of the test's own, ann@example.com, password "password",
          # for the tests that delete the account.
          def account_holder
            user = User.new(email_address: "ann@example.com")
            user.password = "password"
            user.save!
            user
          end

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

          # A user of the test's own, ann@example.com, password "password",
          # confirmed so it can sign in, for the tests that delete the account.
          def account_holder
            user = User.new(email_address: "ann@example.com")
            user.password = "password"
            user.confirmed_at = Time.current
            user.save!
            user
          end

          # Opens the link of the new address user is waiting for (from a browser
          # that is not signed in, as a mail reader's would be), so it takes the
          # old one's place. confirmations_controller_test.rb follows the mailed
          # link itself.
          def confirm_new_address(user)
            token = User.find(user.id).confirmation_token
            reader = open_session
            reader.get "/confirmations/#{token}"
            reader.assert_redirected_to "/session/new"
            nil
          end
        RUBY
      end

      # test/controllers/confirmations_controller_test.rb (--confirmable):
      # the mail, sign-in refused until the address is confirmed, the link,
      # a new address, the send-again form, and the users that /setup and
      # the user command make. Its first test is the mode's: sign-up's mail,
      # or (--invite-only) /setup's confirmed first user.
      def self.confirmations_controller_test(app, invite_only = false)
        text = confirmations_controller_test_body
        text = splice(text, "@FIRST_USER_TEST@", margin(invite_only ? confirmations_setup_test : confirmations_sign_up_test, 2))
        text = splice(text, "@HELPERS@", with_config_helper)
        text = text.gsub(BASE_URL_ENV_MARK, base_url_env(app))
        text.gsub("@APP@", app)
      end

      def self.confirmations_controller_test_body
        <<~'RUBY'
          # Confirming the email address (cybertrain generate authentication
          # --confirmable): the mail with the link (kept in
          # Cybertrain::Mailer.deliveries), sign-in refused until the link is
          # opened, the link itself (three days, once, signing nobody in), a new
          # address that takes effect only once its own link is opened, and the
          # form that mails the link again. The fixtures' users are confirmed;
          # unconfirmed_user makes one who is not.
          require "stringio"
          require "test_helper"
          require_relative "../../app/commands/user_command"

          # start_new_session_for is private (the Authentication concern's): a
          # controller made for these tests calls it, as any action could.
          class SessionStartProbeController < ApplicationController
            def probe_start(user)
              start_new_session_for(user)
            end
          end

          class ConfirmationsControllerTest < ActionDispatch::IntegrationTest
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
            # with_config's `hosts` for an app that lists none (CYBERTRAIN_HOSTS unset).
            NO_HOSTS = Array.new(0) { "" }

            @FIRST_USER_TEST@

            test "./@APP@ user makes a confirmed user, and mails nothing" do
              assert_equal 0, UserCommand.run(["Dee@Example.com", "s3cr3t-s3cr3t"])
              dee = User.find_by(email_address: "dee@example.com")
              refute dee.nil?
              assert_equal true, dee.confirmed?
              assert_no_enqueued_jobs "cybertrain mail"
              post "/session", params: { email_address: "dee@example.com", password: "s3cr3t-s3cr3t" }
              assert_redirected_to "/"
              # A new password for a user who exists leaves the confirmation as it was.
              ann = unconfirmed_user
              assert_equal 0, UserCommand.run(["ann@example.com", "an0ther-s3cr3t"])
              assert_equal false, User.find(ann.id).confirmed?
              post "/session", params: { email_address: "ann@example.com", password: "an0ther-s3cr3t" }
              assert_redirected_to "/session/new"
              follow_redirect!
              assert_includes response.body, UNCONFIRMED
            end

            test "sign-in is refused until confirmed, with the send-again link" do
              ann = unconfirmed_user
              # A wrong password, or an address no user has: the usual message,
              # which says nothing of the address.
              post "/session", params: { email_address: "ann@example.com", password: "wrong-password" }
              assert_redirected_to "/session/new"
              follow_redirect!
              assert_includes response.body, WRONG
              refute response.body.include?(UNCONFIRMED)
              post "/session", params: { email_address: "nobody@example.com", password: "password" }
              assert_redirected_to "/session/new"
              follow_redirect!
              assert_includes response.body, WRONG
              refute response.body.include?(UNCONFIRMED)
              # The right password: refused all the same, with the reason, and the
              # sign-in page links to the form that mails the link again.
              sign_in_as ann
              assert_redirected_to "/session/new"
              follow_redirect!
              assert_includes response.body, UNCONFIRMED
              refute response.body.include?(WRONG)
              assert_includes response.body, SEND_AGAIN_LINK
              assert_equal 0, Session.count
              refute signed_in?("ann@example.com")
              # As any right password does, it cleared the wrong one's count.
              assert_equal 0, User.find(ann.id).failed_attempts
              # Confirmed, the same password signs in.
              get "/confirmations/#{ann.confirmation_token}"
              assert_redirected_to "/session/new"
              sign_in_as ann
              assert_redirected_to "/"
              assert_equal 1, Session.count
              assert signed_in?("ann@example.com")
            end

            test "the concern itself starts no session for an unconfirmed account" do
              ann = unconfirmed_user
              ctx = Cybertrain::Context.new(Cybertrain::Request.new("POST", "/session", {}, ""))
              ctx.session = Cybertrain::Session.new
              SessionStartProbeController.new(ctx).probe_start(ann)
              assert_equal 0, Session.count
              assert_nil ctx.session[:session_id]
              assert_nil ctx.session[:password_key]
              # Confirmed, the same call signs in.
              ann.update_columns(confirmed_at: Time.current)
              SessionStartProbeController.new(ctx).probe_start(User.find(ann.id))
              assert_equal 1, Session.count
              assert_equal Session.first.id, ctx.session[:session_id].to_i
            end

            test "the link confirms, and the user can then sign in" do
              ann = unconfirmed_user
              token = ann.confirmation_token
              before = Time.current.to_i
              get "/confirmations/#{token}"
              after = Time.current.to_i
              assert_redirected_to "/session/new"
              # The page's address holds the token: no Referer leaves it.
              assert_equal "no-referrer", response.header("Referrer-Policy")
              follow_redirect!
              page = response.body
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
              get "/confirmations/#{token}"
              assert_redirected_to "/confirmations/new"
              assert_equal "no-referrer", response.header("Referrer-Policy")
              follow_redirect!
              assert_includes response.body, INVALID
              assert_equal confirmed.confirmed_at.to_i, User.find(ann.id).confirmed_at.to_i
              # The user then signs in, with the password.
              sign_in_as ann
              assert_redirected_to "/"
              assert signed_in?("ann@example.com")
            end

            test "the link lasts three days and belongs to its user and address" do
              ann = unconfirmed_user
              bob = unconfirmed_user("bob@example.com")
              assert_equal 259_200, User::CONFIRMATION_TOKEN_TTL
              now = Time.current.to_i
              assert ann.confirmation_token(now).start_with?("#{ann.id}--#{now + 259_200}--")
              assert_equal ":ann@example.com:0", ann.confirmation_binding
              stale = ann.confirmation_token(now - 259_200 - 60)
              fresh = ann.confirmation_token(now - 259_200 + 60)
              assert_nil User.find_by_confirmation_token(stale)
              assert_equal ann.id, User.find_by_confirmation_token(fresh).id
              get "/confirmations/#{stale}"
              assert_redirected_to "/confirmations/new"
              assert_equal false, User.find(ann.id).confirmed?
              # Another user's id with ann's binding, another purpose, or nothing
              # at all: no one's.
              assert_nil User.find_by_confirmation_token(Cybertrain::Token.issue("confirmation", bob.id, 900, ann.confirmation_binding))
              assert_nil User.find_by_confirmation_token(ann.password_reset_token)
              assert_nil User.find_by_password_reset_token(ann.confirmation_token)
              assert_nil User.find_by_confirmation_token("")
              get "/confirmations/not-a-token"
              assert_redirected_to "/confirmations/new"
              assert_equal bob.id, User.find_by_confirmation_token(bob.confirmation_token).id
              assert_equal false, User.find(bob.id).confirmed?
            end

            test "an email change takes effect only when the new address confirms" do
              ann = users(:one)
              sign_in_as ann
              reset_token = ann.password_reset_token
              change_address(" One@New.Example ")
              assert_redirected_to "/account/edit"
              follow_redirect!
              page = response.body
              assert_includes page, ADDRESS_CHANGED
              # Not yet: the old address is in use, the new one waits.
              assert_includes page, "<span>one@example.com</span>"
              assert_includes page, "<p class=\"hint\">Waiting for confirmation: one@new.example</p>"
              waiting = User.find(ann.id)
              assert_equal "one@example.com", waiting.email_address
              assert_equal "one@new.example", waiting.unconfirmed_email
              other = open_session
              other.post "/session", params: { email_address: "one@new.example", password: "password" }
              other.assert_redirected_to "/session/new"
              other.post "/session", params: { email_address: "one@example.com", password: "password" }
              other.assert_redirected_to "/"
              refute User.find_by_password_reset_token(reset_token).nil?
              # A taken address is refused when it is asked for; the one waiting stays.
              change_address("two@example.com")
              assert_response :unprocessable_entity
              assert_includes response.body, "<li>Email address has already been taken</li>"
              assert_includes response.body, "<p class=\"hint\">Waiting for confirmation: one@new.example</p>"
              assert_equal "one@new.example", User.find(ann.id).unconfirmed_email
              # The mail goes to the new address.
              assert_enqueued_jobs 1, "cybertrain mail"
              assert_equal 1, perform_enqueued_jobs
              mail = Cybertrain::Mailer.deliveries.last
              refute mail.nil?
              assert_equal "one@new.example", mail.mail_to
              assert_includes mail.mail_body, "Hello one@new.example,\n"
              link = last_mail_link
              assert link.start_with?("http://www.example.com/confirmations/"), link
              # Opened in the browser that asked: back to the account page, with
              # the new address in use.
              path = "/confirmations/#{token_in(link)}"
              get path
              assert_redirected_to "/account/edit"
              follow_redirect!
              account_page = response.body
              assert_includes account_page, CONFIRMED
              assert_includes account_page, "<span>one@new.example</span>"
              refute account_page.include?("Waiting for confirmation")
              # The link is used up.
              get path
              assert_redirected_to "/confirmations/new"
              changed = User.find(ann.id)
              assert_equal "one@new.example", changed.email_address
              assert_nil changed.unconfirmed_email
              assert changed.confirmed?
              # Both sessions go on; the old address signs in no more, the new one does.
              assert_equal 2, Session.where(user_id: ann.id).count
              other.post "/session", params: { email_address: "one@example.com", password: "password" }
              other.assert_redirected_to "/session/new"
              other.post "/session", params: { email_address: "one@new.example", password: "password" }
              other.assert_redirected_to "/"
              # A password reset link sent to the old address is spent.
              assert_nil User.find_by_password_reset_token(reset_token)
            end

            test "a new address someone takes before its link is opened is not moved in" do
              ann = users(:one)
              sign_in_as ann
              change_address("carol@example.com")
              assert_redirected_to "/account/edit"
              token = User.find(ann.id).confirmation_token
              # Meanwhile carol signs up with it: an address that only waits is free.
              carol = unconfirmed_user("carol@example.com")
              # A pending address someone has taken since blocks nothing else of
              # ann's account: the user command and the rehash a sign-in makes after
              # the cost was raised save, and leave it waiting (a password reset
              # saves too, below, and withdraws it).
              assert_equal 0, UserCommand.run(["one@example.com", "an0ther-s3cr3t"])
              assert User.find(ann.id).authenticate("an0ther-s3cr3t")
              assert_equal 0, UserCommand.run(["one@example.com", "password"])
              assert User.find(ann.id).authenticate("password")
              assert_equal "carol@example.com", User.find(ann.id).unconfirmed_email
              digest = User.find(ann.id).password_digest
              begin
                Cybertrain::Password.iterations = Cybertrain::Password::TEST_ITERATIONS + 1
                sign_in_as ann
                assert_redirected_to "/"
                refute User.find(ann.id).password_digest == digest
                refute Cybertrain::Password.needs_rehash?(User.find(ann.id).password_digest)
              ensure
                Cybertrain::Password.iterations = Cybertrain::Password::TEST_ITERATIONS
              end
              # The link: the address is not moved in, and the one waiting is
              # forgotten (it can never be confirmed now).
              get "/confirmations/#{token}"
              assert_redirected_to "/account/edit"
              follow_redirect!
              assert_includes response.body, TAKEN
              refute response.body.include?("Waiting for confirmation")
              assert_equal "one@example.com", User.find(ann.id).email_address
              assert_nil User.find(ann.id).unconfirmed_email
              assert_equal "carol@example.com", User.find(carol.id).email_address
              # Another new address ends the link to the one before.
              change_address("one@other.example")
              assert_redirected_to "/account/edit"
              other_token = User.find(ann.id).confirmation_token
              change_address("one@third.example")
              assert_redirected_to "/account/edit"
              assert_nil User.find_by_confirmation_token(other_token)
              assert_equal "one@third.example", User.find(ann.id).unconfirmed_email
              # A password reset saves with a taken address waiting, and withdraws it.
              change_address("zed@example.com")
              assert_redirected_to "/account/edit"
              unconfirmed_user("zed@example.com")
              stranger = open_session
              stranger.put "/passwords/#{User.find(ann.id).password_reset_token}", params: { password: "an0ther-s3cr3t", password_confirmation: "an0ther-s3cr3t" }
              stranger.assert_redirected_to "/session/new"
              assert User.find(ann.id).authenticate("an0ther-s3cr3t")
              assert_nil User.find(ann.id).unconfirmed_email
            end

            test "a password-only change keeps the new address waiting" do
              ann = users(:one)
              sign_in_as ann
              change_address("one@new.example")
              assert_redirected_to "/account/edit"
              token = User.find(ann.id).confirmation_token
              # The form sends the address in use back (it is pre-filled) with a new
              # password: no change of address, so the one waiting stays.
              patch "/account", params: { user: { current_password: "password", email_address: "one@example.com",
                                                  password: "n3w-s3cr3t-n3w", password_confirmation: "n3w-s3cr3t-n3w" } }
              assert_redirected_to "/account/edit"
              follow_redirect!
              assert_includes response.body, UPDATED
              assert_includes response.body, "<p class=\"hint\">Waiting for confirmation: one@new.example</p>"
              kept = User.find(ann.id)
              assert_equal "one@example.com", kept.email_address
              assert_equal "one@new.example", kept.unconfirmed_email
              assert kept.authenticate("n3w-s3cr3t-n3w")
              # The address alone, sent again unchanged: nothing changes either.
              patch "/account", params: { user: { current_password: "n3w-s3cr3t-n3w", email_address: " One@Example.com " } }
              assert_redirected_to "/account/edit"
              assert_equal "one@new.example", User.find(ann.id).unconfirmed_email
              # The link still confirms it.
              assert_equal ann.id, User.find_by_confirmation_token(token).id
              get "/confirmations/#{token}"
              assert_redirected_to "/account/edit"
              assert_equal "one@new.example", User.find(ann.id).email_address
            end

            test "a new address waiting can be withdrawn, and its link then moves nothing" do
              ann = users(:one)
              sign_in_as ann
              # Nothing waits: no button to withdraw it.
              get "/account/edit"
              refute response.body.include?("/account/pending_email")
              refute response.body.include?("Cancel this change")
              # A mistyped address, a stranger's mailbox: the page offers to withdraw it.
              change_address("one@stranger.example")
              assert_redirected_to "/account/edit"
              token = User.find(ann.id).confirmation_token
              follow_redirect!
              assert_includes response.body, CANCEL_BUTTON
              assert_includes response.body, "Cancel this change"
              # Without the form's token: refused, and still waiting.
              with_forgery_protection do
                delete "/account/pending_email", params: { x: "1" }
                assert_response :forbidden
              end
              assert_equal "one@stranger.example", User.find(ann.id).unconfirmed_email
              # A visitor is sent to sign in, and nothing changes.
              visitor = open_session
              visitor.delete "/account/pending_email"
              visitor.assert_redirected_to "/session/new"
              assert_equal "one@stranger.example", User.find(ann.id).unconfirmed_email
              # The button, with no password (withdrawing is the safe direction).
              delete "/account/pending_email"
              assert_redirected_to "/account/edit"
              follow_redirect!
              assert_includes response.body, CANCELLED
              refute response.body.include?("Waiting for confirmation")
              refute response.body.include?("Cancel this change")
              withdrawn = User.find(ann.id)
              assert_nil withdrawn.unconfirmed_email
              assert_equal "one@example.com", withdrawn.email_address
              # The stranger's link: invalid now, and the account stays where it was.
              assert_nil User.find_by_confirmation_token(token)
              stranger = open_session
              stranger.get "/confirmations/#{token}"
              stranger.assert_redirected_to "/confirmations/new"
              stranger.follow_redirect!
              assert_includes stranger.response.body, INVALID
              assert_equal "one@example.com", User.find(ann.id).email_address
              assert_nil User.find(ann.id).unconfirmed_email
              assert signed_in?
            end

            test "two confirmations racing for one address: the second gets the taken answer" do
              ann = users(:one)
              sign_in_as ann
              change_address("carol@example.com")
              assert_redirected_to "/account/edit"
              token = User.find(ann.id).confirmation_token
              # Another account takes the address between confirm's check and its
              # write (a trigger inserts it just before the UPDATE): the unique index
              # refuses the write, and the answer is the taken one, not a 500.
              add_race_trigger
              begin
                get "/confirmations/#{token}"
                assert_redirected_to "/account/edit"
                follow_redirect!
                assert_includes response.body, TAKEN
              ensure
                drop_race_trigger
              end
              raced = User.find(ann.id)
              assert_equal "one@example.com", raced.email_address
              assert_nil raced.unconfirmed_email
              assert raced.confirmed?
              assert signed_in?
            end

            test "a password reset confirms a new account's address, and withdraws a new address waiting" do
              ann = unconfirmed_user
              # The reset link went to ann's own address: it proves that mailbox, as
              # the confirmation link does (and someone who signed up first with that
              # address loses the account to its owner).
              reset_with(ann.password_reset_token, "an0ther-s3cr3t")
              assert_redirected_to "/session/new"
              assert User.find(ann.id).confirmed?
              post "/session", params: { email_address: "ann@example.com", password: "an0ther-s3cr3t" }
              assert_redirected_to "/"
              # A new address waiting for bob: a reset proves only bob's old
              # mailbox, so it never confirms it; it withdraws it, and its link
              # (whoever asked for it may be who bob takes the account back from).
              bob = users(:two)
              confirmed_at = User.find(bob.id).confirmed_at.to_i
              bobs = open_session
              bobs.sign_in_as bob
              bobs.patch "/account", params: { user: { current_password: "password", email_address: "two@new.example" } }
              bobs.assert_redirected_to "/account/edit"
              pending_token = User.find(bob.id).confirmation_token
              refute User.find_by_confirmation_token(pending_token).nil?
              reset_with(bob.password_reset_token, "an0ther-s3cr3t")
              assert_redirected_to "/session/new"
              reset = User.find(bob.id)
              assert_equal "two@example.com", reset.email_address
              assert_nil reset.unconfirmed_email
              assert_equal confirmed_at, reset.confirmed_at.to_i
              assert_nil User.find_by_confirmation_token(pending_token)
              reader = open_session
              reader.get "/confirmations/#{pending_token}"
              reader.assert_redirected_to "/confirmations/new"
              assert_equal "two@example.com", User.find(bob.id).email_address
              post "/session", params: { email_address: "two@new.example", password: "an0ther-s3cr3t" }
              assert_redirected_to "/session/new"
            end

            test "send again answers the same for unknown addresses" do
              ann = unconfirmed_user
              get "/confirmations/new"
              assert_response :ok
              assert_includes response.body, "<h1>Send the confirmation link again</h1>"
              assert_includes response.body, "<form action=\"/confirmations\" method=\"post\">"
              send_again(" Ann@Example.com ")
              known = response
              follow_redirect!
              assert_includes response.body, SENT
              send_again("nobody@example.com")
              unknown = response
              follow_redirect!
              assert_includes response.body, SENT
              # An address confirmed already: the same answer too.
              send_again("two@example.com")
              confirmed = response
              assert_equal 303, known.status
              assert_equal "/session/new", known.header("Location")
              assert_equal known.status, unknown.status
              assert_equal known.header("Location"), unknown.header("Location")
              assert_equal known.body, unknown.body
              assert_equal known.status, confirmed.status
              assert_equal known.header("Location"), confirmed.header("Location")
              assert_equal known.body, confirmed.body
              follow_redirect!
              assert_includes response.body, SENT
              # One mail, to the address that waits; its link confirms it.
              assert_enqueued_jobs 1, "cybertrain mail"
              assert_equal 1, perform_enqueued_jobs
              mail = Cybertrain::Mailer.deliveries.last
              refute mail.nil?
              assert_equal "ann@example.com", mail.mail_to
              get "/confirmations/#{token_in(last_mail_link)}"
              assert_redirected_to "/session/new"
              assert User.find(ann.id).confirmed?
              # Confirmed now, ann gets the same answer and no mail.
              clear_enqueued_jobs
              send_again("ann@example.com")
              assert_equal known.header("Location"), response.header("Location")
              assert_equal known.body, response.body
              assert_no_enqueued_jobs "cybertrain mail"
            end

            test "send again: a refused address, no safe base and the rate limit" do
              # Refused at entry now (User.email_address_format?), so saved
              # before that check existed.
              unconfirmed_user("jose@example.com").update_columns(email_address: "josé@example.com")
              unconfirmed_user
              # An address the mailer refuses: the same answer, and the log says why.
              log = StringIO.new
              with_config("test", NO_HOSTS, "", log) do
                send_again("josé@example.com")
                refused = response
                send_again("nobody@example.com")
                assert_equal 303, response.status
                assert_equal "/session/new", refused.header("Location")
                assert_equal refused.header("Location"), response.header("Location")
                assert_equal refused.body, response.body
              end
              assert_no_enqueued_jobs "cybertrain mail"
              assert_includes log.string, " ERROR "
              assert_includes log.string, "confirmation mail not sent: the to address contains a space, a control character or a non-ASCII byte\n"
              # Production with neither base_url nor CYBERTRAIN_HOSTS: no mail, an
              # ERROR line, the same answer.
              log = StringIO.new
              with_config("production", NO_HOSTS, "", log) do
                send_again("ann@example.com")
                assert_redirected_to "/session/new"
                follow_redirect!
                assert_includes response.body, SENT
              end
              assert_no_enqueued_jobs "cybertrain mail"
              assert_includes log.string, " ERROR "
              assert_includes log.string, "confirmation mail not sent: set @BASE_URL_ENV@ (or CYBERTRAIN_HOSTS)\n"
              # Ten requests per client address, then the form again for a while.
              Cybertrain::RateLimit.reset_all!
              count = 0
              while count < 10
                post "/confirmations", params: { email_address: "nobody@example.com" }
                assert_redirected_to "/session/new"
                count += 1
              end
              post "/confirmations", params: { email_address: "ann@example.com" }
              assert_redirected_to "/confirmations/new"
              follow_redirect!
              assert_includes response.body, "<p class=\"alert\">Try again later.</p>"
              assert_no_enqueued_jobs "cybertrain mail"
              Cybertrain::RateLimit.reset_all!
            end

            # Cybertrain's CSRF check, on inside with_forgery_protection: the
            # send-again form (a visitor's) and the button that withdraws a new
            # address (on the account page) are refused without the form's
            # token, and taken with the token of the page that holds them.
            test "send again and withdrawing a new address take the page's own form token" do
              unconfirmed_user
              Cybertrain::RateLimit.reset_all!
              with_forgery_protection do
                post "/confirmations", params: { email_address: "ann@example.com" }
                assert_response :forbidden
              end
              assert_no_enqueued_jobs "cybertrain mail"
              with_forgery_protection do
                get "/confirmations/new"
                post "/confirmations", params: { authenticity_token: authenticity_token_in(response.body), email_address: "ann@example.com" }
                assert_redirected_to "/session/new"
              end
              assert_enqueued_jobs 1, "cybertrain mail"
              # A new address waiting on one's account.
              one = users(:one)
              sign_in_as one
              change_address("one@stranger.example")
              assert_redirected_to "/account/edit"
              with_forgery_protection do
                delete "/account/pending_email", params: { x: "1" }
                assert_response :forbidden
              end
              assert_equal "one@stranger.example", User.find(one.id).unconfirmed_email
              with_forgery_protection do
                get "/account/edit"
                delete "/account/pending_email", params: { authenticity_token: authenticity_token_in(response.body) }
                assert_redirected_to "/account/edit"
              end
              assert_nil User.find(one.id).unconfirmed_email
              Cybertrain::RateLimit.reset_all!
            end

            private

            # A user who has not confirmed the address yet, as a sign-up leaves one
            # (the fixtures' users are confirmed); the password is the fixtures'.
            def unconfirmed_user(email_address = "ann@example.com")
              user = User.new(email_address: email_address)
              user.password = "password"
              user.save!
              user
            end

            # The token in a link ("http://.../confirmations/<token>").
            def token_in(link)
              start = link.index("/confirmations/").to_i + 15
              link[start, link.size - start].to_s
            end

            # Whether this browser is signed in as email_address: the nav names them.
            def signed_in?(email_address = "one@example.com")
              get "/session/new"
              response.body.include?("<span>#{email_address}</span>")
            end

            # Sends the form that mails the link again, the rate limit's counts
            # forgotten first.
            def send_again(email_address)
              Cybertrain::RateLimit.reset_all!
              post "/confirmations", params: { email_address: email_address }
              nil
            end

            # Sends the new-password form of a password reset link with this token.
            def reset_with(token, password)
              put "/passwords/#{token}", params: { password: password, password_confirmation: password }
              nil
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
            def change_address(email_address)
              Cybertrain::RateLimit.reset_all!
              patch "/account", params: { user: { current_password: "password", email_address: email_address } }
              nil
            end

            @HELPERS@
          end
        RUBY
      end

      # Sign-up mode's first test: the mail, and nobody signed in.
      def self.confirmations_sign_up_test
        <<~'RUBY'
          test "sign-up sends a confirmation mail and signs nobody in" do
            post "/sign_up", params: { user: { email_address: " Ann@Example.com ", password: "s3cr3t-s3cr3t", password_confirmation: "s3cr3t-s3cr3t" } }
            assert_redirected_to "/session/new"
            follow_redirect!
            page = response.body
            assert_includes page, "<p class=\"notice\">Welcome! A link to confirm your email address was sent to it. Open it, then sign in.</p>"
            refute page.include?("<span>ann@example.com</span>")
            user = User.last
            assert_equal "ann@example.com", user.email_address
            assert_equal false, user.confirmed?
            assert_nil user.confirmed_at
            assert_nil user.unconfirmed_email
            assert_equal 0, Session.count
            assert_enqueued_jobs 1, "cybertrain mail"
            from = Cybertrain.config.smtp_from
            begin
              Cybertrain.config.smtp_from = "set-by-this-test@example.org"
              assert_equal 1, perform_enqueued_jobs
            ensure
              Cybertrain.config.smtp_from = from
            end
            mail = Cybertrain::Mailer.deliveries.last
            refute mail.nil?
            assert_equal "Confirm your email address", mail.mail_subject
            assert_equal I18n.t("confirmations_mailer.confirmation_instructions.subject"), mail.mail_subject
            assert_equal "ann@example.com", mail.mail_to
            assert_equal "set-by-this-test@example.org", mail.mail_from
            link = last_mail_link
            assert link.start_with?("http://www.example.com/confirmations/#{user.id}--"), link
            assert_equal "Hello ann@example.com,\n\nOpen this link within the next 3 days to confirm your email address:\n" \
                         "#{link}\n\nIf you did not ask for this, ignore this mail: nothing changes.\n", mail.mail_body
            assert_includes mail.mail_html, "<p>Hello ann@example.com,</p>"
            assert_includes mail.mail_html, "<p><a href=\"#{link}\">Confirm my email address</a></p>"
            # The mailed link is the one that confirms this user.
            assert_equal user.id, User.find_by_confirmation_token(token_in(link)).id
            # Until it is opened, the right password signs nobody in.
            post "/session", params: { email_address: "ann@example.com", password: "s3cr3t-s3cr3t" }
            assert_redirected_to "/session/new"
            assert_equal 0, Session.count
          end
        RUBY
      end

      # --invite-only's first test: /setup's user is confirmed and signed in.
      def self.confirmations_setup_test
        <<~'RUBY'
          # /setup answers only while no user exists: this test starts without
          # the fixtures' users.
          test "/setup makes a confirmed first user, and mails nothing" do
            User.all.delete_all
            post "/setup", params: { token: SetupController.setup_token,
                                     user: { email_address: "ann@example.com", password: "s3cr3t-s3cr3t", password_confirmation: "s3cr3t-s3cr3t" } }
            assert_redirected_to "/"
            assert_equal true, User.first.confirmed?
            assert signed_in?("ann@example.com")
            assert_no_enqueued_jobs "cybertrain mail"
            # Signed out, the same password signs in again.
            sign_out
            post "/session", params: { email_address: "ann@example.com", password: "s3cr3t-s3cr3t" }
            assert_redirected_to "/"
          end
        RUBY
      end
    end
  end
end
