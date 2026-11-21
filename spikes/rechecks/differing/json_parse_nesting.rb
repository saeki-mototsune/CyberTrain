# Evidence for docs/spinel-feedback.md AX (no NOTES rule). Kept until AX is
# closed.
# Where JSON.parse's nesting limit falls: for each kind of document, the
# deepest that parses and what the next depth raises, without and with
# max_nesting:.
#
#   ruby spikes/rechecks/differing/json_parse_nesting.rb
#   spinel spikes/rechecks/differing/json_parse_nesting.rb -O 0 -o "$TMPDIR/jpn" && "$TMPDIR/jpn"
#
# Linux x86_64, Spinel 2026.11.15.7033 (a2f3bfaa, GCC 13.3.0), CRuby 3.3.6,
# 2026-11-21. CRuby printed:
#   arrays around 1: depth 100 parses, depth 101 raises JSON::NestingError: nesting of 101 is too deep
#   arrays, the innermost empty: depth 100 parses, depth 101 raises JSON::NestingError: nesting of 101 is too deep
#   objects around 1: depth 100 parses, depth 101 raises JSON::NestingError: nesting of 101 is too deep
#   arrays around 1, max_nesting: 10: depth 10 parses, depth 11 raises JSON::NestingError: nesting of 11 is too deep
#   arrays, the innermost empty, max_nesting: 10: depth 10 parses, depth 11 raises JSON::NestingError: nesting of 11 is too deep
#   objects around 1, max_nesting: 10: depth 10 parses, depth 11 raises JSON::NestingError: nesting of 11 is too deep
#   arrays around 1, max_nesting: 0: every depth up to 400 parses
#   arrays around 1, max_nesting: 300: depth 300 parses, depth 301 raises JSON::NestingError: nesting of 301 is too deep
# The compiled program printed the same but for the second and fifth lines:
#   arrays, the innermost empty: depth 101 parses, depth 102 raises JSON::NestingError: nesting of 101 is too deep
#   arrays, the innermost empty, max_nesting: 10: depth 11 parses, depth 12 raises JSON::NestingError: nesting of 11 is too deep
# Built with Spinel 2026.11.04.7026 (a2d06115) the same day, every line
# but the second and fifth read "depth 200 parses, depth 201 raises
# JSON::ParserError: nesting too deep", with and without max_nesting:, and
# those two "depth 201 parses, depth 202 raises JSON::ParserError: nesting
# too deep".
require "json"

# `depth` arrays, one inside the other, around `inner`.
def arrays(depth, inner) = ("[" * depth) + inner + ("]" * depth)

# `depth` objects, one inside the other, the innermost holding 1.
def objects(depth) = ("{\"a\":" * depth) + "1" + ("}" * depth)

# "ok", or the class and message of what JSON.parse raised. `max` below
# zero means no max_nesting: option.
def parsed(text, max)
  if max < 0
    JSON.parse(text)
  else
    JSON.parse(text, max_nesting: max)
  end
  "ok"
rescue StandardError => e
  "#{e.class.name}: #{e.message}"
end

def document(kind, depth)
  case kind
  when "arrays around 1" then arrays(depth, "1")
  when "arrays, the innermost empty" then arrays(depth, "")
  else objects(depth)
  end
end

# The smallest depth, up to 400, at which JSON.parse raises.
def report(kind, max)
  label = max < 0 ? kind : "#{kind}, max_nesting: #{max}"
  depth = 1
  while depth <= 400
    result = parsed(document(kind, depth), max)
    if result != "ok"
      puts "#{label}: depth #{depth - 1} parses, depth #{depth} raises #{result}"
      return
    end
    depth += 1
  end
  puts "#{label}: every depth up to 400 parses"
end

report("arrays around 1", -1)
report("arrays, the innermost empty", -1)
report("objects around 1", -1)
report("arrays around 1", 10)
report("arrays, the innermost empty", 10)
report("objects around 1", 10)
report("arrays around 1", 0)
report("arrays around 1", 300)
