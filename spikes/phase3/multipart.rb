# Phase 3 spike, check 5 (spec section 14): a multipart/alternative
# message with a UTF-8 subject and body and base64 parts, built by hand,
# delivered over a plain socket to Cybertrain::Test::SmtpReceiver, parsed
# back from the receiver's record and decoded. A record, not a test.
#
# Run (Spinel 2026.11.04.7026, from spikes/phase3/):
#   spinel $(spin flags) multipart.rb -o /tmp/multipart && /tmp/multipart
# and `LANG=C.UTF-8 ruby -I../.. multipart.rb` under CRuby 3.3.6 (the locale
# only for `inspect`). Output, identical under both:
#   greeting: 220 receiver.test ESMTP ready
#   ehlo: 250 HELP
#   mail: 250 2.1.0 Ok
#   rcpt: 250 2.1.5 Ok
#   data: 354 End data with <CR><LF>.<CR><LF>
#   sent: 250 2.0.0 Ok: queued
#   quit: 221 2.0.0 Bye
#   content-type: multipart/alternative; boundary="=_cybertrain_0123456789abcdef"
#   subject: =?UTF-8?B?Q2Fmw6k=?=
#   boundary read back: true
#   parts: 2
#   Content-Type: text/plain; charset=UTF-8 | valid true | "Café au lait — 3 €\nSecond line.\n"
#   Content-Type: text/html; charset=UTF-8 | valid true | "<p>Café au lait &mdash; <b>3 €</b></p>\n"
#   text round trip: true
#   html round trip: true
#   message bytes: 543
require "socket"
require "base64"
require "cybertrain/mailer"
require "cybertrain/test/smtp_receiver"

TEXT = "Café au lait — 3 €\nSecond line.\n"
HTML = "<p>Café au lait &mdash; <b>3 €</b></p>\n"
BOUNDARY = "=_cybertrain_0123456789abcdef"

def part(content_type, text)
  out = String.new
  out << "--" << BOUNDARY << "\r\n"
  out << "Content-Type: " << content_type << "; charset=UTF-8\r\n"
  out << "Content-Transfer-Encoding: base64\r\n\r\n"
  out << Cybertrain::Mailer.base64_lines(text)
  out
end

def message
  out = String.new
  out << "From: app@example.com\r\n"
  out << "To: bob@example.org\r\n"
  out << "Subject: =?UTF-8?B?" << Base64.strict_encode64("Café") << "?=\r\n"
  out << "MIME-Version: 1.0\r\n"
  out << "Content-Type: multipart/alternative; boundary=\"" << BOUNDARY << "\"\r\n\r\n"
  out << part("text/plain", TEXT)
  out << part("text/html", HTML)
  out << "--" << BOUNDARY << "--\r\n"
  out
end

# One reply (the last line starts with the code and a space).
def read_reply(sock)
  buf = String.new
  while true
    return buf if sock.wait_readable(5).nil?

    chunk = sock.readpartial(4096)
    buf << chunk
    lines = buf.split("\r\n")
    last = lines.empty? ? "" : lines[lines.size - 1]
    return buf if buf.end_with?("\r\n") && last.bytesize >= 4 && last.byteslice(3, 1) == " "
  end
  buf
end

def command(sock, line)
  sock.write(line + "\r\n")
  read_reply(sock).split("\r\n").last.to_s
end

# The body of each part between the boundary lines: [headers, body].
def parts_of(body, boundary)
  out = Array.new(0) { ["", ""] }
  delim = "--" + boundary
  pieces = body.split(delim)
  i = 1
  while i < pieces.size
    piece = pieces[i]
    break if piece.start_with?("--")

    piece = piece.byteslice(2, piece.bytesize - 2) if piece.start_with?("\r\n")
    at = piece.index("\r\n\r\n")
    out << [piece.byteslice(0, at), piece.byteslice(at + 4, piece.bytesize - at - 4)] unless at.nil?
    i += 1
  end
  out
end

smtp = Cybertrain::Test::SmtpReceiver.new
port = smtp.start
sock = TCPSocket.new("127.0.0.1", port)
puts "greeting: #{read_reply(sock).split("\r\n").last}"
puts "ehlo: #{command(sock, "EHLO localhost")}"
puts "mail: #{command(sock, "MAIL FROM:<app@example.com> BODY=8BITMIME")}"
puts "rcpt: #{command(sock, "RCPT TO:<bob@example.org>")}"
puts "data: #{command(sock, "DATA")}"
sock.write(Cybertrain::Mailer.dot_stuff(message))
puts "sent: #{read_reply(sock).split("\r\n").last}"
puts "quit: #{command(sock, "QUIT")}"
sock.close

mail = smtp.received_message
smtp.stop
ctype = mail.message_header("Content-Type")
puts "content-type: #{ctype}"
puts "subject: #{mail.message_header("Subject")}"
at = ctype.index("boundary=\"")
boundary = ctype.byteslice(at + 10, ctype.bytesize - at - 11)
puts "boundary read back: #{boundary == BOUNDARY}"
parts = parts_of(mail.message_body, boundary)
puts "parts: #{parts.size}"
parts.each do |pair|
  decoded = pair[1].unpack1("m").force_encoding("UTF-8")
  puts "#{pair[0].split("\r\n")[0]} | valid #{decoded.valid_encoding?} | #{decoded.inspect}"
end
puts "text round trip: #{parts[0][1].unpack1("m").force_encoding("UTF-8") == TEXT}"
puts "html round trip: #{Base64.decode64(parts[1][1]).force_encoding("UTF-8") == HTML}"
puts "message bytes: #{mail.message_data.bytesize}"
