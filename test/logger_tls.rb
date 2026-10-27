# Regression: a program with the TLS layer in it whose Logger io is only
# ever nil (the default Cybertrain.logger, as in an app that speaks wss://
# or https and never sets a logger) failed C compilation under Spinel
# 2026.10.26.7019: Logger#log's nil-only `@io.puts` went through the IO
# dispatch and was emitted as sp_File_puts_bin with an sp_String* argument.
# Nothing here may set a logger io.
#
# cybertrain/net/tls requires Spinel's openssl package, so the snapshot
# comes from the compiled binary (spikes/NOTES.md rule 23):
# script/regen-snapshot test/logger_tls.rb.
require "cybertrain/logger"
require "cybertrain/net/tls"
require "cybertrain/test"

Cybertrain.logger.info("hello")
Cybertrain.logger.debug("hidden")
Cybertrain.logger.warn("careful")

test "the default logger has no io and logs at :info" do
  assert_equal :info, Cybertrain.logger.level
end

Cybertrain::Test.run!
