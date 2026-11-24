# The SMTP receiver script/auth-e2e's served scenarios send their mail to:
# the framework's test receiver (cybertrain/test/smtp_receiver.rb), run by
# CRuby with this checkout on the load path, for COUNT messages. It writes
# its port to PORT_FILE once it listens, and each message (Subject, To, a
# blank line, the text part) to MAIL_PREFIX-N.txt as it arrives; both
# appear by rename, never half-written. Exits 1 when fewer than COUNT
# arrived within two minutes of the one before.
#
# usage: ruby -I ROOT script/e2e.d/smtp_receiver.rb PORT_FILE MAIL_PREFIX COUNT
require "cybertrain/test/smtp_receiver"
count = ARGV[2].to_i
receiver = Cybertrain::Test::SmtpReceiver.new(accept_window: 120, max: count)
port = receiver.start
File.write("#{ARGV[0]}.tmp", port.to_s)
File.rename("#{ARGV[0]}.tmp", ARGV[0])
got = 0
while got < count
  messages = receiver.received_messages(got + 1, 120)
  break if messages.size <= got

  mail = messages[got]
  got += 1
  text = mail.message_parts["text"]
  path = "#{ARGV[1]}-#{got}.txt"
  File.write("#{path}.tmp", "Subject: #{mail.message_header("Subject")}\nTo: #{mail.envelope_recipients.join(",")}\n\n#{text}")
  File.rename("#{path}.tmp", path)
end
receiver.stop
exit(got == count ? 0 : 1)
