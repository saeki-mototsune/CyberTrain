# Cybertrain::Mailer::Base -- mailer classes, as Rails writes them
# (docs/design.md D98):
#
#     class ApplicationMailer < Cybertrain::Mailer::Base
#       default from: "notifications@example.com"
#       layout "mailer"
#     end
#
#     class UserMailer < ApplicationMailer
#       def welcome
#         @user = params[:user]
#         attachments["terms.pdf"] = File.binread("public/terms.pdf")
#         mail(to: @user.email_address, subject: "Welcome")
#       end
#     end
#
#     UserMailer.with(user: user).welcome.deliver_later
#
# Spinel has no method_missing, so `UserMailer.welcome` and `.with` are not
# found at run time: gen reads app/mailers as text (Gen::MailerScan) and
# writes them into gen/mailers.rb, with the class's view path, layout,
# default sender and the `view_assigns` its views read (Gen::MailersEmitter).
# This file is the base those generated methods call. It renders through
# Cybertrain::Views (the core), so cybertrain/mailer.rb, which sends mail
# with or without the framework, does not load it: gen/app.rb requires it
# before the mailers when app/mailers holds a mailer class, and
# `require "cybertrain"` loads it.
require "cybertrain/mailer"
require "cybertrain/cast"
require "cybertrain/views"
require "cybertrain/i18n"

module Cybertrain
  class Mailer
    # The base of an application's mailers (`ApplicationMailer <
    # Cybertrain::Mailer::Base`, Rails' ActionMailer::Base). An action is a
    # public instance method that ends with {#mail}; `spin run gen` writes
    # the class methods that build its message ({MailMessage}), so
    # `UserMailer.welcome(user)` and `UserMailer.with(user: user).welcome`
    # answer the message, rendered now, to `deliver_now` or `deliver_later`.
    # @api public
    class Base
      # `default from: "x@example.com"` in the class body: gen writes the
      # value into the class's `mailer_default_from` (one line; the
      # expression is read each time a mail is built). Only `from:` is
      # taken. A no-op here.
      # @return [nil]
      # @api public
      # `mail`'s default for `body:` when none is given (a NUL, which no
      # body may hold), so `body: ""` sends an empty text without views.
      NO_BODY = "\0"

      def self.default(from: "")
        nil
      end

      # `layout "mailer"`: the views are wrapped in
      # app/views/layouts/mailer.html.erb and mailer.text.erb (each when it
      # exists). Read by gen, inherited; a no-op here.
      # @return [nil]
      # @api public
      def self.layout(name)
        nil
      end

      def initialize
        seed = { mailer: nil }
        seed.clear
        @params = seed
        @mailer_action = ""
        @attachments = Attachments.new
        @mail_message = MailMessage.skipped("", "")
        @mail_called = false
      end

      # What `UserMailer.with(user: user, url: url)` was given, by Symbol
      # (`params[:user]`); empty without `with`.
      # @return [Hash{Symbol => Object}]
      # @api public
      def params
        @params
      end

      # The files of the mail this action builds: `attachments["x.pdf"] =
      # bytes`, `attachments.inline["logo.png"] = bytes`. Set them before
      # {#mail}.
      # @return [Attachments]
      # @api public
      def attachments
        @attachments
      end

      # The action being run ("welcome"), as Rails' action_name.
      # @return [String]
      # @api public
      def action_name
        @mailer_action
      end

      # Builds the mail: the headers given here, the bodies rendered from
      # `app/views/<mailer_path>/<action>.text.erb` and `.html.erb` (both:
      # multipart/alternative; one: that part alone), each in the class's
      # layout when it has one with that extension, with the action's
      # instance variables, and the attachments set so far. With `body:`
      # no view is read: the text is the body. The answer is the message
      # the generated class method returns.
      # @example
      #   mail(to: @user.email_address, subject: "Welcome")
      # @param to [String] one address, or several separated by commas
      # @param subject [String] "" for the dictionary's
      #   `<mailer>.<action>.subject`, else the action's name humanized
      #   ("Welcome email"), as Rails does
      # @param from [String] "" for the class's `default from:`, else
      #   Config#smtp_from
      # @param body [String] a plain-text body instead of the views (`""`
      #   too: an empty text, no view read)
      # @param template_name [String] the view's name instead of the action's
      # @param template_path [String] the view directory instead of the
      #   class's (`user_mailer`)
      # @return [MailMessage]
      # @raise [Cybertrain::Template::MissingTemplate] when the action has
      #   neither view (and no `body:`)
      # @api public
      def mail(to:, subject: "", from: "", body: NO_BODY, template_name: "", template_path: "")
        sender = from.to_s
        sender = mailer_default_from.to_s if sender.empty?
        title = subject.to_s
        title = Base.default_subject(mailer_path, @mailer_action) if title.empty?
        text = body.to_s
        html = ""
        if text == NO_BODY
          text = ""
          name = template_name.to_s
          name = @mailer_action if name.empty?
          dir = template_path.to_s
          dir = mailer_path if dir.empty?
          view = "#{dir}/#{name}"
          html_view = "#{view}.html.erb"
          text_view = "#{view}.text.erb"
          has_html = Views.view_exists?(html_view)
          has_text = Views.view_exists?(text_view)
          unless has_html || has_text
            raise Template::MissingTemplate, "Missing template #{html_view} or #{text_view} for #{mailer_class_name}##{@mailer_action}"
          end

          assigns = view_assigns
          layout = mailer_layout
          html = Views.render_mailer_view(html_view, assigns, layout.empty? ? "" : "layouts/#{layout}.html.erb") if has_html
          text = Views.render_mailer_view(text_view, assigns, layout.empty? ? "" : "layouts/#{layout}.text.erb") if has_text
        end
        message = MailMessage.new(to: to.to_s, subject: title, body: text, html: html, from: sender,
                                  attachments: @attachments.attachment_list)
        message.mark_origin(mailer_class_name, @mailer_action)
        @mail_message = message
        @mail_called = true
        message
      end

      # The dictionary's `<scope>.<action>.subject` (scope the view path with
      # dots: "admin.notice_mailer"), else the action humanized.
      # @return [String]
      def self.default_subject(path, action)
        words = action.tr("_", " ")
        fallback = words.empty? ? "" : "#{words[0, 1].to_s.upcase}#{words[1, words.size - 1]}"
        key = "#{path.tr("/", ".")}.#{action}.subject"
        I18n.t(key, { default: fallback }).to_s
      end

      # Before the action runs (the generated class methods): its params
      # and name.
      # @return [nil]
      def mailer_setup(params, action)
        @params = params
        @mailer_action = action.to_s
        nil
      end

      # After the action: the message {#mail} built, or a skipped one
      # ({MailMessage.skipped}) when the action returned without calling it.
      # @return [MailMessage]
      def mailer_result
        return @mail_message if @mail_called

        MailMessage.skipped(mailer_class_name, @mailer_action)
      end

      # The generated half overrides these (gen/mailers.rb).

      # @return [String] "UserMailer"
      def mailer_class_name
        ""
      end

      # @return [String] the view directory, "user_mailer"
      def mailer_path
        ""
      end

      # @return [String] the layout's name, "" for none
      def mailer_layout
        ""
      end

      # @return [String] the `default from:` value, "" for Config#smtp_from
      def mailer_default_from
        ""
      end

      # What the views read: the action's instance variables by name.
      # @return [Hash{String => Object}]
      def view_assigns
        Cast.empty_hash
      end
    end
  end
end
