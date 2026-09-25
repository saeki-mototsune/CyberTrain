require "cybertrain/version"
require "cybertrain/logger"
require "cybertrain/test"
require "stringio"

# Regression: cybertrain/version opens `module Cybertrain` before
# cybertrain/logger does. Cybertrain.logger used to be backed by a
# `@@logger` class variable, which mis-compiles under Spinel whenever
# `module Cybertrain` was already open (see cybertrain/logger.rb notes).

test "info logs at the default :info level" do
  sink = StringIO.new
  logger = Cybertrain::Logger.new(sink)
  logger.info("hello")
  assert_equal "[INFO] hello\n", sink.string
end

test "debug is silent at :info level" do
  sink = StringIO.new
  logger = Cybertrain::Logger.new(sink)
  logger.debug("hidden")
  assert_equal "", sink.string
end

test "debug prints once the level is lowered to :debug" do
  sink = StringIO.new
  logger = Cybertrain::Logger.new(sink, :debug)
  logger.debug("shown")
  assert_equal "[DEBUG] shown\n", sink.string
end

test "warn and error always print" do
  sink = StringIO.new
  logger = Cybertrain::Logger.new(sink)
  logger.warn("careful")
  logger.error("boom")
  assert_equal "[WARN] careful\n[ERROR] boom\n", sink.string
end

test "raising the level silences lower-severity messages" do
  sink = StringIO.new
  logger = Cybertrain::Logger.new(sink)
  logger.level = :error
  logger.info("skip")
  logger.warn("skip too")
  logger.error("kept")
  assert_equal "[ERROR] kept\n", sink.string
end

test "Cybertrain.logger returns the same object twice" do
  assert_equal Cybertrain.logger, Cybertrain.logger
end

test "Cybertrain.logger= swaps the process-wide logger" do
  sink = StringIO.new
  custom = Cybertrain::Logger.new(sink)
  Cybertrain.logger = custom
  assert_equal custom, Cybertrain.logger
  Cybertrain.logger.info("via global")
  assert_equal "[INFO] via global\n", sink.string
end

test "an unrecognized level falls back to :info instead of raising" do
  sink = StringIO.new
  logger = Cybertrain::Logger.new(sink, :bogus)
  assert_equal :info, logger.level
  logger.level = :also_bogus
  assert_equal :info, logger.level
  logger.info("still works")
  assert_equal "[INFO] still works\n", sink.string
end

Cybertrain::Test.run!
