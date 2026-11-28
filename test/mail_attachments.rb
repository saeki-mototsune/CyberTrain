require "cybertrain/mailer"
require "cybertrain/test"

# Mail attachments as bytes (docs/design.md D98): Mailer::Attachment's
# checks and types, Mailer::Message.build_mime's multipart/mixed and
# multipart/related, and Message.parse reading them back. No server, no
# database; test/mailer_classes.rb sends them.

def pdf
  Cybertrain::Mailer::Attachment.new("report.pdf", "%PDF\x00\xff".b)
end

def logo
  Cybertrain::Mailer::Attachment.new("logo.png", "PNG", "", true)
end

def build(text, html, files)
  Cybertrain::Mailer::Message.build_mime("app@example.com", "bob@example.org", "Files", text, html, files, "=_b1")
end

def refusal(name, inline)
  Cybertrain::Mailer::Attachment.new(name, "x", "", inline)
  flunk("expected ArgumentError for #{name.inspect}")
  ""
rescue ArgumentError => e
  Cybertrain::Test.count_assertion
  e.message
end

test "an attachment's type comes from its extension, else octet-stream, or is given" do
  assert_equal "application/pdf", pdf.attachment_mime_type
  assert_equal "image/jpeg", Cybertrain::Mailer::Attachment.new("Photo.JPG", "x").attachment_mime_type
  assert_equal "application/octet-stream", Cybertrain::Mailer::Attachment.new("data.bin", "x").attachment_mime_type
  assert_equal "application/octet-stream", Cybertrain::Mailer::Attachment.new("README", "x").attachment_mime_type
  assert_equal "text/calendar", Cybertrain::Mailer::Attachment.new("x.dat", "x", "text/calendar").attachment_mime_type
  assert_equal "cid:logo.png", logo.url
  assert logo.attachment_inline?
  assert_not pdf.attachment_inline?
end

test "names and types that are refused" do
  assert_equal "an attachment needs a file name", refusal("", false)
  assert_equal "the attachment's file name contains / or \\", refusal("../etc/passwd", false)
  assert_equal "the attachment's file name contains / or \\", refusal("a\\b.txt", false)
  assert_equal "the attachment's file name contains a control character", refusal("a\r\nb.txt", false)
  assert_equal "the attachment's file name may not be . or ..", refusal("..", false)
  assert_equal "the attachment's file name is longer than 255 bytes", refusal("a" * 256, false)
  assert_equal "an inline attachment's file name is its Content-ID: use letters, digits and ._-+ only",
               refusal("my logo.png", true)
  message = assert_raises("ArgumentError") { Cybertrain::Mailer::Attachment.new("x.txt", "x", "text/plain; charset=x") }
  assert_equal "the attachment's MIME type must be type/subtype (got \"text/plain; charset=x\")", message
end

test "Attachments: []= adds, the same name replaces, [] reads back, inline adds inline" do
  list = Cybertrain::Mailer::Attachments.new
  list["a.txt"] = "one"
  list["b.csv"] = "two"
  list["a.txt"] = "three"
  list.inline["logo.png"] = "PNG"
  names = Array.new(0) { "" }
  list.attachment_list.each { |a| names << a.attachment_filename }
  assert_equal ["b.csv", "a.txt", "logo.png"], names
  assert_equal "three", list["a.txt"].attachment_content
  assert_nil list["missing.txt"]
  assert list["logo.png"].attachment_inline?
  found = list.attach("event.ics", "BEGIN:VCALENDAR", mime_type: "text/calendar")
  assert_equal "text/calendar", found.attachment_mime_type
end

test "text and a file: multipart/mixed, the text part first" do
  assert_equal "From: app@example.com\r\nTo: bob@example.org\r\nSubject: Files\r\nMIME-Version: 1.0\r\n" \
               "Content-Type: multipart/mixed;\r\n boundary=\"=_b1\"\r\n\r\n" \
               "--=_b1\r\nContent-Type: text/plain; charset=UTF-8\r\nContent-Transfer-Encoding: base64\r\n\r\n" \
               "SGkNCg==\r\n" \
               "--=_b1\r\nContent-Type: application/pdf;\r\n name=\"report.pdf\"\r\nContent-Transfer-Encoding: base64\r\n" \
               "Content-Disposition: attachment;\r\n filename=\"report.pdf\"\r\n\r\nJVBERgD/\r\n" \
               "--=_b1--\r\n", build("Hi\n", "", [pdf])
end

test "text, HTML, an inline image and a file: mixed > alternative > related" do
  out = build("Hi\n", "<p>Hi</p>", [pdf, logo])
  pieces = ["Content-Type: multipart/mixed;\r\n boundary=\"=_b1\"\r\n",
            "--=_b1\r\nContent-Type: multipart/alternative;\r\n boundary=\"a_=_b1\"\r\n",
            "--a_=_b1\r\nContent-Type: text/plain; charset=UTF-8\r\n",
            "--a_=_b1\r\nContent-Type: multipart/related;\r\n boundary=\"r_=_b1\"; type=\"text/html\"\r\n",
            "--r_=_b1\r\nContent-Type: text/html; charset=UTF-8\r\n",
            "--r_=_b1\r\nContent-Type: image/png;\r\n name=\"logo.png\"\r\n",
            "Content-Disposition: inline;\r\n filename=\"logo.png\"\r\nContent-ID: <logo.png>\r\n",
            "--r_=_b1--\r\n--a_=_b1--\r\n",
            "--=_b1\r\nContent-Type: application/pdf;\r\n",
            "--=_b1--\r\n"]
  at = 0
  pieces.each do |piece|
    found = out.index(piece, at)
    assert !found.nil?, "#{piece.inspect} after #{at}"
    at = found.nil? ? at : found + piece.size
  end
  parts = Cybertrain::Mailer::Message.parse(out)
  assert_equal "Files", parts["subject"]
  assert_equal "Hi\r\n", parts["text"]
  assert_equal "<p>Hi</p>\r\n", parts["html"]
  assert_equal "%PDF\x00\xff".b, parts["attachment:report.pdf"].b
  assert_equal "PNG", parts["attachment:logo.png"]
end

test "an inline file without HTML is attached as the others; no file is D57's message byte for byte" do
  out = build("Hi\n", "", [logo])
  assert out.include?("Content-Disposition: attachment;\r\n filename=\"logo.png\"\r\n")
  assert_not out.include?("Content-ID")
  plain = Cybertrain::Mailer::Message.build("app@example.com", "bob@example.org", "Files", "Hi\n", "<p>Hi</p>", "=_b1")
  assert_equal plain, build("Hi\n", "<p>Hi</p>", Cybertrain::Mailer::Attachment.none)
end

test "a name that is not plain ASCII is RFC 2231-encoded, and read back" do
  file = Cybertrain::Mailer::Attachment.new("résumé \"1\".pdf", "x")
  out = build("Hi\n", "", [file])
  assert out.include?("Content-Type: application/pdf;\r\n name*=UTF-8''r%C3%A9sum%C3%A9%20%221%22.pdf\r\n")
  assert out.include?("Content-Disposition: attachment;\r\n filename*=UTF-8''r%C3%A9sum%C3%A9%20%221%22.pdf\r\n")
  assert_equal "x", Cybertrain::Mailer::Message.parse(out)["attachment:résumé \"1\".pdf"]
end

test "the job payload's attachment lines round-trip, and a malformed one is refused" do
  text = Cybertrain::Mailer.encode_attachments([pdf, logo])
  assert_equal "a cmVwb3J0LnBkZg== application/pdf JVBERgD/\ni bG9nby5wbmc= image/png UE5H\n", text
  back = Cybertrain::Mailer.decode_attachments(text)
  assert_equal 2, back.size
  assert_equal "%PDF\x00\xff".b, back[0].attachment_content.b
  assert back[1].attachment_inline?
  assert_equal 0, Cybertrain::Mailer.decode_attachments("").size
  message = assert_raises("ArgumentError") { Cybertrain::Mailer.decode_attachments("a bad\n") }
  assert_equal "the mail job's attachments field is malformed", message
end

Cybertrain::Test.run!
