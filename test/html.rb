require "cybertrain/html"
require "cybertrain/test"

test "escape converts all five special characters" do
  assert_equal "&amp;&lt;&gt;&quot;&#39;", Cybertrain::Html.escape("&<>\"'")
end

test "escape leaves safe text untouched" do
  assert_equal "hello world 123", Cybertrain::Html.escape("hello world 123")
end

test "out(nil) is an empty string" do
  assert_equal "", Cybertrain::Html.out(nil)
end

test "out(SafeString) is not escaped" do
  safe = Cybertrain::Html.safe("<b>bold</b>")
  assert_equal "<b>bold</b>", Cybertrain::Html.out(safe)
end

test "out(String) is escaped" do
  assert_equal "&lt;b&gt;", Cybertrain::Html.out("<b>")
end

test "out(Integer) and friends use to_s" do
  assert_equal "42", Cybertrain::Html.out(42)
  assert_equal "3.5", Cybertrain::Html.out(3.5)
  assert_equal "true", Cybertrain::Html.out(true)
  assert_equal "false", Cybertrain::Html.out(false)
end

test "SafeString#+ escapes the plain half" do
  safe = Cybertrain::Html.safe("<b>")
  combined = safe + "x<"
  assert combined.html_safe?
  assert_equal "<b>x&lt;", combined.to_s
end

test "SafeString#+ with another SafeString does not double-escape" do
  a = Cybertrain::Html.safe("<i>")
  b = Cybertrain::Html.safe("<u>")
  assert_equal "<i><u>", (a + b).to_s
end

test "SafeString#html_safe? is true" do
  assert Cybertrain::Html.safe("x").html_safe?
end

test "SafeString#== compares by string value" do
  a = Cybertrain::Html.safe("hi")
  b = Cybertrain::Html.safe("hi")
  assert_equal a, b
  assert_equal "hi", a.to_s
end

Cybertrain::Test.run!
