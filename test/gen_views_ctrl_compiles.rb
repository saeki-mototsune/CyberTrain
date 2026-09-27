require "cybertrain/test"
require_relative "fixtures/embed_ctrl/gen/views"

# gen/views.rb escapes control bytes (ESC, DEL, NUL) as \u00XX in its
# string literals; the compiled literal reads back to the original bytes.
# Also runs under CRuby.

test "a template with control bytes round-trips byte for byte" do
  expected = File.binread("test/fixtures/embed_ctrl/app/views/pages/ctrl.html.erb").bytes
  assert_equal expected, Gen::Views::SOURCES["pages/ctrl.html.erb"].bytes
  assert_equal 1, Gen::Views::SOURCES.size
end

Cybertrain::Test.run!
