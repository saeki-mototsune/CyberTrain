require "stringio"
require "cybertrain"
require "cybertrain/test"
require "cybertrain/test/jobs"
require "cybertrain/test/mail"
require "cybertrain/test/smtp_receiver"

# Mailer classes (docs/design.md D98), compiled: the fixture app's
# ApplicationMailer, UserMailer and Admin::NoticeMailer with their
# checked-in gen/mailers.rb (test/gen_mailers.rb checks it is what gen
# writes), in the order gen/app.rb loads them, rendering the fixture's
# views. The mail goes to Mailer.deliveries (:test), to an SmtpReceiver
# for the multipart bytes, and through the "cybertrain mail" job for
# deliver_later, with the mail assertions. SQLite is FFI, so the snapshot comes from the compiled
# binary (spikes/NOTES.md rule 23).
require_relative "fixtures/gen_mailers/app/mailers/application_mailer"
require_relative "fixtures/gen_mailers/app/mailers/admin/notice_mailer"
require_relative "fixtures/gen_mailers/app/mailers/legacy_mailer"
require_relative "fixtures/gen_mailers/app/mailers/user_mailer"
require_relative "fixtures/gen_mailers/gen/mailers"

Cybertrain.logger = Cybertrain::Logger.new(StringIO.new)
Cybertrain::Views.configure("test/fixtures/gen_mailers/app/views", cache: false)

# What the views read from a user.
class MailUser
  attr_reader :name, :email_address

  def initialize(name, email_address)
    @name = name
    @email_address = email_address
  end
end

ANN = MailUser.new("Ann <A>", "ann@example.com")

def to_deliveries
  Cybertrain.config.mail_delivery_method = :test
  Cybertrain::Mailer.deliveries.clear
  nil
end

def smtp_to(port)
  c = Cybertrain.config
  c.mail_delivery_method = :smtp
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

test "a class method runs the action and answers its rendered message" do
  m = UserMailer.welcome(ANN)
  assert_equal "ann@example.com", m.mail_to
  assert_equal "Hello, Ann <A>", m.mail_subject
  assert_equal "notifications@example.com", m.mail_from
  assert_equal "UserMailer", m.mail_mailer_name
  assert_equal "welcome", m.mail_action
  assert_not m.mail_skipped?
  # The HTML view escapes, inside layouts/mailer.html.erb; the text view
  # does not, inside layouts/mailer.text.erb.
  assert_equal "<html><body><p>Hello, Ann &lt;A&gt; &amp; friends</p>\n<img src=\"cid:logo.png\" alt=\"logo\">\n" \
               "<footer>Sent by the fixture app</footer></body></html>\n", m.mail_html
  assert_equal "Hello, Ann <A> & friends <b>\n--\nSent by the fixture app\n", m.mail_body
  assert_equal 2, m.mail_attachments.size
  assert_equal "terms.pdf", m.mail_attachments[0].attachment_filename
  assert_equal "application/pdf", m.mail_attachments[0].attachment_mime_type
  assert_not m.mail_attachments[0].attachment_inline?
  assert_equal "image/png", m.mail_attachments[1].attachment_mime_type
  assert m.mail_attachments[1].attachment_inline?
end

test "positional and keyword parameters pass through" do
  m = UserMailer.welcome(ANN, "Hi", copy: true)
  assert_equal "Hi, Ann <A>", m.mail_subject
  assert_equal "ann@example.com, copy@example.com", m.mail_to
end

test "with(params) gives the action its params" do
  m = UserMailer.with(user: ANN, url: "https://example.com/r/1").reset
  assert_equal "ann@example.com", m.mail_to
  # No subject given: the action's name, humanized.
  assert_equal "Reset", m.mail_subject
  # The text layout's footer reads @footer, which reset does not set.
  # Its partial is _sign.text.erb, unescaped, not the HTML one beside it.
  assert_equal "Reset: https://example.com/r/1\nText & sign\n\n--\n\n", m.mail_body
  # A text view alone: no HTML part.
  assert_equal "", m.mail_html
end

test "an action that returns before mail answers a skipped message that sends nothing" do
  to_deliveries
  m = UserMailer.with(user: MailUser.new("skip", "s@example.com")).reset
  assert m.mail_skipped?
  assert_equal "reset", m.mail_action
  m.deliver_now
  assert_equal 0, m.deliver_later
  assert_equal 0, Cybertrain::Mailer.deliveries.size
end

test "body: skips the views, from: overrides the default" do
  m = UserMailer.plain_note("bob@example.org")
  assert_equal "Just text & <plain>\n", m.mail_body
  assert_equal "other@example.com", m.mail_from
  assert_equal "", m.mail_html
end

test "body: \"\" is an empty text, no view read" do
  m = UserMailer.empty_note("bob@example.org")
  assert_equal "", m.mail_body
  assert_equal "", m.mail_html
  assert_equal "Empty", m.mail_subject
end

test "a text view's partial must exist as .text.erb: the HTML one is not used" do
  message = assert_raises("Cybertrain::Template::RuntimeError") { UserMailer.html_partial_only("bob@example.org") }
  assert message.start_with?("user_mailer/html_partial_only.text.erb:1: Missing template ")
  assert message.end_with?("user_mailer/_html_only.text.erb")
end

test "a namespaced mailer reads its own view directory, layout false" do
  m = Admin::NoticeMailer.report(3)
  assert_equal "<p>3 new</p>\n", m.mail_html
  assert_equal "", m.mail_body
  assert_equal "Admin::NoticeMailer", m.mail_mailer_name
end

test "a mailer module still works beside the classes" do
  assert_equal "Ping", LegacyMailer.ping("bob@example.org").mail_subject
end

test "deliver_now stores the message with its attachments under :test" do
  to_deliveries
  UserMailer.welcome(ANN).deliver_now
  assert_equal 1, Cybertrain::Mailer.deliveries.size
  stored = Cybertrain::Mailer.deliveries.last
  assert_equal "notifications@example.com", stored.mail_from
  assert_equal 2, stored.mail_attachments.size
  assert_equal "welcome", stored.mail_action
  assert_emails 1 do
    Admin::NoticeMailer.report(1).deliver_now
  end
end

test "deliver_now over SMTP sends multipart/mixed with the files" do
  smtp = Cybertrain::Test::SmtpReceiver.new
  smtp_to(smtp.start)
  UserMailer.welcome(ANN).deliver_now
  mail = smtp.received_message
  smtp.stop
  smtp_reset
  to_deliveries
  assert mail.message_header("Content-Type").start_with?("multipart/mixed;")
  parts = mail.message_parts
  assert_equal "Hello, Ann <A> & friends <b>\r\n--\r\nSent by the fixture app\r\n", parts["text"]
  assert parts["html"].include?("<img src=\"cid:logo.png\"")
  assert_equal "%PDF-1.4 terms", parts["attachment:terms.pdf"]
  assert_equal "\x89PNG\r\n".b, parts["attachment:logo.png"].b
  assert mail.message_data.include?("Content-ID: <logo.png>")
  assert mail.message_data.include?("Content-Type: multipart/related;")
end

test "deliver_later queues the message, files included, and the job sends it" do
  Cybertrain::DB.connect(":memory:")
  to_deliveries
  id = UserMailer.with(user: ANN, url: "https://example.com/r/2").reset.deliver_later
  assert id > 0
  assert_enqueued_jobs 1, "cybertrain mail"
  assert_emails 1 do
    UserMailer.welcome(ANN).deliver_later(wait: 5.minutes)
  end
  stored = Cybertrain::Mailer.deliveries.last
  assert_equal "welcome", stored.mail_action
  assert_equal "UserMailer", stored.mail_mailer_name
  assert_equal 2, stored.mail_attachments.size
  assert_equal "%PDF-1.4 terms", stored.mail_attachments[0].attachment_content
  assert_equal "\x89PNG\r\n".b, stored.mail_attachments[1].attachment_content.b
  assert stored.mail_attachments[1].attachment_inline?
  assert_equal 1, perform_enqueued_jobs
  assert_equal "Reset", Cybertrain::Mailer.deliveries.last.mail_subject
end

test "assert_enqueued_emails, assert_no_enqueued_emails and assert_enqueued_email_with" do
  Cybertrain::DB.connect(":memory:")
  assert_enqueued_emails 2 do
    UserMailer.welcome(ANN).deliver_later
    Admin::NoticeMailer.report(2).deliver_later
  end
  assert_no_enqueued_emails do
    UserMailer.with(user: MailUser.new("skip", "s@example.com")).reset.deliver_later
  end
  assert_enqueued_emails 2
  assert_enqueued_email_with UserMailer, :welcome
  assert_enqueued_email_with Admin::NoticeMailer, :report, to: "admin@example.com"
  assert_enqueued_email_with "UserMailer", "welcome", to: "ann@example.com"
  failure = assert_raises("Cybertrain::Test::AssertionFailed") do
    assert_enqueued_email_with UserMailer, :reset
  end
  assert_equal "expected an enqueued email UserMailer#reset; queued: UserMailer#welcome to ann@example.com, " \
               "Admin::NoticeMailer#report to admin@example.com", failure
  clear_enqueued_jobs
end

test "a view the action lacks raises MissingTemplate naming both files" do
  message = assert_raises("Cybertrain::Template::MissingTemplate") do
    UserMailer.new.mail(to: "a@example.com", template_name: "nothing")
  end
  assert_equal "Missing template user_mailer/nothing.html.erb or user_mailer/nothing.text.erb for UserMailer#", message
end

Cybertrain::Test.run!
