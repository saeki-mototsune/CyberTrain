# Cybertrain::Mailer against scripted SMTP servers on 127.0.0.1: a thread
# that accepts one connection and plays a fixed dialogue (send a reply, read
# a command, read the DATA payload), recording what the client sent. Nothing
# here may hang: every wait the mailer makes is bounded by its timeout, and
# every wait the scripted servers make by wait_readable(5). Ports and
# timings are never printed.
#
# The TLS layer is in the program (cybertrain/net/tls requires Spinel's
# openssl package), so the snapshot comes from the compiled binary
# (spikes/NOTES.md rule 23). There is no TLS server to talk to (the package
# has no X509 to make a certificate), so STARTTLS and implicit TLS are
# tested up to the handshake, against servers that answer it in plain text.
require "socket"
require "cybertrain/mailer"
require "cybertrain/net/tls"
require "cybertrain/test"

# A server that plays `steps` on one connection:
#   "> text"  sends text and CRLF (text may hold more CRLF-separated lines)
#   "<"       reads one command line and records it
#   "<data"   reads the DATA payload up to and including CRLF.CRLF
#   "<any"    waits for any bytes (a TLS ClientHello) and drops them
#   "close"   closes the connection
class SmtpScript
  attr_reader :script_port, :commands

  def initialize(steps)
    @listener = TCPServer.new("127.0.0.1", 0)
    @script_port = @listener.addr[1]
    @steps = steps
    @commands = Array.new(0) { "" }
    @data = String.new
    @inbuf = String.new
  end

  def data
    @data
  end

  def start
    listener = @listener
    @thread = Thread.new { serve_one(listener) }
    self
  end

  def serve_one(listener)
    sock = listener.accept
    i = 0
    while i < @steps.size
      step = @steps[i]
      if step.start_with?("> ")
        line = String.new
        line << step.byteslice(2, step.bytesize - 2) << "\r\n"
        sock.write(line)
      elsif step == "<"
        got = take_until(sock, "\r\n")
        break if got == "\u0000"

        @commands << got
      elsif step == "<data"
        payload = take_until(sock, "\r\n.\r\n")
        break if payload == "\u0000"

        @data << payload << "\r\n.\r\n"
      elsif step == "<any"
        break if sock.wait_readable(5).nil?

        sock.readpartial(16_384)
      elsif step == "close"
        break
      end
      i += 1
    end
    sock.close
    listener.close
    nil
  rescue EOFError, IOError, SystemCallError
    nil
  end

  # The bytes before the next `marker` (consumed with it), or "\0" when the
  # client went quiet or away.
  def take_until(sock, marker)
    while @inbuf.byteindex(marker).nil?
      return "\u0000" if sock.wait_readable(5).nil?

      @inbuf << sock.readpartial(16_384)
    end
    at = @inbuf.byteindex(marker)
    head = @inbuf.byteslice(0, at)
    rest_from = at + marker.bytesize
    rest = @inbuf.byteslice(rest_from, @inbuf.bytesize - rest_from)
    @inbuf = String.new
    @inbuf << rest
    head
  end

  def finish
    @thread.join(5)
    nil
  end
end

# What a delivery ended with: "ok" or the error's kind, and the message (the
# server's reply for "ok"). The rescue ladder lives in a method that
# receives the block as a Proc (spikes/NOTES.md rule 32) and tells the
# classes apart by clause (rule 47).
class Outcome
  attr_reader :kind, :text

  def initialize(kind, text)
    @kind = kind
    @text = text
  end
end

def outcome(&action)
  begin
    reply = action.call
    return Outcome.new("ok", reply)
  rescue Cybertrain::Mailer::RejectedError => e
    return Outcome.new("rejected #{e.smtp_code}", e.message)
  rescue Cybertrain::Mailer::TimeoutError => e
    return Outcome.new("timeout", e.message)
  rescue Cybertrain::Mailer::ConnectError => e
    return Outcome.new("connect", e.message)
  rescue Cybertrain::Mailer::TLSError => e
    return Outcome.new("tls", e.message)
  rescue Cybertrain::Mailer::InsecureError => e
    return Outcome.new("insecure", e.message)
  rescue Cybertrain::Mailer::ProtocolError => e
    return Outcome.new("protocol", e.message)
  rescue ArgumentError => e
    return Outcome.new("argument", e.message)
  end
  Outcome.new("none", "")
end

def plain_mailer(port, user = "", password = "", host = "127.0.0.1")
  Cybertrain::Mailer.new(host: host, port: port, user: user, password: password, tls: "none",
                         from: "app@example.com", timeout: 2, deadline: 5)
end

# A port nothing listens on: a mailer that gets as far as connecting to it
# is refused, so an error of another kind shows nothing was dialled.
def closed_port
  gone = TCPServer.new("127.0.0.1", 0)
  port = gone.addr[1]
  gone.close
  port
end

def now
  Process.clock_gettime(Process::CLOCK_MONOTONIC)
end

# The steps of a successful dialogue: greeting, EHLO (with `caps`), MAIL,
# one RCPT per recipient, DATA, the payload, QUIT.
def delivery_steps(caps, recipients)
  steps = Array.new(0) { "" }
  steps << "> 220 mail.test ESMTP ready"
  steps << "<"
  ehlo = String.new
  ehlo << "250-mail.test greets you"
  j = 0
  while j < caps.size
    ehlo << "\r\n250-" << caps[j]
    j += 1
  end
  ehlo << "\r\n250 HELP"
  steps << "> #{ehlo}"
  steps << "<"
  steps << "> 250 2.1.0 Ok"
  i = 0
  while i < recipients
    steps << "<"
    steps << "> 250 2.1.5 Ok"
    i += 1
  end
  steps << "<"
  steps << "> 354 End data with <CR><LF>.<CR><LF>"
  steps << "<data"
  steps << "> 250 2.0.0 Ok: queued as ABC123"
  steps << "<"
  steps << "> 221 2.0.0 Bye"
  steps
end

# The payload without its first line (the Date header, which is the clock's).
def after_date(payload)
  first = payload.byteindex("\r\n")
  payload.byteslice(first + 2, payload.bytesize - first - 2)
end

# ---- successful deliveries --------------------------------------------------

test "a delivery over tls none to loopback: the commands and the message bytes" do
  srv = SmtpScript.new(delivery_steps(["SIZE 1000000"], 1)).start
  got = outcome { plain_mailer(srv.script_port).deliver(to: "bob@example.org", subject: "Hello", body: "Hi Bob,\n.hidden\r..two\r\nend") }
  srv.finish
  assert_equal "ok", got.kind
  assert_equal "250 2.0.0 Ok: queued as ABC123", got.text
  assert_equal ["EHLO localhost", "MAIL FROM:<app@example.com>", "RCPT TO:<bob@example.org>", "DATA", "QUIT"], srv.commands
  assert srv.data.start_with?("Date: ")
  expected = "From: app@example.com\r\nTo: bob@example.org\r\nSubject: Hello\r\nMIME-Version: 1.0\r\n" \
             "Content-Type: text/plain; charset=UTF-8\r\nContent-Transfer-Encoding: 7bit\r\n\r\n" \
             "Hi Bob,\r\n..hidden\r\n...two\r\nend\r\n.\r\n"
  assert_equal expected, after_date(srv.data)
end

test "several recipients get one RCPT each and share the To header" do
  srv = SmtpScript.new(delivery_steps(["8BITMIME"], 3)).start
  got = outcome do
    plain_mailer(srv.script_port).deliver(to: "a@example.org, b@example.org,,c@example.org", subject: "All",
                                          body: "x", from: "boss@example.com")
  end
  srv.finish
  assert_equal "ok", got.kind
  assert_equal ["EHLO localhost", "MAIL FROM:<boss@example.com>", "RCPT TO:<a@example.org>",
                "RCPT TO:<b@example.org>", "RCPT TO:<c@example.org>", "DATA", "QUIT"], srv.commands
  assert_includes srv.data, "\r\nFrom: boss@example.com\r\nTo: a@example.org, b@example.org, c@example.org\r\n"
end

test "a UTF-8 body is 8bit with BODY=8BITMIME when the server offers it" do
  srv = SmtpScript.new(delivery_steps(["8BITMIME"], 1)).start
  got = outcome { plain_mailer(srv.script_port).deliver(to: "bob@example.org", subject: "café", body: "café\n") }
  srv.finish
  assert_equal "ok", got.kind
  assert_equal "MAIL FROM:<app@example.com> BODY=8BITMIME", srv.commands[1]
  assert_includes srv.data, "Content-Transfer-Encoding: 8bit\r\n"
  assert_includes srv.data, "Subject: =?UTF-8?B?Y2Fmw6k=?=\r\n"
  assert_equal "café\r\n.\r\n".bytes, srv.data.byteslice(srv.data.bytesize - 10, 10).bytes
end

test "without 8BITMIME a UTF-8 body goes as base64" do
  srv = SmtpScript.new(delivery_steps(["SIZE 10"], 1)).start
  got = outcome { plain_mailer(srv.script_port).deliver(to: "bob@example.org", subject: "x", body: "café\n") }
  srv.finish
  assert_equal "ok", got.kind
  assert_equal "MAIL FROM:<app@example.com>", srv.commands[1]
  assert_includes srv.data, "Content-Transfer-Encoding: base64\r\n\r\nY2Fmw6kNCg==\r\n.\r\n"
end

test "AUTH PLAIN over tls none is allowed to loopback" do
  srv = SmtpScript.new(["> 220 ready", "<", "> 250-mail.test\r\n250 AUTH LOGIN PLAIN", "<", "> 235 2.7.0 Authentication successful",
                        "<", "> 250 Ok", "<", "> 250 Ok", "<", "> 354 go", "<data", "> 250 queued", "<", "> 221 Bye"]).start
  got = outcome { plain_mailer(srv.script_port, "alice", "s3cr3t").deliver(to: "bob@example.org", subject: "s", body: "b") }
  srv.finish
  assert_equal "ok", got.kind
  assert_equal "AUTH PLAIN AGFsaWNlAHMzY3IzdA==", srv.commands[1]
  assert_equal "MAIL FROM:<app@example.com>", srv.commands[2]
end

test "Mailer.deliver takes its settings from Config" do
  srv = SmtpScript.new(delivery_steps(["SIZE 10"], 1)).start
  c = Cybertrain.config
  c.smtp_host = "localhost"
  c.smtp_port = srv.script_port
  c.smtp_tls = "none"
  c.smtp_from = "config@example.com"
  got = outcome { Cybertrain::Mailer.deliver(to: "bob@example.org", subject: "From config", body: "b") }
  srv.finish
  c.smtp_host = ""
  c.smtp_port = 0
  c.smtp_tls = "starttls"
  c.smtp_from = ""
  assert_equal "ok", got.kind
  assert_equal "MAIL FROM:<config@example.com>", srv.commands[1]
end

# ---- what the server refuses ------------------------------------------------

test "a 550 to RCPT is a RejectedError with the code and the reply" do
  srv = SmtpScript.new(["> 220 ready", "<", "> 250 mail.test", "<", "> 250 Ok", "<", "> 550 5.1.1 <nobody@example.org>: no such user"]).start
  got = outcome { plain_mailer(srv.script_port).deliver(to: "nobody@example.org", subject: "s", body: "b") }
  srv.finish
  assert_equal "rejected 550", got.kind
  assert_includes got.text, "127.0.0.1:#{srv.script_port}: RCPT TO <nobody@example.org> rejected: 550 5.1.1"
  assert_includes got.text, "no such user"
end

test "a 4xx greeting is a RejectedError" do
  srv = SmtpScript.new(["> 421-mail.test busy\r\n421 try again later"]).start
  got = outcome { plain_mailer(srv.script_port).deliver(to: "bob@example.org", subject: "s", body: "b") }
  srv.finish
  assert_equal "rejected 421", got.kind
  assert_includes got.text, "the greeting rejected: 421 mail.test busy / try again later"
end

test "a failed AUTH names the code, never the password" do
  srv = SmtpScript.new(["> 220 ready", "<", "> 250-mail.test\r\n250 AUTH PLAIN", "<", "> 535 5.7.8 Authentication credentials invalid"]).start
  got = outcome { plain_mailer(srv.script_port, "alice", "s3cr3t").deliver(to: "bob@example.org", subject: "s", body: "b") }
  srv.finish
  assert_equal "rejected 535", got.kind
  assert_includes got.text, "AUTH (authentication) rejected: 535"
  assert_nil got.text.index("s3cr3t")
  assert_nil got.text.index("AGFsaWNl")
end

test "a server that does not offer AUTH PLAIN is a ProtocolError" do
  srv = SmtpScript.new(["> 220 ready", "<", "> 250-mail.test\r\n250 AUTH CRAM-MD5"]).start
  got = outcome { plain_mailer(srv.script_port, "alice", "s3cr3t").deliver(to: "bob@example.org", subject: "s", body: "b") }
  srv.finish
  assert_equal "protocol", got.kind
  assert_includes got.text, "does not offer AUTH PLAIN"
end

test "replies that are not SMTP, or stop half way, are ProtocolErrors" do
  srv = SmtpScript.new(["> HTTP/1.1 400 Bad Request"]).start
  got = outcome { plain_mailer(srv.script_port).deliver(to: "bob@example.org", subject: "s", body: "b") }
  srv.finish
  assert_equal "protocol", got.kind
  assert_includes got.text, "not SMTP"
  srv2 = SmtpScript.new(["> 220 ready", "<", "close"]).start
  cut = outcome { plain_mailer(srv2.script_port).deliver(to: "bob@example.org", subject: "s", body: "b") }
  srv2.finish
  assert_equal "protocol", cut.kind
end

# ---- credentials and TLS ----------------------------------------------------

test "AUTH over tls none to a host that is not loopback is refused before connecting" do
  started = now
  got = outcome { plain_mailer(25, "alice", "s3cr3t", "192.0.2.1").deliver(to: "bob@example.org", subject: "s", body: "b") }
  assert_equal "insecure", got.kind
  assert_includes got.text, "refusing to send credentials in plain text to 192.0.2.1"
  assert_nil got.text.index("s3cr3t")
  assert now - started < 1.0
end

test "starttls without cybertrain/net/tls says what to require, before connecting" do
  Cybertrain::Net.tls_connector = Cybertrain::Net::TlsConnector.new
  port = closed_port
  mailer = Cybertrain::Mailer.new(host: "127.0.0.1", port: port, tls: "starttls", from: "app@example.com", timeout: 2, deadline: 5)
  got = outcome { mailer.deliver(to: "bob@example.org", subject: "s", body: "b") }
  implicit = Cybertrain::Mailer.new(host: "127.0.0.1", port: port, tls: "tls", from: "app@example.com", timeout: 2, deadline: 5)
  wrapped = outcome { implicit.deliver(to: "bob@example.org", subject: "s", body: "b") }
  Cybertrain::Net.tls_connector = Cybertrain::Net::OpenSSLConnector.new
  assert_equal "tls", got.kind
  assert_includes got.text, "require \"cybertrain/net/tls\""
  assert_equal "tls", wrapped.kind
  assert_includes Cybertrain::Net.tls_connector.class.name.to_s, "OpenSSLConnector"
end

test "starttls to a server that does not offer it is a TLSError" do
  srv = SmtpScript.new(["> 220 ready", "<", "> 250-mail.test\r\n250 8BITMIME"]).start
  mailer = Cybertrain::Mailer.new(host: "127.0.0.1", port: srv.script_port, from: "app@example.com", timeout: 2, deadline: 5)
  got = outcome { mailer.deliver(to: "bob@example.org", subject: "s", body: "b") }
  srv.finish
  assert_equal "tls", got.kind
  assert_includes got.text, "does not offer STARTTLS"
  assert_equal ["EHLO localhost"], srv.commands
end

test "bytes sent after the 220 to STARTTLS are refused" do
  srv = SmtpScript.new(["> 220 ready", "<", "> 250-mail.test\r\n250 STARTTLS", "<", "> 220 go ahead\r\n250 injected"]).start
  mailer = Cybertrain::Mailer.new(host: "127.0.0.1", port: srv.script_port, from: "app@example.com", timeout: 2, deadline: 5)
  got = outcome { mailer.deliver(to: "bob@example.org", subject: "s", body: "b") }
  srv.finish
  assert_equal "protocol", got.kind
  assert_includes got.text, "sent data after its STARTTLS reply"
end

test "STARTTLS then a server that answers the handshake in plain text" do
  srv = SmtpScript.new(["> 220 ready", "<", "> 250-mail.test\r\n250 STARTTLS", "<", "> 220 go ahead", "<any", "> 500 what"]).start
  mailer = Cybertrain::Mailer.new(host: "localhost", port: srv.script_port, user: "alice", password: "s3cr3t",
                                  from: "app@example.com", timeout: 2, deadline: 5)
  got = outcome { mailer.deliver(to: "bob@example.org", subject: "s", body: "b") }
  srv.finish
  assert_equal "tls", got.kind
  assert_includes got.text, "TLS handshake failed"
  assert_equal ["EHLO localhost", "STARTTLS"], srv.commands
end

test "implicit tls to a plain server fails the handshake" do
  srv = SmtpScript.new(["> 220 plain text"]).start
  mailer = Cybertrain::Mailer.new(host: "localhost", port: srv.script_port, tls: "tls", from: "app@example.com", timeout: 2, deadline: 5)
  got = outcome { mailer.deliver(to: "bob@example.org", subject: "s", body: "b") }
  srv.finish
  assert_equal "tls", got.kind
  assert_includes got.text, "TLS handshake failed"
end

# ---- bounded waits ----------------------------------------------------------

test "a server that never greets is a timeout" do
  silent = TCPServer.new("127.0.0.1", 0) # never accept()ed: the kernel completes the handshake
  port = silent.addr[1]
  started = now
  mailer = Cybertrain::Mailer.new(host: "127.0.0.1", port: port, tls: "none", from: "app@example.com", timeout: 0.3, deadline: 5)
  got = outcome { mailer.deliver(to: "bob@example.org", subject: "s", body: "b") }
  assert_equal "timeout", got.kind
  assert_includes got.text, "127.0.0.1:#{port}: reading timed out after 0.3s"
  assert now - started < 3.0
  silent.close
end

test "a closed port is a ConnectError" do
  got = outcome { plain_mailer(closed_port).deliver(to: "bob@example.org", subject: "s", body: "b") }
  assert_equal "connect", got.kind
  assert_includes got.text, "connection refused"
end

# ---- what the mailer refuses to send ----------------------------------------

test "header injection and malformed addresses are refused before connecting" do
  m = plain_mailer(closed_port)
  assert_equal "argument", outcome { m.deliver(to: "bob@example.org", subject: "Hi\r\nBcc: evil@example.net", body: "b") }.kind
  assert_equal "argument", outcome { m.deliver(to: "bob@example.org", subject: "Hi\nBcc: evil@example.net", body: "b") }.kind
  injected = outcome { m.deliver(to: "bob@example.org\r\nRCPT TO:<evil@example.net>", subject: "s", body: "b") }
  assert_equal "argument", injected.kind
  assert_nil injected.text.index("evil")
  assert_equal "argument", outcome { m.deliver(to: "Bob <bob@example.org>", subject: "s", body: "b") }.kind
  assert_equal "argument", outcome { m.deliver(to: "bob@example.org", subject: "s", body: "b", from: "a@example.com>") }.kind
  assert_equal "argument", outcome { m.deliver(to: "", subject: "s", body: "b") }.kind
  assert_equal "argument", outcome { m.deliver(to: " , ", subject: "s", body: "b") }.kind
  assert_equal "argument", outcome { m.deliver(to: "bob", subject: "s", body: "b") }.kind
  assert_equal "argument", outcome { m.deliver(to: "@example.org", subject: "s", body: "b") }.kind
  assert_equal "argument", outcome { m.deliver(to: "a@b@example.org", subject: "s", body: "b") }.kind
  assert_equal "argument", outcome { m.deliver(to: "bob@example.org", subject: "s", body: "a\u0000b") }.kind
  assert_equal "argument", outcome { m.deliver(to: "bob@example.org", subject: "s", body: "caf\xC3") }.kind
  assert_equal "argument", outcome { m.deliver(to: "bob@example.org", subject: "s" * 999, body: "b") }.kind
  long = "#{"x" * 250}@example.org"
  assert_equal "argument", outcome { m.deliver(to: long, subject: "s", body: "b") }.kind
  no_from = Cybertrain::Mailer.new(host: "127.0.0.1", port: closed_port, tls: "none", from: "", timeout: 2, deadline: 5)
  assert_includes outcome { no_from.deliver(to: "bob@example.org", subject: "s", body: "b") }.text, "from address is empty"
end

test "settings Mailer.new refuses, and the ports the modes default to" do
  assert_equal "argument", outcome { Cybertrain::Mailer.new(host: "", tls: "none").mail_host }.kind
  assert_equal "argument", outcome { Cybertrain::Mailer.new(host: "mail.example.com", tls: "ssl").mail_host }.kind
  assert_equal "argument", outcome { Cybertrain::Mailer.new(host: "mail example.com").mail_host }.kind
  assert_equal "argument", outcome { Cybertrain::Mailer.new(host: "mail.example.com", port: 70_000).mail_host }.kind
  assert_equal "argument", outcome { Cybertrain::Mailer.new(host: "mail.example.com", timeout: 0).mail_host }.kind
  assert_equal 587, Cybertrain::Mailer.new(host: "mail.example.com").mail_port
  assert_equal 465, Cybertrain::Mailer.new(host: "mail.example.com", tls: "TLS").mail_port
  assert_equal 25, Cybertrain::Mailer.new(host: "mail.example.com", tls: "none").mail_port
  assert_equal 2525, Cybertrain::Mailer.new(host: "Mail.Example.com", port: 2525).mail_port
  assert_equal "mail.example.com", Cybertrain::Mailer.new(host: "Mail.Example.com").mail_host
end

# ---- the message ------------------------------------------------------------

test "subjects: plain ASCII as it is, anything else as RFC 2047 encoded words" do
  assert_equal "Subject: Hello there\r\n", Cybertrain::Mailer.subject_header("Hello there")
  assert_equal "Subject: =?UTF-8?B?44GT44KT44Gr44Gh44Gv44CB5LiW55WM?=\r\n", Cybertrain::Mailer.subject_header("こんにちは、世界")
  # 46 bytes: the first word stops before the character the 45th byte is in.
  assert_equal "Subject: =?UTF-8?B?YeOBguOBguOBguOBguOBguOBguOBguOBguOBguOBguOBguOBguOBguOBgg==?=\r\n =?UTF-8?B?44GC?=\r\n",
               Cybertrain::Mailer.subject_header("a" + ("あ" * 15))
  assert_equal "Subject: =?UTF-8?B?UHJpY2UgPT94?=\r\n", Cybertrain::Mailer.subject_header("Price =?x")
end

test "the message: headers, line endings, encodings, folding" do
  text = Cybertrain::Mailer.normalize_body("café\n")
  assert_equal "café\r\n".bytes, text.bytes
  assert_equal "\r\n", Cybertrain::Mailer.normalize_body("")
  assert_equal "a\r\nb\r\nc\r\n\r\n", Cybertrain::Mailer.normalize_body("a\rb\nc\r\n\r\n")
  message = Cybertrain::Mailer.build_message("app@example.com", ["a@example.com"], "Hi", text,
                                             "Thu, 01 Jan 1970 00:00:00 +0000", "base64")
  assert_equal "Date: Thu, 01 Jan 1970 00:00:00 +0000\r\nFrom: app@example.com\r\nTo: a@example.com\r\nSubject: Hi\r\n" \
               "MIME-Version: 1.0\r\nContent-Type: text/plain; charset=UTF-8\r\nContent-Transfer-Encoding: base64\r\n\r\n" \
               "Y2Fmw6kNCg==\r\n", message
  assert_equal "7bit", Cybertrain::Mailer.body_encoding("plain\r\n", false)
  assert_equal "8bit", Cybertrain::Mailer.body_encoding(text, true)
  assert_equal "base64", Cybertrain::Mailer.body_encoding(text, false)
  assert_equal "7bit", Cybertrain::Mailer.body_encoding("#{"x" * 998}\r\n", true)
  assert_equal "base64", Cybertrain::Mailer.body_encoding("#{"x" * 999}\r\n", true)
  assert_equal "Hello,\r\n..hidden\r\n...two\r\nend\r\n.\r\n",
               Cybertrain::Mailer.dot_stuff(Cybertrain::Mailer.normalize_body("Hello,\n.hidden\r..two\r\nend"))
  assert_equal "To: aaaaaaaaaaaaaaaaaaaa@example.com, bbbbbbbbbbbbbbbbbbbbbbbbbbb@example.com,\r\n c@example.com\r\n",
               Cybertrain::Mailer.to_header(["aaaaaaaaaaaaaaaaaaaa@example.com", "bbbbbbbbbbbbbbbbbbbbbbbbbbb@example.com", "c@example.com"])
  assert_equal "Thu, 01 Jan 1970 00:00:00 +0000", Cybertrain::Mailer.date_header(Time.at(0))
end

test "Config reads the CYBERTRAIN_SMTP_* variables" do
  ENV["CYBERTRAIN_SMTP_HOST"] = "smtp.example.com"
  ENV["CYBERTRAIN_SMTP_PORT"] = "2525"
  ENV["CYBERTRAIN_SMTP_USER"] = "app"
  ENV["CYBERTRAIN_SMTP_PASSWORD"] = "pw"
  ENV["CYBERTRAIN_SMTP_FROM"] = "noreply@example.com"
  ENV["CYBERTRAIN_SMTP_TLS"] = "TLS"
  c = Cybertrain::Config.new
  ENV["CYBERTRAIN_SMTP_PORT"] = "99999"
  bad_port = Cybertrain::Config.new
  ENV["CYBERTRAIN_SMTP_HOST"] = ""
  ENV["CYBERTRAIN_SMTP_PORT"] = ""
  ENV["CYBERTRAIN_SMTP_USER"] = ""
  ENV["CYBERTRAIN_SMTP_PASSWORD"] = ""
  ENV["CYBERTRAIN_SMTP_FROM"] = ""
  ENV["CYBERTRAIN_SMTP_TLS"] = ""
  defaults = Cybertrain::Config.new
  assert_equal "smtp.example.com", c.smtp_host
  assert_equal 2525, c.smtp_port
  assert_equal "app", c.smtp_user
  assert_equal "pw", c.smtp_password
  assert_equal "noreply@example.com", c.smtp_from
  assert_equal "tls", c.smtp_tls
  assert_equal 0, bad_port.smtp_port
  assert_equal "", defaults.smtp_host
  assert_equal 0, defaults.smtp_port
  assert_equal "", defaults.smtp_user
  assert_equal "", defaults.smtp_password
  assert_equal "starttls", defaults.smtp_tls
  assert_equal "", defaults.settings_summary
end

Cybertrain::Test.run!
