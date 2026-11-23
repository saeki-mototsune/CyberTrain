# Shared by the framework tests that start a CRuby of their own on the
# framework (`require_relative "support/spinel_http"`): the framework
# requires spinel-http, the HTTP layer (docs/design.md D91), so that Ruby
# needs its checkout on the load path too. Not a test program itself.
module SpinelHttpDir
  # The checkout spin.lock pins, as script/spinel_http_path.rb finds it
  # (fetched when missing); `scratch` is a file the answer passes through.
  # @param scratch [String]
  # @return [String]
  def self.path(scratch)
    raise "script/spinel_http_path.rb failed" unless system("sh", "-c", "ruby script/spinel_http_path.rb > \"$1\"", "sh", scratch)

    File.read(scratch).strip
  end
end
