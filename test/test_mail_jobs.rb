ENV["CYBERTRAIN_ENV"] = "test"
ENV.delete("CYBERTRAIN_MAIL_DELIVERY_METHOD")
require "stringio"
require "cybertrain"
require "cybertrain/test_help"
require "cybertrain/test/smtp_receiver"

# Mail and jobs in tests (spec section 10, acceptance 7; plan decisions
# D12 and D13): in the test environment a delivery is stored in
# Mailer.deliveries instead of connecting, cleared before every test;
# assert_emails / assert_no_emails count what a block delivered, the
# deliver_later jobs it queued included; perform_enqueued_jobs with a block
# runs what the block queued, whatever its run_at. Links SQLite through
# FFI, so its snapshot comes from the compiled binary (spikes/NOTES.md
# rule 23). Each block's locals have names of their own (rule 63).

Cybertrain.logger = Cybertrain::Logger.new(StringIO.new)
# The sender every delivery here uses (a mail without one is refused, in
# the test environment as anywhere).
Cybertrain.config.smtp_from = "noreply@example.com"

# What the handlers below ran, in order (a constant: NOTES rule 64).
PERFORMED = Array.new(0) { "" }

Cybertrain::Job.register("early") { |run| PERFORMED << "early" }
Cybertrain::Job.register("leaf") { |run| PERFORMED << "leaf" }
# Queues "leaf", due now: a job queued by a job the block queued.
Cybertrain::Job.register("chain") do |run|
  PERFORMED << "chain"
  Cybertrain::Job.enqueue("leaf", "{}")
end
# Always raises.
Cybertrain::Job.register("boom") do |run|
  PERFORMED << "boom"
  raise "always"
end
# Raises on its first attempt only.
Cybertrain::Job.register("flaky") do |run|
  PERFORMED << "flaky #{run.run_attempts}"
  raise ArgumentError, "not yet" if run.run_attempts == 1
end
# The clock the job ran at.
Cybertrain::Job.register("stamp") { |run| PERFORMED << "stamp #{Time.current.to_i}" }
# An application job with `discard_on ArgumentError`: the arms the job
# generator writes (cybertrain/generator/jobs_emitter.rb), in a method
# that takes no block (NOTES rules 32, 45).
def run_discarding(run)
  begin
    PERFORMED << "discarding"
    raise ArgumentError, "no longer wanted"
  rescue ::ArgumentError => e
    Cybertrain::Job.discard(run, e)
  end
  nil
end
Cybertrain::Job.register("discarding") { |run| run_discarding(run) }

def fresh_db
  Cybertrain::DB.connect(":memory:")
  PERFORMED.pop until PERFORMED.empty?
  nil
end

def hello_mail(subject)
  Cybertrain::MailMessage.new(to: "a@example.com", subject: subject, body: "b")
end

test "in the test environment deliver stores the message" do
  # No database yet: assert_emails counts deliver_now without one.
  refute Cybertrain::DB.connected?
  assert_emails(1) { hello_mail("No database").deliver_now }
  Cybertrain::Mailer.deliveries.clear
  assert_equal :test, Cybertrain.config.mail_delivery_method
  # No SMTP host is configured: nothing connects.
  assert_equal "", Cybertrain.config.smtp_host
  reply = Cybertrain::Mailer.deliver(to: "a@example.com", subject: "Hi", body: "x")
  assert_equal "250 2.0.0 stored in Mailer.deliveries", reply
  assert_equal 1, Cybertrain::Mailer.deliveries.size
  stored = Cybertrain::Mailer.deliveries[0]
  assert_equal "Hi", stored.mail_subject
  assert_equal "a@example.com", stored.mail_to
  assert_equal "x", stored.mail_body
  assert_equal "", stored.mail_html
  assert_equal "noreply@example.com", stored.mail_from
  # The checks run as for SMTP: a refused address raises, nothing is stored.
  refused = assert_raises(ArgumentError) { Cybertrain::Mailer.deliver(to: "not an address", subject: "Hi", body: "x") }
  assert_includes refused, "address"
  assert_raises(ArgumentError) { Cybertrain::Mailer.deliver(to: "a@example.com", subject: "a\nb", body: "x") }
  assert_equal 1, Cybertrain::Mailer.deliveries.size
  # deliver_now and an explicit from: and html:.
  Cybertrain::MailMessage.new(to: "b@example.com", subject: "Two", body: "t", html: "<p>t</p>", from: "app@example.com").deliver_now
  last = Cybertrain::Mailer.deliveries.last
  assert_equal "app@example.com", last.mail_from
  assert_equal "<p>t</p>", last.mail_html
  # A Mailer made with the method given keeps it.
  assert_equal :test, Cybertrain::Mailer.new.mail_delivery_method
  assert_equal :smtp, Cybertrain::Mailer.new(host: "smtp.example.com", delivery_method: :smtp).mail_delivery_method
  unknown = assert_raises(ArgumentError) { Cybertrain::Mailer.new(delivery_method: :letter_opener) }
  assert_equal "delivery_method must be :smtp or :test (got :letter_opener)", unknown
end

test "deliveries are cleared before every test" do
  assert_equal 0, Cybertrain::Mailer.deliveries.size
end

test "assert_emails counts deliver_later in the block" do
  fresh_db
  # Queued before the block: not the block's, so it stays queued.
  hello_mail("Before").deliver_later
  assert_emails(1) { Cybertrain::MailMessage.new(to: "a@example.com", subject: "S", body: "b").deliver_later }
  assert_equal 1, Cybertrain::Mailer.deliveries.size
  assert_equal "S", Cybertrain::Mailer.deliveries[0].mail_subject
  assert_enqueued_jobs 1, "cybertrain mail"
  # deliver_now in the block counts too; so do two at once.
  assert_emails(2) do
    hello_mail("Now").deliver_now
    hello_mail("Later").deliver_later
  end
  failed = assert_raises("AssertionFailed") { assert_emails(2) { hello_mail("One").deliver_later } }
  assert_equal "Expected 2 emails, got 1", failed
  # Without a block: the deliveries so far in this test.
  assert_emails 4
  # A job of another kind queued in the block is not performed.
  assert_emails(0) { Cybertrain::Job.enqueue("early", "{}") }
  assert_enqueued_jobs 1, "early"
  assert_equal 0, PERFORMED.size
end

test "assert_no_emails" do
  fresh_db
  assert_no_emails { nil }
  assert_no_emails { Cybertrain::Job.enqueue("early", "{}") }
  failed_none = assert_raises("AssertionFailed") { assert_no_emails { hello_mail("Oops").deliver_later } }
  assert_equal "Expected 0 emails, got 1", failed_none
end

test "the :smtp opt-out reaches the SmtpReceiver" do
  receiver = Cybertrain::Test::SmtpReceiver.new
  c = Cybertrain.config
  c.mail_delivery_method = :smtp
  c.smtp_host = "127.0.0.1"
  c.smtp_port = receiver.start
  c.smtp_tls = "none"
  reply = Cybertrain::Mailer.deliver(to: "a@example.com", subject: "Wire", body: "x")
  got = receiver.received_message
  receiver.stop
  c.mail_delivery_method = :test
  c.smtp_host = ""
  c.smtp_port = 0
  c.smtp_tls = "starttls"
  assert reply.start_with?("250"), reply
  assert_equal "Wire", got.message_header("Subject")
  assert_equal 0, Cybertrain::Mailer.deliveries.size
end

test "perform_enqueued_jobs with a block runs jobs queued in it, the jobs they queue and a future run_at, not earlier jobs" do
  fresh_db
  Cybertrain::Job.enqueue("early", "{}")
  performed = perform_enqueued_jobs { Cybertrain::Job.enqueue("chain", "{}", run_at: 1.day.from_now) }
  assert_equal 2, performed
  assert_equal ["chain", "leaf"], PERFORMED
  assert_enqueued_jobs 1
  assert_enqueued_jobs 1, "early"
  # A block that queues nothing performs nothing.
  assert_equal 0, perform_enqueued_jobs { nil }
  # Mail queued in the block is delivered (stored) too.
  mailed = perform_enqueued_jobs { hello_mail("Job").deliver_later }
  assert_equal 1, mailed
  assert_equal "Job", Cybertrain::Mailer.deliveries[0].mail_subject
end

test "the block-less form still runs due jobs at a given time" do
  fresh_db
  Cybertrain::Job.enqueue("early", "{}", run_at: Time.at(5000))
  assert_equal 0, perform_enqueued_jobs(Time.at(4000))
  assert_equal 1, perform_enqueued_jobs(Time.at(6000))
  assert_equal ["early"], PERFORMED
  Cybertrain::Job.enqueue("leaf", "{}")
  assert_equal 1, perform_enqueued_jobs
end

test "Job.work_one_after claims above the floor whatever the run_at, of a kind when given" do
  fresh_db
  below = Cybertrain::Job.enqueue("early", "{}")
  Cybertrain::Job.enqueue("leaf", "{}", run_at: 1.day.from_now)
  Cybertrain::Job.enqueue("early", "{}", run_at: 2.days.from_now)
  assert Cybertrain::Job.work_one_after(below, "early")
  assert_equal ["early"], PERFORMED
  assert Cybertrain::Job.work_one_after(below)
  assert_equal ["early", "leaf"], PERFORMED
  refute Cybertrain::Job.work_one_after(below)
  assert_enqueued_jobs 1, "early"
end

test "a job that raises fails perform_enqueued_jobs with its kind and error, performed once" do
  fresh_db
  boom = assert_raises("AssertionFailed") { perform_enqueued_jobs { Cybertrain::Job.enqueue("boom", "{}") } }
  assert_equal "perform_enqueued_jobs: the job \"boom\" (id 1) raised RuntimeError: always (now queued)", boom
  assert_equal ["boom"], PERFORMED
end

test "a job that fails once is not retried in the block; its retry runs once travel_to brings it due" do
  fresh_db
  flaky = assert_raises("AssertionFailed") { perform_enqueued_jobs { Cybertrain::Job.enqueue("flaky", "{}") } }
  assert_equal "perform_enqueued_jobs: the job \"flaky\" (id 1) raised ArgumentError: not yet (now queued)", flaky
  assert_equal ["flaky 1"], PERFORMED
  # The retry waits for its run_at (60 s), on the test's clock.
  refute Cybertrain::Job.work_one_after(0)
  travel_to(2.minutes.from_now) { assert Cybertrain::Job.work_one_after(0) }
  assert_equal ["flaky 1", "flaky 2"], PERFORMED
  assert_no_enqueued_jobs
end

test "the count is distinct jobs, and jobs run at the test's clock" do
  fresh_db
  three = perform_enqueued_jobs do
    Cybertrain::Job.enqueue("leaf", "{}")
    Cybertrain::Job.enqueue("leaf", "{}")
    Cybertrain::Job.enqueue("early", "{}", run_at: 1.day.from_now)
  end
  assert_equal 3, three
  travel_to(Time.at(2_000_000_000)) do
    assert_equal 1, perform_enqueued_jobs { Cybertrain::Job.enqueue("stamp", "{}") }
  end
  assert_equal ["leaf", "leaf", "early", "stamp 2000000000"], PERFORMED
end

test "a job the application discards on purpose counts as performed" do
  fresh_db
  assert_equal 1, perform_enqueued_jobs { Cybertrain::Job.enqueue("discarding", "{}") }
  assert_equal ["discarding"], PERFORMED
  state = Cybertrain::DB.with { |c| c.execute("SELECT state FROM cybertrain_jobs WHERE id = 1") }
  assert_equal "discarded", Cybertrain::Cast.str(state[0]["state"])
end

test "a mail job that fails names its error in assert_emails; assert_no_emails without a block" do
  fresh_db
  Cybertrain.config.smtp_from = ""
  nosender = assert_raises("AssertionFailed") { assert_emails(1) { hello_mail("Nobody").deliver_later } }
  Cybertrain.config.smtp_from = "noreply@example.com"
  assert_equal "assert_emails: the job \"cybertrain mail\" (id 1) raised ArgumentError: the from address is empty (now discarded)",
               nosender
  assert_no_emails
  hello_mail("One").deliver_now
  none = assert_raises("AssertionFailed") { assert_no_emails }
  assert_equal "Expected 0 emails, got 1", none
end

# A boot of its own (stage_config's shape in test/boot_stages.rb): the
# warning is logged once outside the test environment.
def mail_boot_log(env)
  c = Cybertrain::Config.new
  c.env = env
  c.database_path = ":memory:"
  c.secret_key_base = "test-mail-jobs-secret"
  c.views_root = "tmp/test_mail_jobs/views"
  c.public_root = "tmp/test_mail_jobs/public"
  c.mail_delivery_method = :test
  views = { "" => "" }
  views.delete("")
  views["pages/index.html.erb"] = "<h1>ok</h1>\n"
  saved = Cybertrain.logger
  sink = StringIO.new
  Cybertrain.logger = Cybertrain::Logger.new(sink)
  app = Cybertrain::Application.new(router: Cybertrain::Router.new, url_resolver: ->(name, args, options) { "/" },
                                    views: views, config: c)
  app.boot
  app.shutdown
  Cybertrain::Runtime.reset!
  Cybertrain.logger = saved
  sink.string
end

test "boot warns about :test delivery outside the test environment, and not in it" do
  fresh_db
  warning = "mail_delivery_method is :test outside the test environment (env production): " \
            "mail is stored in memory (the mailer's deliveries) and not sent"
  production = mail_boot_log("production")
  assert_includes production, warning
  assert_nil production.index("mail_delivery_method", production.index("mail_delivery_method").to_i + 1)
  assert_not_includes mail_boot_log("test"), "mail_delivery_method"
  smtp = Cybertrain::Config.new
  smtp.env = "production"
  smtp.mail_delivery_method = :smtp
  assert_equal "", smtp.mail_delivery_warning
end

Cybertrain::Test.run!
