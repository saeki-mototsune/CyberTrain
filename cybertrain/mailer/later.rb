# Cybertrain::Mailer.deliver_later -- a mail sent by the job queue: the
# built-in job kind "cybertrain mail", registered when this file is
# required. cybertrain.rb requires it, so an application has it without
# doing anything; it is apart from cybertrain/mailer.rb because the queue
# is cybertrain/jobs (SQLite through Spinel FFI, and the core), and a
# program that only sends mail should neither link SQLite nor stop loading
# under CRuby. It requires cybertrain/jobs, not only cybertrain/job, so the
# server role starts the job threads that send it (JobsFeature).
#
# Registering the kind means a process that runs jobs (`./<app> server`
# unless Config#worker is off, and `./<app> worker`) starts its job threads
# even when the application defines no job of its own.
require "json"
require "cybertrain/cast"
require "cybertrain/jobs"
require "cybertrain/mailer"
require "cybertrain/mail_message"

module Cybertrain
  class Mailer
    # The job kind {.deliver_later} enqueues.
    JOB_KIND = "cybertrain mail"

    # Sends one message later, from a job: enqueues the built-in kind
    # "cybertrain mail" with the five fields as a JSON object (`to`,
    # `subject`, `body`, `html`, `from`), and a job thread (`./<app>
    # server` or `./<app> worker`) delivers it with {.deliver} and the
    # settings in {Config} at that time. The fields are checked now, as
    # {.deliver} checks them, so a refused address or subject raises here
    # and nothing is enqueued. Render the bodies before calling
    # ({Views.render_mail}): the job has no view context.
    #
    # The whole message, body and HTML included, is stored in the
    # database (the `cybertrain_jobs` row's payload, shown on the jobs
    # page) until the job finishes, and for as long as the finished row is
    # kept.
    #
    # The job's policy:
    # - a {TimeoutError}, a {ConnectError}, or a {RejectedError} with a 4xx
    #   reply (421, greylisting's 450 / 451, 452: RFC 5321 calls them
    #   transient) is retried 60 seconds later, until 5 attempts have
    #   failed, when the row is `failed`;
    # - a {RejectedError} with a 5xx reply (a refused address will not
    #   become deliverable, a refused login needs the configuration fixed)
    #   discards the row;
    # - an ArgumentError when the job runs (a field the payload can never
    #   send: an empty from: with no Config#smtp_from, no Config#smtp_host,
    #   a payload changed in the database that fails the checks again)
    #   discards the row too, with nothing sent;
    # - any other error follows the default policy ({Job}).
    #
    # One message goes to all the recipients in one SMTP transaction, so
    # when the server refuses one of several recipients with a 5xx, the
    # whole job is discarded and the other recipients do not get the mail
    # either (with a 4xx it is retried for all of them). Enqueue one
    # message per recipient when they should not depend on each other.
    # @example
    #   id = Cybertrain::Mailer.deliver_later(to: user.email, subject: "Welcome", body: text, html: html)
    # @param to [String] one address, or several separated by commas
    # @param subject [String] UTF-8
    # @param body [String] UTF-8 plain text
    # @param html [String] UTF-8 HTML, "" for a plain-text message
    # @param from [String] the sender; "" for Config#smtp_from when the job runs
    # @return [Integer] the job's id
    # @raise [ArgumentError] for an address, subject or body refused
    # @raise [Cybertrain::DB::Error] when the database is not connected or
    #   the insert fails
    # @api public
    def self.deliver_later(to:, subject:, body:, html: "", from: "")
      sender = from.to_s
      recipients = to.to_s
      title = subject.to_s
      text = body.to_s
      markup = html.to_s
      Mailer.check_address(sender, "from") unless sender.empty?
      Mailer.split_recipients(recipients)
      Mailer.check_subject(title)
      Mailer.normalize_body(text)
      Mailer.normalize_body(markup) unless markup.empty?
      fields = { "to" => recipients, "subject" => title, "body" => text, "html" => markup, "from" => sender }
      payload = JSON.generate(fields)
      Job.enqueue(JOB_KIND, payload)
    end

    # The "cybertrain mail" job: {.mail_job_with_timeout} with the
    # mailer's default timeout (10 s each wait).
    # @param run [Job::Run]
    # @return [nil]
    def self.run_mail_job(run)
      Mailer.mail_job_with_timeout(run, 10.0)
    end

    # The job's work: a Mailer with the settings in {Config} and `timeout`
    # seconds a wait sends the payload's fields; its policy is the rescue
    # arms the job generator writes for `retry_on` / `discard_on`
    # (cybertrain/generator/jobs_emitter.rb), each class anchored at the
    # top level (spikes/NOTES.md rule 89), in a method that takes no block
    # (rules 32, 45). The ArgumentError arm comes last: no Mailer error is
    # one. (A parameter rather than a constant so a test can reach the
    # TimeoutError arm quickly.)
    # @param run [Job::Run]
    # @param timeout [Float]
    # @return [nil]
    def self.mail_job_with_timeout(run, timeout)
      args = run.run_args
      to = Cast.str(args["to"])
      subject = Cast.str(args["subject"])
      body = Cast.str(args["body"])
      html = Cast.str(args["html"])
      from = Cast.str(args["from"])
      begin
        mailer = Mailer.new(timeout: timeout)
        mailer.deliver(to: to, subject: subject, body: body, html: html, from: from)
      rescue ::Cybertrain::Mailer::TimeoutError => e
        Cybertrain::Job.retry_later(run, e, 60, false, 5)
      rescue ::Cybertrain::Mailer::ConnectError => e
        Cybertrain::Job.retry_later(run, e, 60, false, 5)
      rescue ::Cybertrain::Mailer::RejectedError => e
        # 5xx is permanent, 4xx transient (RFC 5321 4.2.1).
        if e.smtp_code >= 500
          Cybertrain::Job.discard(run, e)
        else
          Cybertrain::Job.retry_later(run, e, 60, false, 5)
        end
      rescue ::ArgumentError => e
        Cybertrain::Job.discard(run, e)
      end
      nil
    end
  end
end

module Cybertrain
  # The later half of a MailMessage (cybertrain/mail_message.rb), here so
  # the class itself needs only cybertrain/mailer.
  class MailMessage
    # Enqueues the message for a job thread to send ({Mailer.deliver_later}:
    # the fields are checked now, so a refused one raises and nothing is
    # queued).
    # @example
    #   PasswordsMailer.reset(user, url).deliver_later
    # @return [Integer] the job's id
    # @raise [ArgumentError] for an address, subject or body refused
    # @raise [Cybertrain::DB::Error] when the database is not connected or
    #   the insert fails
    # @api public
    def deliver_later
      Mailer.deliver_later(to: @mail_to, subject: @mail_subject, body: @mail_body, html: @mail_html, from: @mail_from)
    end
  end
end

# The built-in mail job, registered when this file is required; its block
# calls the concrete method (spikes/NOTES.md rule 88).
Cybertrain::Job.register(Cybertrain::Mailer::JOB_KIND, max_attempts: 5) { |run| Cybertrain::Mailer.run_mail_job(run) }
