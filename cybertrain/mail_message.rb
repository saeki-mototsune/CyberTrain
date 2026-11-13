# Cybertrain::MailMessage -- one mail, built now and sent later or at once:
# what a generated mailer method returns, so application code reads as in
# Rails:
#
#     PasswordsMailer.reset(user, url).deliver_later
#
# {#deliver_now} is {Mailer.deliver} with the settings in {Config}; it is
# part of `require "cybertrain/mailer"`, which loads this file at its end
# (as it does cybertrain/mailer/message.rb). {#deliver_later} is
# {Mailer.deliver_later} (the built-in "cybertrain mail" job, so it needs
# the database and the jobs subsystem): cybertrain/mailer/later.rb reopens
# this class to add it, so an application that only sends mail now
# compiles no job queue.

module Cybertrain
  # A mail's fields, and the two ways to send them.
  # @api public
  class MailMessage
    # @return [String] one address, or several separated by commas
    # @api public
    attr_reader :mail_to
    # @return [String] UTF-8
    # @api public
    attr_reader :mail_subject
    # @return [String] UTF-8 plain text
    # @api public
    attr_reader :mail_body
    # @return [String] UTF-8 HTML, "" for a plain-text message
    # @api public
    attr_reader :mail_html
    # @return [String] the sender, "" for Config#smtp_from
    # @api public
    attr_reader :mail_from

    # Keeps the fields; nothing is checked or sent until a deliver call.
    # @example
    #   Cybertrain::MailMessage.new(to: user.email, subject: "Welcome", body: text, html: html)
    # @param to [String] one address, or several separated by commas
    # @param subject [String] UTF-8
    # @param body [String] UTF-8 plain text
    # @param html [String] UTF-8 HTML, "" for a plain-text message
    # @param from [String] the sender; "" for Config#smtp_from
    # @api public
    def initialize(to:, subject:, body:, html: "", from: "")
      @mail_to = to.to_s
      @mail_subject = subject.to_s
      @mail_body = body.to_s
      @mail_html = html.to_s
      @mail_from = from.to_s
    end

    # Sends the message now, with the settings in {Config} ({Mailer.deliver}).
    # @example
    #   WelcomeMailer.welcome(user).deliver_now
    # @return [nil]
    # @raise [Mailer::Error] a subclass, when the server cannot be reached or
    #   refuses the message
    # @raise [ArgumentError] for an address, subject or body refused
    # @api public
    def deliver_now
      Mailer.deliver(to: @mail_to, subject: @mail_subject, body: @mail_body, html: @mail_html, from: @mail_from)
      nil
    end
  end
end
