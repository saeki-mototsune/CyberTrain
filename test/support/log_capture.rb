require "stringio"
require "cybertrain/logger"

# Shared by the framework tests that read log lines (each one
# `require_relative "support/log_capture"`). Not a test program itself:
# script/gate and script/test-shard read test/*.rb only.
#
# A log line is `<time> <LEVEL> [<tag>]... <message>` (spec section 12.1).
# Tests compare the level and the message, not the time and the tags, so
# that a tag added around a line (a request id, a job's kind and id) does
# not change what they assert: {LogCapture.entries} drops the time and the
# tags, leaving `"<LEVEL> <message>"`. A message that itself starts with
# `[` would lose that bracket group too; none of the framework's does.
# Byte-level reading, no regexp (pre-flight ruling G5).
module LogCapture
  # Runs the block with Cybertrain.logger writing into a StringIO at
  # :debug and answers what was logged; the logger found before is back
  # when the block ends, also when it raises (spikes/NOTES.md rule 103).
  def self.during
    saved = Cybertrain.logger
    sink = StringIO.new
    Cybertrain.logger = Cybertrain::Logger.new(sink, :debug)
    _value = yield
    sink.string
  ensure
    Cybertrain.logger = saved
  end

  # {with_scope}'s save-yield-ensure, in a module function.
  def self.scoped(scope)
    saved = Cybertrain::Logger.swap_scope(scope)
    _value = yield
    nil
  ensure
    Cybertrain::Logger.swap_scope(saved)
  end

  # Each line of `text` as `"<LEVEL> <message>"`: the time and the tags
  # dropped. A line without a time and a level (a continuation) is kept
  # as it is.
  def self.entries(text)
    out = Array.new(0) { "" }
    text.to_s.split("\n").each do |line|
      out << LogCapture.entry(line)
    end
    out
  end

  # One line as `"<LEVEL> <message>"` (see {entries}).
  def self.entry(line)
    s = line.to_s
    space = s.index(" ")
    return s if space.nil? || space == 0 || s.getbyte(space - 1) != 90 # "Z": the time's end

    rest = s[(space + 1)..].to_s
    level_end = rest.index(" ")
    return rest if level_end.nil?

    level = rest[0, level_end].to_s
    message = rest[(level_end + 1)..].to_s
    while message.start_with?("[")
      close = message.index("] ")
      break if close.nil?

      message = message[(close + 2)..].to_s
    end
    "#{level} #{message}"
  end

  # How many lines of `text` are at `level` with a message starting with
  # `message`; a `message` ending in "\n" must be the whole message.
  def self.count(text, level, message)
    whole = message.end_with?("\n")
    wanted = whole ? "#{level} #{message.chomp}" : "#{level} #{message}"
    n = 0
    LogCapture.entries(text).each do |e|
      n += 1 if whole ? e == wanted : e.start_with?(wanted)
    end
    n
  end
end

# What Cybertrain.logger wrote (at :debug) while the block ran.
def capture_log
  LogCapture.during { yield }
end

# Runs the block with `scope` (a Cybertrain::Logger::Scope) as this
# thread's log scope; the scope found before is back when the block ends,
# also when it raises (spikes/NOTES.md rule 103). Answers nil.
def with_scope(scope)
  LogCapture.scoped(scope) { yield }
end

# Passes when `log` has a line at `level` (`"INFO"`, `"WARN"`, ...) whose
# message starts with `message` (is `message`, when it ends in "\n"),
# whatever its time and tags: what `assert_includes log, "[LEVEL] message"`
# checked before the line had a time.
def assert_logged(log, level, message)
  assert LogCapture.count(log, level, message) > 0, "expected a #{level} line starting #{message.inspect} in:\n#{log}"
end
