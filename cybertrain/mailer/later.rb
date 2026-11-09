# Cybertrain::Mailer.deliver_later -- a mail sent by the job queue: the
# built-in job kind "cybertrain mail", registered when this file is
# required. cybertrain.rb requires it, so an application has it without
# doing anything; it is apart from cybertrain/mailer.rb because the queue
# is cybertrain/job (SQLite through Spinel FFI), and a program that only
# sends mail should neither link SQLite nor stop loading under CRuby.
#
# Registering the kind means a process that runs jobs (`./<app> server`
# unless Config#worker is off, and `./<app> worker`) starts its job threads
# even when the application defines no job of its own.
require "json"
require "cybertrain/cast"
require "cybertrain/job"
require "cybertrain/mailer"

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
    # The job's policy: a {TimeoutError} or {ConnectError} is retried 60
    # seconds later, until 5 attempts have failed; a {RejectedError} (a
    # refused address will not become deliverable) discards the row; any
    # other error follows the default policy ({Job}).
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

    # The "cybertrain mail" job: {.deliver} with the payload's fields, its
    # policy as the rescue arms the job generator writes for `retry_on` /
    # `discard_on` (cybertrain/generator/jobs_emitter.rb), each class
    # anchored at the top level (spikes/NOTES.md rule 89), in a method that
    # takes no block (rules 32, 45).
    # @param run [Job::Run]
    # @return [nil]
    def self.run_mail_job(run)
      args = run.run_args
      to = Cast.str(args["to"])
      subject = Cast.str(args["subject"])
      body = Cast.str(args["body"])
      html = Cast.str(args["html"])
      from = Cast.str(args["from"])
      begin
        Mailer.deliver(to: to, subject: subject, body: body, html: html, from: from)
      rescue ::Cybertrain::Mailer::TimeoutError => e
        Cybertrain::Job.retry_later(run, e, 60, false, 5)
      rescue ::Cybertrain::Mailer::ConnectError => e
        Cybertrain::Job.retry_later(run, e, 60, false, 5)
      rescue ::Cybertrain::Mailer::RejectedError => e
        Cybertrain::Job.discard(run, e)
      end
      nil
    end
  end
end

# The built-in mail job, registered when this file is required; its block
# calls the concrete method (spikes/NOTES.md rule 88).
Cybertrain::Job.register(Cybertrain::Mailer::JOB_KIND, max_attempts: 5) { |run| Cybertrain::Mailer.run_mail_job(run) }
