# Regression: under Spinel, Symbol#to_s answers a new frozen String at
# every call and a frozen heap String is never freed (NOTES rule 123), so
# every `key.to_s` of a Symbol key on a request path leaked about 110
# bytes: examples/blog's server grew by 1 to 4 KB per request, without
# bound, and its throughput fell with it. The framework names a key with
# Cybertrain::Key.string_of, which answers the Symbol's one cached name.
#
# The identity tests hold under CRuby and Spinel alike (Symbol#name is the
# same object at every call), and are what rules the leak out: no call
# allocates. The last test drives the fixed request-path APIs with Symbol
# keys and, where /proc/self/status gives the resident size (Linux), checks
# that 200,000 rounds do not grow it by the ~20 MB the leak would add.
require "cybertrain/key"
require "cybertrain/params"
require "cybertrain/session"
require "cybertrain/flash"
require "cybertrain/html"
require "cybertrain/i18n"
require "cybertrain/test"

test "Key.string_of names a Symbol with the same frozen String at every call" do
  a = Cybertrain::Key.string_of(:user_id)
  b = Cybertrain::Key.string_of(:user_id)
  assert_equal "user_id", a
  assert a.equal?(b)
  assert a.frozen?
end

test "Key.string_of answers a String key itself and to_s of anything else" do
  s = "title"
  assert s.equal?(Cybertrain::Key.string_of(s))
  assert_equal "7", Cybertrain::Key.string_of(7)
  assert_equal "", Cybertrain::Key.string_of(nil)
end

test "Symbol and String keys reach the same entries" do
  p = Cybertrain::Params.new
  p.set_value("id", "1")
  assert_equal "1", p[:id]
  assert_equal "1", p["id"]
  session = Cybertrain::Session.new
  session[:user_id] = 5
  assert_equal "5", session["user_id"]
  assert session.key?(:user_id)
  flash = Cybertrain::Flash.new
  flash.set_now(:notice, "saved")
  assert_equal "saved", flash[:notice]
  assert_equal "<p class=\"lead\">x</p>", Cybertrain::Html.tag(:p, { class: :lead }, "x").to_s
end

def resident_kb
  return -1 unless File.exist?("/proc/self/status")

  File.read("/proc/self/status").each_line do |line|
    return line.split[1].to_i if line.start_with?("VmRSS:")
  end
  -1
end

test "Symbol keys on the request path do not grow the process" do
  p = Cybertrain::Params.new
  p.set_value("id", "1")
  session = Cybertrain::Session.new({ "user_id" => "42" })
  flash = Cybertrain::Flash.new
  flash.set_now("notice", "saved")
  hits = 0
  round = lambda do
    hits += 1 if p[:id] == "1"
    hits += 1 if session[:user_id] == "42"
    hits += 1 if flash[:notice] == "saved"
    hits += 1 if Cybertrain::Html.tag(:p, { class: :lead }, "x").to_s == "<p class=\"lead\">x</p>"
    hits += 1 unless I18n.t(:"cybertrain.key_text.absent", default: "absent").empty?
  end
  1_000.times { round.call }
  before = resident_kb
  200_000.times { round.call }
  after = resident_kb
  assert_equal 201_000 * 5, hits
  # 5 pinned Strings a round would be over 100 MB; the budget leaves room
  # for allocator noise.
  # One assertion on every system: where the size cannot be read (macOS has
  # no /proc), before is -1 and it holds trivially.
  assert before < 0 || after - before < 20_000, "resident size grew by #{after - before} KB"
end

Cybertrain::Test.run!
