# Cybertrain::MailMessage's fields and deliver_now: the part of the class
# cybertrain/mailer.rb needs, because a delivery in the test environment
# stores a MailMessage in Mailer.deliveries. cybertrain/mailer.rb requires
# this file at its end; {MailMessage#deliver_later} is added by
# cybertrain/mailer/later.rb (the job queue, SQLite through FFI), so a
# program that only sends mail still links no SQLite.
#
# Applications have this half with require "cybertrain/mailer" and the
# other with require "cybertrain/mailer/later" (cybertrain and
# cybertrain/mail_message load both).

module Cybertrain
  # One mail, built now and sent later or at once: what a generated mailer
  # method returns, so application code reads as in Rails:
  #
  #     PasswordsMailer.reset(user, url).deliver_later
  #
  # {#deliver_later} is {Mailer.deliver_later} (the built-in "cybertrain
  # mail" job, so it needs the database); {#deliver_now} is
  # {Mailer.deliver} with the settings in {Config}. In the test
  # environment each delivery is stored in {Mailer.deliveries} as one of
  # these.
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
    # @return [String] the sender, "" for Config#smtp_from (a message in
    #   {Mailer.deliveries} has the sender it was delivered with)
    # @api public
    attr_reader :mail_from

    # @return [Array<Mailer::Attachment>] the attached files, in order
    #   (none for a message without)
    # @api public
    attr_reader :mail_attachments
    # @return [String] the mailer class that built the message
    #   ("UserMailer"), "" for one built by hand
    # @api public
    attr_reader :mail_mailer_name
    # @return [String] the mailer action that built it ("welcome"), "" for
    #   one built by hand
    # @api public
    attr_reader :mail_action

    # Keeps the fields; nothing is checked or sent until a deliver call.
    # @example
    #   Cybertrain::MailMessage.new(to: user.email, subject: "Welcome", body: text, html: html)
    # @param to [String] one address, or several separated by commas
    # @param subject [String] UTF-8
    # @param body [String] UTF-8 plain text
    # @param html [String] UTF-8 HTML, "" for a plain-text message
    # @param from [String] the sender; "" for Config#smtp_from
    # @param attachments [Array<Mailer::Attachment>] the files to attach
    # @api public
    def initialize(to:, subject:, body:, html: "", from: "", attachments: Mailer::Attachment.none)
      @mail_to = to.to_s
      @mail_subject = subject.to_s
      @mail_body = body.to_s
      @mail_html = html.to_s
      @mail_from = from.to_s
      @mail_attachments = attachments
      @mail_mailer_name = ""
      @mail_action = ""
      @mail_skipped = false
    end

    # The message of a mailer action that did not call `mail` (Rails'
    # null mail): delivering it sends nothing.
    # @return [MailMessage]
    # @api public
    def self.skipped(mailer_name, action)
      message = MailMessage.new(to: "", subject: "", body: "")
      message.mark_origin(mailer_name, action)
      message.mark_skipped
      message
    end

    # True for {.skipped}'s message: {#deliver_now} and {#deliver_later}
    # do nothing.
    # @return [Boolean]
    # @api public
    def mail_skipped?
      @mail_skipped
    end

    # Records the mailer and action that built the message (Mailer::Base).
    # @return [nil]
    def mark_origin(mailer_name, action)
      @mail_mailer_name = mailer_name.to_s
      @mail_action = action.to_s
      nil
    end

    # @return [nil]
    def mark_skipped
      @mail_skipped = true
      nil
    end

    # Sends the message now, with the settings in {Config}
    # ({Mailer.deliver_message}). A skipped message sends nothing.
    # @example
    #   WelcomeMailer.welcome(user).deliver_now
    # @return [nil]
    # @raise [Mailer::Error] a subclass, when the server cannot be reached or
    #   refuses the message
    # @raise [ArgumentError] for an address, subject or body refused
    # @api public
    def deliver_now
      return nil if @mail_skipped

      Mailer.deliver_message(self)
      nil
    end
  end
end
