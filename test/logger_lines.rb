require "json"
require "cybertrain/logger"
require "cybertrain/test"
require_relative "support/log_capture"

# The log line (spec sections 12.1 and 12.5, plan D2 and D3): the time in
# UTC with milliseconds, taken from the Clock so that it follows a test's
# travel, the level in capitals, the tags, the message; or one JSON object
# per line. Runs under CRuby and compiled. Byte checks instead of regexps
# (pre-flight ruling G5); restores go through plain helpers' `ensure`
# (ruling G4).

SINK = StringIO.new

def sink_logger(level = :info)
  Cybertrain::Logger.new(SINK, level)
end

# Turns JSON lines on for the block, off again after it.
def json_during
  Cybertrain::Logger.json_lines = true
  _value = yield
  nil
ensure
  Cybertrain::Logger.json_lines = false
end

def digit?(b)
  b >= 48 && b <= 57
end

# Whether `line` starts with `YYYY-MM-DDTHH:MM:SS.mmmZ `.
def timestamp_shape?(line)
  s = line.to_s
  return false if s.bytesize < 25

  shape = "dddd-dd-ddTdd:dd:dd.dddZ "
  i = 0
  while i < 25
    want = shape.getbyte(i)
    got = s.getbyte(i)
    if want == 100
      return false unless digit?(got)
    elsif want != got
      return false
    end
    i += 1
  end
  true
end

Cybertrain::Test.on_reset(-> { SINK.truncate(0); SINK.rewind; nil })

test "the line: UTC time with milliseconds, the level in capitals, the message, every level" do
  logger = sink_logger(:debug)
  travel_to(Time.utc(2026, 11, 11, 12)) do
    logger.debug("d")
    logger.info("i")
    logger.warn("w")
    logger.error("e")
    logger.fatal("f")
  end
  assert_equal "2026-11-11T12:00:00.000Z DEBUG d\n2026-11-11T12:00:00.000Z INFO i\n" \
               "2026-11-11T12:00:00.000Z WARN w\n2026-11-11T12:00:00.000Z ERROR e\n" \
               "2026-11-11T12:00:00.000Z FATAL f\n", SINK.string
end

test "real time has milliseconds and follows travel_back" do
  sink_logger.info("x")
  assert timestamp_shape?(SINK.string), SINK.string
  assert SINK.string.end_with?("Z INFO x\n"), SINK.string
  assert_equal 1, SINK.string.count("\n")
  travel_to(Time.utc(2001, 9, 9, 1, 46, 40)) do
    travel_to(Time.utc(2030, 1, 1)) { sink_logger.info("in") }
    sink_logger.info("out")
  end
  assert_includes SINK.string, "2030-01-01T00:00:00.000Z INFO in\n2001-09-09T01:46:40.000Z INFO out\n"
  sink_logger.info("back")
  last = SINK.string.split("\n").last.to_s
  assert timestamp_shape?(last), last
  refute last.start_with?("2001-09-09T01:46:40"), last
end

test "a travel without a block, freeze_time and travel_back move the line's time" do
  travel_to(Time.utc(2026, 11, 11, 12, 0, 1))
  sink_logger.warn("held")
  travel_back
  sink_logger.warn("real")
  lines = SINK.string.split("\n")
  assert_equal "2026-11-11T12:00:01.000Z WARN held", lines[0]
  refute lines[1].to_s.start_with?("2026-11-11T12:00:01"), lines[1].to_s
  freeze_time
  now = Cybertrain::Clock.now
  sink_logger.warn("frozen")
  stamp = "#{now.year}-#{now.month.to_s.rjust(2, "0")}-#{now.day.to_s.rjust(2, "0")}T" \
          "#{now.hour.to_s.rjust(2, "0")}:#{now.min.to_s.rjust(2, "0")}:#{now.sec.to_s.rjust(2, "0")}.000Z"
  assert_equal "#{stamp} WARN frozen", SINK.string.split("\n")[2]
end

test "Logger.timestamp formats the followed instant; -1 is real time" do
  Cybertrain::Logger.follow_clock(Time.utc(1999, 12, 31, 23, 59, 59).to_i * 1_000_000 + 7_500)
  assert_equal "1999-12-31T23:59:59.007Z", Cybertrain::Logger.timestamp
  Cybertrain::Logger.follow_clock(-1)
  assert timestamp_shape?("#{Cybertrain::Logger.timestamp} ")
  refute Cybertrain::Logger.timestamp.start_with?("1999")
end

test "a level below the logger's is silent; a message ending in a newline gets no second one" do
  logger = sink_logger(:warn)
  freeze_time
  logger.info("no")
  logger.warn("yes\n")
  assert_equal 1, SINK.string.count("\n")
  assert SINK.string.end_with?("Z WARN yes\n"), SINK.string
end

test "JSON lines: time, level, tags, message" do
  json_during do
    travel_to(Time.utc(2026, 11, 11, 12)) { sink_logger.info("Completed 200 in 12ms") }
  end
  assert_equal %({"time":"2026-11-11T12:00:00.000Z","level":"INFO","tags":[],"message":"Completed 200 in 12ms"}\n), SINK.string
end

test "format_line puts the request id apart from the other tags in JSON, in place in text" do
  tags = ["WelcomeJob 42", "3f2a9c1e-6c1d-4f0b-9a52-0d1e2f3a4b5c"]
  json = ""
  travel_to(Time.utc(2026, 11, 11, 12)) do
    assert_equal "2026-11-11T12:00:00.000Z ERROR [WelcomeJob 42] [3f2a9c1e-6c1d-4f0b-9a52-0d1e2f3a4b5c] boom\n",
                 Cybertrain::Logger.format_line("ERROR", tags, 1, "boom")
    json_during { json = Cybertrain::Logger.format_line("ERROR", tags, 1, "boom") }
  end
  assert_equal %({"time":"2026-11-11T12:00:00.000Z","level":"ERROR","request_id":"3f2a9c1e-6c1d-4f0b-9a52-0d1e2f3a4b5c","tags":["WelcomeJob 42"],"message":"boom"}\n),
               json
end

test "a JSON line's message drops the line's own newline" do
  json_during do
    travel_to(Time.utc(2026, 11, 11, 12)) { sink_logger.info("ends\n") }
  end
  assert_equal %({"time":"2026-11-11T12:00:00.000Z","level":"INFO","tags":[],"message":"ends"}\n), SINK.string
end

# The quoted form of a text whose `n` bytes are all replaced.
def replaced(prefix, n, suffix)
  "\"#{prefix}#{"\\ufffd" * n}#{suffix}\""
end

# What JSON.parse reads back from a quoted text (CRuby only: the compiled
# program checks the bytes alone).
def json_round_trip(quoted)
  JSON.parse("{\"m\":#{quoted}}")["m"].to_s
end

test "the byte scan refuses what is not UTF-8: every byte from 0x80 up is replaced" do
  invalid = [
    ["\xC0\xAF", 2], ["\xC1\xBF", 2],                   # overlong 2-byte
    ["\xE0\x80\xAF", 3], ["\xE0\x9F\xBF", 3],           # overlong 3-byte
    ["\xF0\x80\x80\xAF", 4], ["\xF0\x8F\xBF\xBF", 4],   # overlong 4-byte
    ["\xED\xA0\x80", 3], ["\xED\xBF\xBF", 3],           # UTF-8-encoded surrogates U+D800, U+DFFF
    ["\xF4\x90\x80\x80", 4],                            # U+110000, above U+10FFFF
    ["\x80", 1], ["\xBF", 1],                           # lone continuation bytes
    ["\xF5", 1], ["\xF6", 1], ["\xF7", 1], ["\xF8", 1], ["\xF9", 1], ["\xFA", 1],
    ["\xFB", 1], ["\xFC", 1], ["\xFD", 1], ["\xFE", 1], ["\xFF", 1],
    ["\xF5\x80\x80\x80", 4], ["\xE6\x97", 2],          # a lead byte 0xF5; a truncated character
    ["\xE6\x97\xA5\x80", 4]                             # a valid character, then a stray byte: all replaced
  ]
  invalid.each do |pair|
    bytes = pair[0].to_s.b
    n = pair[1].to_i
    quoted = Cybertrain::Logger.json_quote("a#{bytes}b".b)
    assert_equal replaced("a", n, "b"), quoted
    assert_equal "a#{"�" * n}b", json_round_trip(quoted) if RUBY_ENGINE == "ruby"
  end
end

test "valid UTF-8 is kept: U+10FFFF, U+2028, a CJK character, an emoji" do
  valid = ["\xF4\x8F\xBF\xBF", "\xE2\x80\xA8", "\xE6\x97\xA5", "\xF0\x9F\x98\x80", "\xC2\xA0"]
  valid.each do |text|
    utf8 = text.dup.force_encoding("UTF-8")
    assert_equal "\"a#{utf8}b\"", Cybertrain::Logger.json_quote("a#{text}b".b)
    assert_equal "\"a#{utf8}b\"", Cybertrain::Logger.json_quote("a#{utf8}b")
    assert_equal "a#{utf8}b", json_round_trip(Cybertrain::Logger.json_quote("a#{utf8}b")) if RUBY_ENGINE == "ruby"
  end
end

test "messages with control bytes, invalid UTF-8 and non-ASCII are one valid JSON line" do
  assert_equal %("a\\"b\\\\c\\nd\\te\\r\\u0001\\u001b[31m\\u007f"), Cybertrain::Logger.json_quote("a\"b\\c\nd\te\r\u0001\e[31m\x7f")
  assert_equal %("x\\ufffdy"), Cybertrain::Logger.json_quote("x\xFFy".b)
  assert_equal %("x\\ufffd\\ufffdy"), Cybertrain::Logger.json_quote("x\xE6\x97y".b)
  assert_equal %("日本"), Cybertrain::Logger.json_quote("日本")
  assert_equal %("日本"), Cybertrain::Logger.json_quote("日本".b)
  long = "z" * 100_000
  json_during { sink_logger.info("title: a\nb #{long}") }
  assert_equal 1, SINK.string.count("\n")
  assert_includes SINK.string, %("message":"title: a\\nb #{long}"}\n)
end

test "a JSON line's tag holding invalid UTF-8 or a newline stays one valid JSON line" do
  json_during do
    travel_to(Time.utc(2026, 11, 11, 12)) { sink_logger.tagged("x\xFF\ny".b) { sink_logger.info("tagged") } }
  end
  assert_equal %({"time":"2026-11-11T12:00:00.000Z","level":"INFO","tags":["x\\ufffd\\ny"],"message":"tagged"}\n),
               SINK.string
  if RUBY_ENGINE == "ruby"
    assert_equal ["x�\ny"], JSON.parse(SINK.string)["tags"]
  end
end

test "a long text line is one line, whole" do
  long = "y" * 100_000
  sink_logger.info("a\nb #{long}")
  assert_equal 2, SINK.string.count("\n")
  assert SINK.string.end_with?("Z INFO a\nb #{long}\n")
end

test "capture_log answers what Cybertrain.logger wrote, debug included, and puts the logger back" do
  before = Cybertrain.logger
  log = capture_log do
    Cybertrain.logger.debug("low")
    Cybertrain.logger.error("high")
  end
  assert Cybertrain.logger.equal?(before)
  assert_equal ["DEBUG low", "ERROR high"], LogCapture.entries(log)
  assert_logged log, "ERROR", "hi"
  assert_logged log, "ERROR", "high\n"
  assert_equal 0, LogCapture.count(log, "ERROR", "hi\n")
  assert_equal 0, LogCapture.count(log, "INFO", "high")
  assert_equal "INFO text [d]", LogCapture.entry("2026-11-11T12:00:00.000Z INFO [a] [b c] text [d]")
end

Cybertrain::Test.run!
