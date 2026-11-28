require "tmpdir"
require "cybertrain/cli"
require "cybertrain/generator/mailer_scan"
require "cybertrain/generator/mailers_emitter"
require "cybertrain/test"
require_relative "support/file_tree"

# `cybertrain generate mailer` (docs/design.md D98): a mailer class under
# app/mailers with one action per name, its views, its test, and the
# application mailer and mailer layouts when they are missing; what gen
# then writes for it.
TMP = Dir.mktmpdir("cybertrain-cli-generate-mailer")
Dir.chdir(TMP)

at_exit do
  Dir.chdir("/")
  FileTree.remove(TMP)
end

Cybertrain::CLI::NewApp.create("shop", "{ path = \"../cybertrain\" }")

def generate(args)
  Dir.chdir("shop") { Cybertrain::CLI.run(["generate", "mailer"] + args) }
end

test "generate mailer user welcome writes the class with one action ending in mail" do
  assert_equal 0, generate(["user", "welcome"])
  assert_equal <<~'RUBY', File.read("shop/app/mailers/user_mailer.rb")
    class UserMailer < ApplicationMailer
      # Subject can be set in your I18n file at config/locales/en.yml
      # with the following lookup:
      #
      #   en.user_mailer.welcome.subject
      #
      # UserMailer.welcome.deliver_later sends it from a job;
      # UserMailer.with(user: user).welcome gives it params[:user].
      def welcome
        @greeting = "Hi"

        mail to: "to@example.org"
      end
    end
  RUBY
end

test "the views, the application mailer and the layouts" do
  assert_equal "<h1>UserMailer#welcome</h1>\n\n<p>\n  <%= @greeting %>, find me in app/views/user_mailer/welcome.html.erb\n</p>\n",
               File.read("shop/app/views/user_mailer/welcome.html.erb")
  assert_equal "UserMailer#welcome\n\n<%= @greeting %>, find me in app/views/user_mailer/welcome.text.erb\n",
               File.read("shop/app/views/user_mailer/welcome.text.erb")
  assert_includes File.read("shop/app/mailers/application_mailer.rb"),
                  "class ApplicationMailer < Cybertrain::Mailer::Base\n  default from: \"from@example.com\"\n  layout \"mailer\"\nend\n"
  assert_includes File.read("shop/app/views/layouts/mailer.html.erb"), "  <body>\n    <%= yield %>\n  </body>\n"
  assert_equal "<%= yield %>\n", File.read("shop/app/views/layouts/mailer.text.erb")
end

test "the test is an ActionMailer::TestCase reading the message back" do
  assert_equal <<~'RUBY', File.read("shop/test/mailers/user_mailer_test.rb")
    require "test_helper"

    # app/mailers/user_mailer.rb: each action's message, built and rendered.
    class UserMailerTest < ActionMailer::TestCase
      test "welcome" do
        mail = UserMailer.welcome
        assert_equal "Welcome", mail.mail_subject
        assert_equal "to@example.org", mail.mail_to
        assert_match "Hi", mail.mail_body
        assert_emails 1 do
          mail.deliver_now
        end
      end
    end
  RUBY
end

test "gen reads what the generator wrote" do
  infos = Cybertrain::Gen::MailerScan.scan_dir("shop/app/mailers")
  assert_equal ["ApplicationMailer", "UserMailer"], infos.map { |i| i.mailer_name }
  out = Cybertrain::Gen::MailersEmitter.emit(infos)
  assert_includes out, "  def self.welcome\n    with({}).welcome\n  end\n"
  assert_includes out, "  def view_assigns\n    { \"greeting\" => @greeting }\n  end\n"
end

test "generate mailer adds the mailer's two lines to bin/shop.rb and bin/db.rb, once" do
  bin = File.read("shop/bin/shop.rb")
  assert_includes bin, "require \"cybertrain/core\"\nrequire \"cybertrain/mailer\"\nrequire \"cybertrain/mailer/later\"\n"
  assert_includes File.read("shop/bin/db.rb"), "require \"cybertrain/mailer\"\nrequire \"cybertrain/mailer/later\"\n"
  assert_includes File.read("shop/config/deploy.yml"), "\n  worker:\n    hosts:\n"
end

test "a second mailer leaves the application mailer and the layouts alone, a namespace nests" do
  File.write("shop/app/mailers/application_mailer.rb", "class ApplicationMailer < Cybertrain::Mailer::Base\nend\n")
  assert_equal 0, generate(["admin/notice", "report", "daily_summary"])
  assert_equal "class ApplicationMailer < Cybertrain::Mailer::Base\nend\n", File.read("shop/app/mailers/application_mailer.rb")
  source = File.read("shop/app/mailers/admin/notice_mailer.rb")
  assert source.start_with?("module Admin\n  class NoticeMailer < ApplicationMailer\n")
  assert_includes source, "    #   en.admin.notice_mailer.daily_summary.subject\n"
  assert File.exist?("shop/app/views/admin/notice_mailer/daily_summary.text.erb")
  assert_includes File.read("shop/test/mailers/admin/notice_mailer_test.rb"),
                  "    assert_equal \"Daily summary\", mail.mail_subject\n"
  assert_equal 1, File.read("shop/bin/shop.rb").scan("require \"cybertrain/mailer\"\n").size
end

test "refusals: a reserved action, a bad name, an existing file without --force" do
  assert_equal 1, generate(["user", "params"])
  assert_equal 1, generate(["user", "9lives"])
  assert_equal 1, generate(["application", "welcome"])
  File.write("shop/app/mailers/user_mailer.rb", "class UserMailer < ApplicationMailer\nend\n")
  assert_equal 1, generate(["user", "welcome"])
  assert_equal 0, generate(["user", "welcome", "--force"])
  assert_includes File.read("shop/app/mailers/user_mailer.rb"), "  def welcome\n"
  assert_equal 1, generate([])
end

Cybertrain::Test.run!
