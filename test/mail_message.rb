require "stringio"
require "cybertrain"
require "cybertrain/mail_message"
require "cybertrain/test"
require "cybertrain/test/jobs"
require "cybertrain/test/smtp_receiver"

# Cybertrain::MailMessage (plan D16): what a generated mailer method returns,
# so `PasswordsMailer.reset(user, url).deliver_later` reads as in Rails.
# deliver_later enqueues the built-in "cybertrain mail" job
# (Mailer.deliver_later); deliver_now sends at once (Mailer.deliver). It
# links SQLite through FFI, so its snapshot comes from the compiled binary
# (spikes/NOTES.md rule 23).

Cybertrain.logger = Cybertrain::Logger.new(StringIO.new)

def fresh_db
  Cybertrain::DB.connect(":memory:")
  nil
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

def reset_mail
  Cybertrain::MailMessage.new(to: "bob@example.org", subject: "Reset your password",
                              body: "Open the link.\n", html: "<p>Open the link.</p>")
end

test "a mail message keeps its fields, html and from empty by default" do
  m = reset_mail
  assert_equal "bob@example.org", m.mail_to
  assert_equal "Reset your password", m.mail_subject
  assert_equal "Open the link.\n", m.mail_body
  assert_equal "<p>Open the link.</p>", m.mail_html
  assert_equal "", m.mail_from
  plain = Cybertrain::MailMessage.new(to: "ann@example.com", subject: "Hi", body: "text", from: "app@example.com")
  assert_equal "", plain.mail_html
  assert_equal "app@example.com", plain.mail_from
end

test "deliver_later queues the mail and the job sends it" do
  fresh_db
  smtp = Cybertrain::Test::SmtpReceiver.new
  smtp_to(smtp.start)
  id = reset_mail.deliver_later
  assert id > 0
  assert_enqueued_jobs 1, "cybertrain mail"
  assert_enqueued_with "cybertrain mail", { "to" => "bob@example.org", "subject" => "Reset your password",
                                            "body" => "Open the link.\n", "html" => "<p>Open the link.</p>", "from" => "" }
  assert_equal 1, perform_enqueued_jobs
  mail = smtp.received_message
  smtp.stop
  smtp_reset
  assert_no_enqueued_jobs "cybertrain mail"
  assert_equal "Reset your password", mail.message_header("Subject")
  assert_equal "config@example.com", mail.envelope_from
  assert_equal ["bob@example.org"], mail.envelope_recipients
  parts = mail.message_parts
  assert_equal "Open the link.\r\n", parts["text"]
  assert_equal "<p>Open the link.</p>\r\n", parts["html"]
end

test "deliver_later refuses what the mailer would refuse, before anything is queued" do
  fresh_db
  bad = Cybertrain::MailMessage.new(to: "bob@example.org", subject: "a\r\nBcc: e@example.net", body: "b")
  assert_raises("ArgumentError") { bad.deliver_later }
  assert_no_enqueued_jobs
end

test "deliver_now sends at once and queues nothing" do
  fresh_db
  smtp = Cybertrain::Test::SmtpReceiver.new
  smtp_to(smtp.start)
  m = Cybertrain::MailMessage.new(to: "ann@example.com", subject: "Welcome", body: "Hello Ann\n", from: "boss@example.com")
  assert_nil m.deliver_now
  mail = smtp.received_message
  smtp.stop
  smtp_reset
  assert_no_enqueued_jobs
  assert_equal "Welcome", mail.message_header("Subject")
  assert_equal "boss@example.com", mail.envelope_from
  assert_equal ["ann@example.com"], mail.envelope_recipients
  assert_equal "text/plain; charset=UTF-8", mail.message_header("Content-Type")
  assert_equal "Hello Ann\r\n", mail.message_parts["text"]
end

Cybertrain::Test.run!
