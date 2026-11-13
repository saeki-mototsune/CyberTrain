# Phase 5a spike, item 5 (spec section 16): what `e.backtrace` answers in a
# release build, a `-g` build and a `--debug` build, and what a debug build
# costs. A record, not a test.
#
# The request rate is in-process (no wrk on the spike machine, and bench/run
# needs it): each request is a raw HTTP/1.1 head parsed by HttpParser, a
# Request, a Context, the Router, the handler, and Response#to_http.
#
# Run (Spinel 2026.11.04.7026, from the repository root; a shared 4-vCPU
# cloud machine; three runs each, the rates vary by about 10%):
#   spinel --strict-require -I . spikes/phase5/backtrace.rb -o $TMPDIR/release          (23 s, 1,435,960 bytes)
#   spinel --strict-require -I . spikes/phase5/backtrace.rb -o $TMPDIR/g -g             (30 s, 4,996,832 bytes)
#   spinel --strict-require -I . spikes/phase5/backtrace.rb -o $TMPDIR/debug --debug    (11 s, 3,847,032 bytes)
# Output, release (95,000 to 115,000 req/s):
#   a raise three methods deep: 0 frames
#   a builtin's raise (Integer("x")): 0 frames
# -g (about 100,000 req/s):
#   a raise three methods deep: 1 frames
#     spikes/phase5/backtrace.rb:1:in `<main>'
#   a builtin's raise (Integer("x")): 1 frames
#     spikes/phase5/backtrace.rb:1:in `<main>'
# --debug (44,000 to 47,000 req/s, about 45% of release):
#   a raise three methods deep: 4 frames
#     spikes/phase5/backtrace.rb:21:in `Spike.inner'
#     spikes/phase5/backtrace.rb:18:in `Spike.middle'
#     spikes/phase5/backtrace.rb:17:in `Spike.outer'
#     spikes/phase5/backtrace.rb:1:in `<main>'
#   a builtin's raise (Integer("x")): 1 frames
#     spikes/phase5/backtrace.rb:1:in `<main>'
# Verdict: a release build answers an empty Array; --debug answers
# `file:line:in 'method'` frames for Ruby methods (the raising line and each
# caller's), but `<main>` is always line 1 and a builtin's raise has no
# frame of its own. --debug is -O0: faster to compile, about half the speed.
require "cybertrain/html"
require "cybertrain/http/parser"
require "cybertrain/http/request"
require "cybertrain/http/response"
require "cybertrain/router"

module Spike
  def self.outer(n) = middle(n)
  def self.middle(n) = inner(n)

  def self.inner(n)
    raise ArgumentError, "boom #{n}" if n > 0

    n
  end
end

def show(label, frames)
  shown = frames.nil? ? "nil" : "#{frames.size} frames"
  puts "#{label}: #{shown}"
  return if frames.nil?

  frames.first(5).each { |f| puts "  #{f}" }
end

begin
  Spike.outer(1)
rescue ArgumentError => e
  show("a raise three methods deep", e.backtrace)
end

begin
  Integer("x")
rescue ArgumentError => e
  show("a builtin's raise (Integer(\"x\"))", e.backtrace)
end

router = Cybertrain::Router.new
router.get("/posts/:id", "post") { |c| c.response.body = "show #{c.params[:id]}" }
head = "GET /posts/42 HTTP/1.1\r\nHost: localhost\r\nAccept: text/html\r\nUser-Agent: spike\r\n"
n = ARGV.empty? ? 200_000 : ARGV[0].to_i
bytes = 0
started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
n.times do
  h = Cybertrain::HttpParser.parse_head(head)
  ctx = Cybertrain::Context.new(Cybertrain::Request.new(h.method, h.target, h.headers, "", "127.0.0.1"))
  router.call(ctx)
  bytes += ctx.response.to_http.bytesize
end
elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
STDERR.puts "#{n} requests in #{elapsed.round(3)} s: #{(n / elapsed).round} req/s (#{bytes} bytes)"
