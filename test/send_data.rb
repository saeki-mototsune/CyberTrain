require "stringio"
require "cybertrain/test"
require "cybertrain/test/client"
require "cybertrain/router"
require "cybertrain/controller"

# Controller#send_data and UploadedFile.content_disposition_utf8 through a
# real controller action, a Router and Test::Client. cybertrain/controller
# pulls in the SQLite FFI bindings, so take the snapshot from the compiled
# binary (script/regen-snapshot), not from CRuby (spikes/NOTES.md rule 23).

Cybertrain.logger = Cybertrain::Logger.new(StringIO.new)

class ExportsController < Cybertrain::Controller
  def accented
    send_data "a,b\n", filename: "résumé.csv", type: "text/csv"
  end

  def quoted
    send_data "hi", filename: "a \"b\".txt", type: "text/plain", disposition: "inline"
  end

  def anonymous
    send_data "raw"
  end

  def slashed
    send_data "x", filename: "back\\slash\r\nX-Evil: 1.txt", type: "text/plain"
  end

  def created
    send_data "made", filename: "m.bin", status: :created
  end
end

router = Cybertrain::Router.new
router.get("/accented", "accented") { |ctx| ExportsController.new(ctx).process(:accented) { |c| c.accented } }
router.get("/quoted", "quoted") { |ctx| ExportsController.new(ctx).process(:quoted) { |c| c.quoted } }
router.get("/anonymous", "anonymous") { |ctx| ExportsController.new(ctx).process(:anonymous) { |c| c.anonymous } }
router.get("/slashed", "slashed") { |ctx| ExportsController.new(ctx).process(:slashed) { |c| c.slashed } }
router.get("/created", "created") { |ctx| ExportsController.new(ctx).process(:created) { |c| c.created } }

CLIENT = Cybertrain::Test::Client.new(router)

test "send_data writes RFC 6266 Content-Disposition" do
  res = CLIENT.get("/accented")
  puts "disposition #{res.header("Content-Disposition")}"
  assert_equal 200, res.status
  assert_equal "text/csv", res.header("Content-Type")
  assert_equal "attachment; filename=\"r?sum?.csv\"; filename*=UTF-8''r%C3%A9sum%C3%A9.csv", res.header("Content-Disposition")
  assert_equal "a,b\n", res.body
  assert res.performed?
end

test "an inline disposition escapes quotes" do
  res = CLIENT.get("/quoted")
  puts "disposition #{res.header("Content-Disposition")}"
  assert_equal "text/plain", res.header("Content-Type")
  assert_equal "inline; filename=\"a \\\"b\\\".txt\"; filename*=UTF-8''a%20%22b%22.txt", res.header("Content-Disposition")
end

test "no filename is the bare disposition and the default type" do
  res = CLIENT.get("/anonymous")
  assert_equal "attachment", res.header("Content-Disposition")
  assert_equal "application/octet-stream", res.header("Content-Type")
  assert_equal "raw", res.body
end

test "a backslash and CRLF cannot break out of the header" do
  res = CLIENT.get("/slashed")
  disposition = res.header("Content-Disposition")
  puts "disposition #{disposition}"
  assert disposition.ascii_only?
  refute disposition.include?("\r")
  refute disposition.include?("\n")
  assert_equal "attachment; filename=\"back\\\\slash??X-Evil: 1.txt\"; filename*=UTF-8''back%5Cslash%0D%0AX-Evil%3A%201.txt", disposition
  assert_equal 0, res.to_http.scan("\r\nX-Evil:").length
end

test "send_data takes a status" do
  assert_equal 201, CLIENT.get("/created").status
end

test "content_disposition_utf8 on its own" do
  f = Cybertrain::UploadedFile
  assert_equal "attachment", f.content_disposition_utf8("attachment", "")
  assert_equal "attachment", f.content_disposition_utf8("bogus", "")
  assert_equal "inline; filename=\"a.png\"; filename*=UTF-8''a.png", f.content_disposition_utf8("inline", "a.png")
  assert_equal "attachment; filename=\"?\"; filename*=UTF-8''%E6%97%A5", f.content_disposition_utf8("attachment", "日")
  assert_equal "attachment; filename=\"a?b\"; filename*=UTF-8''a%09b", f.content_disposition_utf8("attachment", "a\tb")
end

Cybertrain::Test.run!
