# `cybertrain generate mailer user welcome reset`: writes
# app/mailers/user_mailer.rb (a `UserMailer < ApplicationMailer` with one
# action per name, each ending in `mail`), its views
# app/views/user_mailer/<action>.html.erb and .text.erb, and
# test/mailers/user_mailer_test.rb (docs/design.md D98), as Rails'
# generator does; app/mailers/application_mailer.rb and the mailer layouts
# (app/views/layouts/mailer.html.erb, mailer.text.erb) when they are
# missing (an existing one is left as it is, --force or not). A name may
# carry a namespace ("admin/notice" -> Admin::NoticeMailer in
# app/mailers/admin/notice_mailer.rb). `spin run gen` then writes the
# class methods (`UserMailer.welcome`, `UserMailer.with(...)`) into
# gen/mailers.rb. It adds `require "cybertrain/mailer"` and `require
# "cybertrain/mailer/later"` to bin/<app>.rb and bin/db.rb when they (or
# `require "cybertrain"`) are not there, and uncomments config/deploy.yml's
# worker role, which sends the mail deliver_later queues
# (Templates.enable_worker_role).
require "cybertrain/generator/inflector"
require "cybertrain/cli/templates"
require "cybertrain/cli/scaffold"
require "cybertrain/cli/helper"

module Cybertrain
  module CLI
    module Mailer
      USAGE = "usage: cybertrain generate mailer NAME [action ...] [--force]"

      # The names no action may take: Gen::MailerScan::RESERVED_ACTIONS and
      # RESERVED_CLASS_METHODS, which gen refuses (copied: the CLI loads
      # no generator file but the inflector; script/check-reserved-names
      # keeps the copy equal).
      RESERVED = ["action_name", "attachments", "mail", "mailer_class_name", "mailer_default_from",
                  "mailer_layout", "mailer_path", "mailer_result", "mailer_setup", "params", "view_assigns",
                  "default", "default_subject", "layout", "new", "with"]

      # Returns the paths written.
      def self.generate(root, name, actions, force = false)
        GeneratedFiles.require_app!(root)

        segments = GeneratedFiles.name_segments(name, "mailer")
        stem = segments.last.delete_suffix("_mailer")
        raise InvalidArgument, "bad mailer name '#{name}'" if stem.empty?

        segments[segments.size - 1] = "#{stem}_mailer"
        modules = segments.map { |s| Inflector.camelize(s) }
        full = modules.join("::")
        # Checked on the class name, so every spelling that camelizes to it
        # ("application", "application_", "Application") is refused.
        if full == "ApplicationMailer"
          raise InvalidArgument, "ApplicationMailer is the base the generator writes when it is missing: give the mailer another name"
        end
        rel = segments.join("/")
        actions.each { |a| check_action(a) }
        files = [["app/mailers/#{rel}.rb", class_source(modules, rel, actions)]]
        actions.each do |a|
          files << ["app/views/#{rel}/#{a}.html.erb", html_view(full, rel, a)]
          files << ["app/views/#{rel}/#{a}.text.erb", text_view(full, rel, a)]
        end
        files << ["test/mailers/#{rel}_test.rb", test_source(full, rel, actions)]
        written = GeneratedFiles.write_all(root, files, force)
        shared = [
          ["app/mailers/application_mailer.rb", APPLICATION_MAILER],
          ["app/views/layouts/mailer.html.erb", HTML_LAYOUT],
          ["app/views/layouts/mailer.text.erb", TEXT_LAYOUT]
        ]
        shared.each do |pair|
          full_path = File.join(root, pair[0])
          if File.exist?(full_path)
            puts "exist #{pair[0]}"
            next
          end
          Templates.mkdir_p(File.dirname(full_path))
          File.write(full_path, pair[1])
          puts "create #{pair[0]}"
          written << pair[0]
        end
        # A mailer class needs cybertrain/mailer, deliver_later
        # cybertrain/mailer/later, in bin/<app>.rb and bin/db.rb,
        Templates.add_requires(root, ["cybertrain/mailer", "cybertrain/mailer/later"])
        # and the worker role sends what deliver_later queues.
        Templates.enable_worker_role(root)
        written
      end

      # An action is a method name the mailer base does not take.
      def self.check_action(action)
        raise InvalidArgument, "bad action name '#{action}'" unless Templates.identifier?(action)
        if RESERVED.include?(action)
          raise InvalidArgument, "'#{action}' is a method of every mailer: give the action another name"
        end

        nil
      end

      APPLICATION_MAILER = <<~RUBY
        # The base of the application's mailers. `default from:` is the
        # sender of every mail that names none (one line; `spin run gen` reads
        # it); without it the sender is Config#smtp_from
        # (CYBERTRAIN_SMTP_FROM). The views are wrapped in
        # app/views/layouts/mailer.html.erb and mailer.text.erb.
        class ApplicationMailer < Cybertrain::Mailer::Base
          default from: "from@example.com"
          layout "mailer"
        end
      RUBY

      HTML_LAYOUT = <<~ERB
        <!DOCTYPE html>
        <html>
          <head>
            <meta http-equiv="Content-Type" content="text/html; charset=utf-8">
            <style>
              /* Email styles need to be inline */
            </style>
          </head>

          <body>
            <%= yield %>
          </body>
        </html>
      ERB

      TEXT_LAYOUT = "<%= yield %>\n"

      def self.class_source(modules, rel, actions)
        body = +""
        body << "class #{modules.last} < ApplicationMailer\n"
        if actions.empty?
          body << "  # An action is a public method that ends with `mail(to:, subject:)`;\n"
          body << "  # its views are app/views/#{rel}/<action>.html.erb and .text.erb.\n"
          body << "  # `spin run gen` writes #{modules.join("::")}.<action> and .with(...)\n"
          body << "  # (gen/mailers.rb).\n"
        end
        actions.each_with_index do |a, i|
          body << "\n" if i > 0
          body << "  # Subject can be set in your I18n file at config/locales/en.yml\n"
          body << "  # with the following lookup:\n"
          body << "  #\n"
          body << "  #   en.#{rel.tr("/", ".")}.#{a}.subject\n"
          body << "  #\n"
          body << "  # #{modules.join("::")}.#{a}.deliver_later sends it from a job;\n"
          body << "  # #{modules.join("::")}.with(user: user).#{a} gives it params[:user].\n"
          body << "  def #{a}\n"
          body << "    @greeting = \"Hi\"\n"
          body << "\n"
          body << "    mail to: \"to@example.org\"\n"
          body << "  end\n"
        end
        body << "end\n"
        GeneratedFiles.nest(modules[0, modules.size - 1], body)
      end

      def self.html_view(full, rel, action)
        out = +""
        out << "<h1>#{full}##{action}</h1>\n"
        out << "\n"
        out << "<p>\n"
        out << "  <%= @greeting %>, find me in app/views/#{rel}/#{action}.html.erb\n"
        out << "</p>\n"
        out
      end

      def self.text_view(full, rel, action)
        out = +""
        out << "#{full}##{action}\n"
        out << "\n"
        out << "<%= @greeting %>, find me in app/views/#{rel}/#{action}.text.erb\n"
        out
      end

      # The class-form test: each action's message, rendered, read back.
      def self.test_source(full, rel, actions)
        out = +""
        out << "require \"test_helper\"\n"
        out << "\n"
        out << "# app/mailers/#{rel}.rb: each action's message, built and rendered.\n"
        out << "class #{full}Test < ActionMailer::TestCase\n"
        if actions.empty?
          out << "  test \"#{full} has a view directory\" do\n"
          out << "    assert_equal \"#{rel}\", #{full}.new.mailer_path\n"
          out << "  end\n"
        end
        actions.each_with_index do |a, i|
          out << "\n" if i > 0
          words = a.tr("_", " ")
          subject = "#{words[0, 1].to_s.upcase}#{words[1, words.size - 1]}"
          out << "  test \"#{a}\" do\n"
          out << "    mail = #{full}.#{a}\n"
          out << "    assert_equal #{subject.inspect}, mail.mail_subject\n"
          out << "    assert_equal \"to@example.org\", mail.mail_to\n"
          out << "    assert_match \"Hi\", mail.mail_body\n"
          out << "    assert_emails 1 do\n"
          out << "      mail.deliver_now\n"
          out << "    end\n"
          out << "  end\n"
        end
        out << "end\n"
        out
      end
    end
  end
end
