require "socket"
require "stringio"
require "cybertrain"
require "cybertrain/mailer/later"
require "cybertrain/test"
require "cybertrain/test/smtp_receiver"

# Mailer.deliver_later: the built-in "cybertrain mail" job, registered when
# cybertrain/mailer/later is required (cybertrain.rb requires it), worked through Job.work_one against
# Cybertrain::Test::SmtpReceiver. Its policy is the generated-style arm
# table of Mailer.run_mail_job: a TimeoutError or ConnectError is retried
# after 60 s up to 5 attempts, a RejectedError discards the row, anything
# else follows the default policy. Jobs are worked with chosen epoch
# times, so nothing sleeps. It links SQLite through FFI, so its snapshot
# comes from the compiled binary (spikes/NOTES.md rule 23).

LOG = StringIO.new
Cybertrain.logger = Cybertrain::Logger.new(LOG)
# The mail goes to an SmtpReceiver: the SMTP path, whatever CYBERTRAIN_ENV
# says (the test environment stores mail in Mailer.deliveries instead).
Cybertrain.config.mail_delivery_method = :smtp

def fresh_db
  Cybertrain::DB.connect(":memory:")
  nil
end

def job_column(id, column)
  rows = Cybertrain::DB.with { |c| c.execute("SELECT #{column} AS v FROM cybertrain_jobs WHERE id = ?", [id]) }
  Cybertrain::Cast.str(rows[0]["v"])
end

def job_number(id, column)
  rows = Cybertrain::DB.with { |c| c.execute("SELECT #{column} AS v FROM cybertrain_jobs WHERE id = ?", [id]) }
  Cybertrain::Cast.int(rows[0]["v"])
end

def smtp_to(port)
  c = Cybertrain.config
  c.smtp_host = "127.0.0.1"
  c.smtp_port = port
  c.smtp_tls = "none"
  c.smtp_from = "config@example.com"
  nil
end

def smtp_reset
  c = Cybertrain.config
  c.smtp_host = ""
  c.smtp_port = 0
  c.smtp_tls = "starttls"
  c.smtp_from = ""
  nil
end

# A port nothing listens on: a delivery to it is a ConnectError.
def closed_port
  gone = TCPServer.new("127.0.0.1", 0)
  port = gone.addr[1]
  gone.close
  port
end

# "ok", or "argument: <message>" when the block raises ArgumentError (the
# rescue in a method that receives the block as a Proc: NOTES rule 32).
def enqueue_kind(&action)
  action.call
  "ok"
rescue ArgumentError => e
  "argument: #{e.message}"
end

# The mail job with a short timeout: the same arms, reached in 0.3 s.
Cybertrain::Job.register("quick mail", max_attempts: 5) { |run| Cybertrain::Mailer.mail_job_with_timeout(run, 0.3) }

test "the mail job is registered when cybertrain/mailer/later is required" do
  index = Cybertrain::Job.handler_index("cybertrain mail")
  assert index >= 0
  assert_equal 5, Cybertrain::Job::HANDLERS[index].handler_max_attempts
end

test "deliver_later enqueues cybertrain mail and work_one delivers it" do
  fresh_db
  smtp = Cybertrain::Test::SmtpReceiver.new
  smtp_to(smtp.start)
  id = Cybertrain::Mailer.deliver_later(to: "bob@example.org", subject: "Café", body: "Hello Bob,\n",
                                        html: "<p>Hello <b>Bob</b></p>")
  assert id > 0
  assert_equal "cybertrain mail", job_column(id, "kind")
  assert_equal "queued", job_column(id, "state")
  payload = JSON.parse(job_column(id, "payload"))
  assert_equal "bob@example.org", Cybertrain::Cast.str(payload["to"])
  assert_equal "Café", Cybertrain::Cast.str(payload["subject"])
  assert_equal "Hello Bob,\n", Cybertrain::Cast.str(payload["body"])
  assert_equal "<p>Hello <b>Bob</b></p>", Cybertrain::Cast.str(payload["html"])
  assert_equal "", Cybertrain::Cast.str(payload["from"])
  assert Cybertrain::Job.work_one(Time.now.to_i)
  mail = smtp.received_message
  smtp.stop
  smtp_reset
  assert_equal "done", job_column(id, "state")
  assert_equal "config@example.com", mail.envelope_from
  assert_equal ["bob@example.org"], mail.envelope_recipients
  parts = mail.message_parts
  assert_equal "Café", parts["subject"]
  assert_equal "Hello Bob,\r\n", parts["text"]
  assert_equal "<p>Hello <b>Bob</b></p>\r\n", parts["html"]
end

test "deliver_later with from: and no html sends the plain message" do
  fresh_db
  smtp = Cybertrain::Test::SmtpReceiver.new
  smtp_to(smtp.start)
  id = Cybertrain::Mailer.deliver_later(to: "bob@example.org", subject: "Plain", body: "just text", from: "boss@example.com")
  assert Cybertrain::Job.work_one(Time.now.to_i)
  mail = smtp.received_message
  smtp.stop
  smtp_reset
  assert_equal "done", job_column(id, "state")
  assert_equal "boss@example.com", mail.envelope_from
  assert_equal "text/plain; charset=UTF-8", mail.message_header("Content-Type")
  assert_equal "just text\r\n", mail.message_parts["text"]
end

test "deliver_later refuses what deliver would refuse, before anything is enqueued" do
  fresh_db
  assert enqueue_kind { Cybertrain::Mailer.deliver_later(to: "bob@example.org", subject: "a\r\nBcc: e@example.net", body: "b") }.start_with?("argument")
  assert enqueue_kind { Cybertrain::Mailer.deliver_later(to: "bob@example.org\nBcc: e@example.net", subject: "s", body: "b") }.start_with?("argument")
  assert enqueue_kind { Cybertrain::Mailer.deliver_later(to: "bob@example.org", subject: "s", body: "b", from: "x>") }.start_with?("argument")
  assert enqueue_kind { Cybertrain::Mailer.deliver_later(to: "bob@example.org", subject: "s", body: "caf\xC3") }.start_with?("argument")
  assert enqueue_kind { Cybertrain::Mailer.deliver_later(to: "bob@example.org", subject: "s", body: "b", html: "a\u0000b") }.start_with?("argument")
  assert_equal 0, Cybertrain::Job.state_count("queued")
end

test "a rejected address discards; a connection failure requeues" do
  fresh_db
  smtp = Cybertrain::Test::SmtpReceiver.new(reject: { rcpt: "550 5.1.1 no such user" })
  smtp_to(smtp.start)
  rejected = Cybertrain::Mailer.deliver_later(to: "nobody@example.org", subject: "s", body: "b")
  t = Time.now.to_i + 100
  assert Cybertrain::Job.work_one(t)
  smtp.received_message
  smtp.stop
  assert_equal "discarded", job_column(rejected, "state")
  assert_includes job_column(rejected, "last_error"), "RejectedError: "
  assert_includes job_column(rejected, "last_error"), "550 5.1.1 no such user"

  smtp_to(closed_port)
  refused = Cybertrain::Mailer.deliver_later(to: "bob@example.org", subject: "s", body: "b")
  assert Cybertrain::Job.work_one(t + 1000)
  assert_equal "queued", job_column(refused, "state")
  assert_equal t + 1060, job_number(refused, "run_at")
  assert_equal 1, job_number(refused, "attempts")
  assert_includes job_column(refused, "last_error"), "ConnectError: "
  refute Cybertrain::Job.work_one(t + 1059)
  # The fifth attempt is the last: the row is failed.
  Cybertrain::DB.with { |c| c.execute("UPDATE cybertrain_jobs SET attempts = 4 WHERE id = ?", [refused]) }
  assert Cybertrain::Job.work_one(t + 1060)
  assert_equal "failed", job_column(refused, "state")
  assert_equal 5, job_number(refused, "attempts")
  smtp_reset
end

test "a 4xx reply (greylisting) requeues; a 5xx one still discards" do
  fresh_db
  smtp = Cybertrain::Test::SmtpReceiver.new(reject: { rcpt: "451 4.7.1 greylisted, try again later" })
  smtp_to(smtp.start)
  greylisted = Cybertrain::Mailer.deliver_later(to: "bob@example.org", subject: "s", body: "b")
  t = Time.now.to_i + 100
  assert Cybertrain::Job.work_one(t)
  smtp.received_message
  smtp.stop
  assert_equal "queued", job_column(greylisted, "state")
  assert_equal t + 60, job_number(greylisted, "run_at")
  assert_includes job_column(greylisted, "last_error"), "451 4.7.1 greylisted"

  refusing = Cybertrain::Test::SmtpReceiver.new(reject: { greeting: "554 5.3.2 no service here" })
  smtp_to(refusing.start)
  assert Cybertrain::Job.work_one(t + 60)
  refusing.received_message
  refusing.stop
  smtp_reset
  assert_equal "discarded", job_column(greylisted, "state")
  assert_includes job_column(greylisted, "last_error"), "554 5.3.2 no service here"
end

test "a timeout requeues after 60 s" do
  fresh_db
  # Listening, never accepting: the connect succeeds, the greeting never comes.
  silent = TCPServer.new("127.0.0.1", 0)
  smtp_to(silent.addr[1])
  id = Cybertrain::Job.enqueue("quick mail", JSON.generate({ "to" => "bob@example.org", "subject" => "s", "body" => "b",
                                                             "html" => "", "from" => "" }))
  t = Time.now.to_i + 100
  assert Cybertrain::Job.work_one(t)
  silent.close
  smtp_reset
  assert_equal "queued", job_column(id, "state")
  assert_equal t + 60, job_number(id, "run_at")
  assert_includes job_column(id, "last_error"), "TimeoutError: "
end

test "a payload that fails the checks when the job runs is discarded, nothing sent" do
  fresh_db
  smtp = Cybertrain::Test::SmtpReceiver.new(accept_window: 1.0)
  smtp_to(smtp.start)
  # As if the row had been changed in the database after deliver_later.
  id = Cybertrain::Job.enqueue("cybertrain mail", JSON.generate({ "to" => "bob@example.org", "subject" => "s\r\nBcc: evil@example.net",
                                                                  "body" => "b", "html" => "", "from" => "" }))
  assert Cybertrain::Job.work_one(Time.now.to_i + 100)
  assert_nil smtp.received_message(0.5)
  smtp.stop
  smtp_reset
  assert_equal "discarded", job_column(id, "state")
  assert_includes job_column(id, "last_error"), "ArgumentError: the subject contains CR, LF or NUL"
end

Cybertrain::Test.run!
