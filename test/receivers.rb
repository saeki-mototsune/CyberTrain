# Cybertrain::Test::HttpReceiver and SmtpReceiver, driven by the
# framework's own outbound clients (HttpClient, Mailer with tls "none") and
# by a raw socket for what those never send (a chunked request body).
# Nothing here may hang: every wait is bounded, and a receiver nobody
# connects to gives up. Ports and timings are never printed.
require "socket"
require "cybertrain/http_client"
require "cybertrain/mailer"
require "cybertrain/test"
require "cybertrain/test/http_receiver"
require "cybertrain/test/smtp_receiver"

def private_client
  Cybertrain::HttpClient.new(timeout: 2, deadline: 5, allow_private: true)
end

def plain_mailer(port, user = "", password = "")
  Cybertrain::Mailer.new(host: "127.0.0.1", port: port, user: user, password: password, tls: "none",
                         from: "app@example.com", timeout: 2, deadline: 5)
end

def now
  Process.clock_gettime(Process::CLOCK_MONOTONIC)
end

# What a delivery ended with: "ok" or the error's kind and code. The rescue
# lives in a method that receives the block as a Proc (spikes/NOTES.md
# rule 32) and tells the classes apart by clause (rule 47).
def delivery_kind(&action)
  begin
    action.call
    return "ok"
  rescue Cybertrain::Mailer::RejectedError => e
    return "rejected #{e.smtp_code}"
  rescue Cybertrain::Mailer::Error => e
    return "error #{e.class.name}"
  end
  "none"
end

def http_kind(&action)
  begin
    res = action.call
    return "ok #{res.status}"
  rescue Cybertrain::HttpClient::RefusedError
    return "refused"
  rescue Cybertrain::HttpClient::Error => e
    return "error #{e.class.name}"
  end
  "none"
end

# Sends `bytes` on a plain socket and returns everything the receiver
# answers, up to its close (each wait bounded).
def raw_exchange(port, bytes)
  sock = TCPSocket.new("127.0.0.1", port)
  sock.write(bytes)
  answer = String.new
  while true
    break if sock.wait_readable(5).nil?

    chunk = raw_read(sock)
    break if chunk.empty?

    answer << chunk
  end
  sock.close
  answer
end

def raw_read(sock)
  sock.readpartial(16_384)
rescue EOFError
  ""
end

# What HttpReceiver.new(max: 0) raises (the rescue in a method: rule 32).
def max_zero_kind
  Cybertrain::Test::HttpReceiver.new(max: 0)
  "none"
rescue ArgumentError
  "argument"
end

# The message without its first line (the Date header, which is the clock's).
def after_date(data)
  first = data.byteindex("\r\n")
  data.byteslice(first + 2, data.bytesize - first - 2)
end

# ---- HttpReceiver -----------------------------------------------------------

test "a GET: the canned response reaches the client, the request is recorded" do
  hook = Cybertrain::Test::HttpReceiver.new(status: 201, headers: { "X-Canned" => "yes" }, body: "made")
  port = hook.start
  assert port > 0
  assert_equal port, hook.port
  assert hook.serving?
  res = private_client.get(hook.url("/things?id=7"), headers: { "X-Token" => "t0k3n" })
  req = hook.received_request
  hook.stop
  assert_equal 201, res.status
  assert_equal "made", res.body
  assert_equal "yes", res.header("x-canned")
  assert_equal "close", res.header("connection")
  refute req.nil?
  assert_equal "GET", req.http_method
  assert_equal "/things?id=7", req.http_target
  assert_equal "/things", req.http_path
  assert_equal "t0k3n", req.http_header("X-Token")
  assert_equal "t0k3n", req.http_headers["x-token"]
  assert_equal "127.0.0.1:#{port}", req.http_header("host")
  assert_equal "", req.http_header("x-missing")
  assert_equal "", req.http_body
  refute hook.serving?
end

test "a POST: the body, its type and the caller's headers" do
  hook = Cybertrain::Test::HttpReceiver.new
  hook.start
  body = "{\"name\":\"café\"}\n\x00 bytes"
  res = private_client.post(hook.url("/hooks/signup"), body, content_type: "application/json",
                                                             headers: { "X-Signature" => "sha256=abc" })
  req = hook.received_request
  hook.stop
  assert_equal 200, res.status
  assert_equal "ok", res.body
  assert_equal "POST", req.http_method
  assert_equal "/hooks/signup", req.http_target
  assert_equal "application/json", req.http_header("Content-Type")
  assert_equal "sha256=abc", req.http_header("x-signature")
  assert_equal body.bytesize.to_s, req.http_header("content-length")
  assert_equal body.bytes, req.http_body.bytes
end

test "a chunked response is decoded by the client" do
  hook = Cybertrain::Test::HttpReceiver.new(status: 200, body: "hello chunked world", chunked: true)
  hook.start
  res = private_client.get(hook.url("/"))
  hook.stop
  assert_equal "hello chunked world", res.body
  assert_equal "chunked", res.header("transfer-encoding")
end

test "a 204 has no body" do
  hook = Cybertrain::Test::HttpReceiver.new(status: 204, body: "ignored")
  hook.start
  res = private_client.post(hook.url("/"), "x")
  hook.stop
  assert_equal 204, res.status
  assert_equal "", res.body
end

test "a chunked request body is decoded, repeated headers joined" do
  hook = Cybertrain::Test::HttpReceiver.new(status: 202, body: "queued")
  port = hook.start
  answer = raw_exchange(port, "PUT /up HTTP/1.1\r\nHost: x\r\nX-A: one\r\nx-a:  two \r\nTransfer-Encoding: chunked\r\n\r\n" \
                              "5;ext=1\r\nhello\r\n6\r\n world\r\n0\r\nX-Trailer: t\r\n\r\n")
  req = hook.received_request
  hook.stop
  assert answer.start_with?("HTTP/1.1 202 Accepted\r\n")
  assert_includes answer, "Connection: close\r\n"
  assert answer.end_with?("\r\n\r\nqueued")
  assert_equal "PUT", req.http_method
  assert_equal "hello world", req.http_body
  assert_equal "one, two", req.http_header("X-A")
end

test "max: several requests, and respond_with between them" do
  hook = Cybertrain::Test::HttpReceiver.new(body: "first", max: 2)
  hook.start
  one = private_client.get(hook.url("/1"))
  hook.respond_with(status: 500, body: "second")
  two = private_client.get(hook.url("/2"))
  got_requests = hook.received_requests
  hook.stop
  assert_equal "first", one.body
  assert_equal 500, two.status
  assert_equal "second", two.body
  assert_equal 2, got_requests.size
  assert_equal "/1", got_requests[0].http_target
  assert_equal "/2", got_requests[1].http_target
end

test "a request that never comes: nil after the bound, and the port is free again" do
  idle = Cybertrain::Test::HttpReceiver.new
  port = idle.start
  started = now
  assert_nil idle.received_request(0.3)
  assert now - started < 2.0
  assert_equal 0, idle.received_requests(1, 0.1).size
  idle.stop
  refute idle.serving?
  # The first receiver's thread is gone: a second one on the same port gets
  # the next connection.
  again = Cybertrain::Test::HttpReceiver.new(body: "second receiver")
  assert_equal port, again.start(port: port)
  res = private_client.get("http://127.0.0.1:#{port}/again")
  req = again.received_request
  again.stop
  assert_equal "second receiver", res.body
  assert_equal "/again", req.http_target
  assert_nil idle.received_request(0.1)
end

test "stop is idempotent, also before start" do
  hook = Cybertrain::Test::HttpReceiver.new
  hook.stop
  hook.start
  hook.stop
  hook.stop
  refute hook.serving?
  assert_equal "argument", max_zero_kind
end

test "the accept window bounds how long a receiver waits for a connection" do
  hook = Cybertrain::Test::HttpReceiver.new(accept_window: 0.2)
  port = hook.start
  started = now
  assert_nil hook.received_request(3.0)
  assert now - started < 2.0
  refute hook.serving?
  assert_equal "refused", http_kind { private_client.get("http://127.0.0.1:#{port}/late") }
  hook.stop
end

# ---- SmtpReceiver -----------------------------------------------------------

test "a delivery: the transcript, the envelope and the message bytes" do
  smtp = Cybertrain::Test::SmtpReceiver.new
  port = smtp.start
  kind = delivery_kind { plain_mailer(port).deliver(to: "bob@example.org, carol@example.org", subject: "Hello", body: "Hi Bob,\n.hidden\nend") }
  mail = smtp.received_message
  smtp.stop
  assert_equal "ok", kind
  refute mail.nil?
  assert mail.delivered?
  assert_equal ["EHLO localhost", "MAIL FROM:<app@example.com>", "RCPT TO:<bob@example.org>",
                "RCPT TO:<carol@example.org>", "DATA", "QUIT"], mail.transcript
  assert_equal "app@example.com", mail.envelope_from
  assert_equal ["bob@example.org", "carol@example.org"], mail.envelope_recipients
  assert mail.message_data.start_with?("Date: ")
  assert_equal "From: app@example.com\r\nTo: bob@example.org, carol@example.org\r\nSubject: Hello\r\nMIME-Version: 1.0\r\n" \
               "Content-Type: text/plain; charset=UTF-8\r\nContent-Transfer-Encoding: 7bit\r\n\r\n" \
               "Hi Bob,\r\n.hidden\r\nend\r\n", after_date(mail.message_data)
  assert_equal "Hi Bob,\r\n.hidden\r\nend\r\n", mail.message_body
  assert_equal "Hello", mail.message_header("subject")
  assert_equal "bob@example.org, carol@example.org", mail.message_header("To")
  assert_equal "", mail.message_header("X-Missing")
end

test "8BITMIME is offered by default and can be withheld" do
  offered = Cybertrain::Test::SmtpReceiver.new
  port = offered.start
  plain_mailer(port).deliver(to: "bob@example.org", subject: "café", body: "café\n")
  eight = offered.received_message
  offered.stop
  assert_equal "MAIL FROM:<app@example.com> BODY=8BITMIME", eight.transcript[1]
  assert_equal "8bit", eight.message_header("Content-Transfer-Encoding")
  assert_equal "=?UTF-8?B?Y2Fmw6k=?=", eight.message_header("Subject")
  assert_equal "café\r\n".bytes, eight.message_body.bytes

  withheld = Cybertrain::Test::SmtpReceiver.new(eight_bit_mime: false)
  port2 = withheld.start
  plain_mailer(port2).deliver(to: "bob@example.org", subject: "x", body: "café\n")
  seven = withheld.received_message
  withheld.stop
  assert_equal "MAIL FROM:<app@example.com>", seven.transcript[1]
  assert_equal "base64", seven.message_header("content-transfer-encoding")
  assert_equal "Y2Fmw6kNCg==\r\n", seven.message_body
end

test "a rejected recipient: the mailer raises, the transcript shows how far it got" do
  smtp = Cybertrain::Test::SmtpReceiver.new(reject: { rcpt: "550 5.1.1 no such user" })
  port = smtp.start
  kind = delivery_kind { plain_mailer(port).deliver(to: "nobody@example.org", subject: "s", body: "b") }
  mail = smtp.received_message
  smtp.stop
  assert_equal "rejected 550", kind
  refute mail.delivered?
  assert_equal "", mail.message_data
  assert_equal "app@example.com", mail.envelope_from
  assert_equal 0, mail.envelope_recipients.size
  assert_equal "RCPT TO:<nobody@example.org>", mail.transcript[2]
  assert_nil mail.transcript.index("DATA")
end

test "a rejected greeting, and a message refused after its data" do
  busy = Cybertrain::Test::SmtpReceiver.new(reject: { greeting: "421 4.3.2 try again later" })
  port = busy.start
  assert_equal "rejected 421", delivery_kind { plain_mailer(port).deliver(to: "bob@example.org", subject: "s", body: "b") }
  greeted = busy.received_message
  busy.stop
  refute greeted.delivered?

  spam = Cybertrain::Test::SmtpReceiver.new(reject: { message: "554 5.7.1 looks like spam" })
  port2 = spam.start
  assert_equal "rejected 554", delivery_kind { plain_mailer(port2).deliver(to: "bob@example.org", subject: "s", body: "b") }
  refused = spam.received_message
  spam.stop
  refute refused.delivered?
  assert_equal "DATA", refused.transcript[3]
end

test "auth: AUTH PLAIN is offered and accepted, and recorded" do
  smtp = Cybertrain::Test::SmtpReceiver.new(auth: true)
  port = smtp.start
  kind = delivery_kind { plain_mailer(port, "alice", "s3cr3t").deliver(to: "bob@example.org", subject: "s", body: "b") }
  mail = smtp.received_message
  smtp.stop
  assert_equal "ok", kind
  assert_equal "AUTH PLAIN AGFsaWNlAHMzY3IzdA==", mail.transcript[1]
  assert mail.delivered?
end

test "several deliveries to one receiver, through Mailer.deliver and Config" do
  smtp = Cybertrain::Test::SmtpReceiver.new(max: 2)
  port = smtp.start
  c = Cybertrain.config
  c.smtp_host = "127.0.0.1"
  c.smtp_port = port
  c.smtp_tls = "none"
  c.smtp_from = "config@example.com"
  Cybertrain::Mailer.deliver(to: "a@example.org", subject: "one", body: "1")
  Cybertrain::Mailer.deliver(to: "b@example.org", subject: "two", body: "2")
  c.smtp_host = ""
  c.smtp_port = 0
  c.smtp_tls = "starttls"
  c.smtp_from = ""
  got_mails = smtp.received_messages
  smtp.stop
  assert_equal 2, got_mails.size
  assert_equal ["a@example.org"], got_mails[0].envelope_recipients
  assert_equal "two", got_mails[1].message_header("Subject")
  assert_equal "config@example.com", got_mails[1].envelope_from
end

test "a message that never comes: nil after the bound, and stop is idempotent" do
  smtp = Cybertrain::Test::SmtpReceiver.new
  smtp.start
  started = now
  assert_nil smtp.received_message(0.3)
  assert now - started < 2.0
  smtp.stop
  smtp.stop
  refute smtp.serving?
  assert_equal 0, smtp.received_messages(1, 0.1).size
end

Cybertrain::Test.run!
