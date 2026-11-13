# Phase 5a spike, pre-flight R12 / N39: assert_select's polymorphic
# arguments. The positional `equality` is a String (the text), an Integer
# (the count), true / false (present or absent) or nil; `text:` is a String
# or a Regexp. One method takes them all; the matching is a toy over a list
# of [tag, text] pairs, since only the argument shapes are in question. A
# record, not a test.
#
# Run (Spinel 2026.11.04.7026, from the repository root):
#   spinel --strict-require -I . spikes/phase5/assert_select_args.rb -o $TMPDIR/as && $TMPDIR/as > $TMPDIR/as_spinel.txt
#   ruby -I. spikes/phase5/assert_select_args.rb > $TMPDIR/as_cruby.txt
#   diff $TMPDIR/as_spinel.txt $TMPDIR/as_cruby.txt && echo same
# Output (8 s to compile; CRuby 3.3.6 prints the same, so `same`):
#   String equality: 1
#   Integer equality: 2
#   true: 1
#   false: 0
#   nil: 2
#   text: String: 1
#   text: Regexp: 2
#   count:: 2
#   minimum: / maximum:: 2
#   a failure: FAIL Expected exactly 3 elements matching "li", found 2.
#   false, but present: FAIL Expected exactly 0 elements matching "h1", found 1.
# Verdict: PASS. `case equality when nil / String / Integer / true / false`
# and `case text when nil / Regexp / else` tell the boxed arguments apart.
require "cybertrain/test"

NODES = [%w[h1 Hello], %w[li one], %w[li two], %w[p body]].freeze

def matched(selector, text)
  NODES.select do |n|
    next false unless n[0] == selector

    case text
    when nil then true
    when Regexp then n[1].match?(text)
    else n[1] == text.to_s
    end
  end
end

def assert_select(selector, equality = nil, count: nil, minimum: nil, maximum: nil, text: nil)
  Cybertrain::Test.count_assertion
  want_text = text
  want_count = count
  want_min = minimum
  case equality
  when nil then nil
  when String then want_text = equality
  when Integer then want_count = equality
  when true then want_min = 1
  when false then want_count = 0
  else raise ArgumentError, "assert_select: equality must be a String, an Integer, true or false"
  end
  found = matched(selector, want_text).size
  want_min = 1 if want_count.nil? && want_min.nil? && maximum.nil?
  ok = true
  ok = false if !want_count.nil? && found != want_count
  ok = false if !want_min.nil? && found < want_min
  ok = false if !maximum.nil? && found > maximum
  flunk("Expected #{want_count.nil? ? "at least #{want_min || 0}" : "exactly #{want_count}"} elements matching #{selector.inspect}, found #{found}.") unless ok
  found
end

def show(label)
  puts "#{label}: #{yield}"
rescue Cybertrain::Test::AssertionFailed => e
  puts "#{label}: FAIL #{e.message}"
end

show("String equality") { assert_select "h1", "Hello" }
show("Integer equality") { assert_select "li", 2 }
show("true") { assert_select "p", true }
show("false") { assert_select "table", false }
show("nil") { assert_select "li" }
show("text: String") { assert_select "li", text: "two" }
show("text: Regexp") { assert_select "li", text: /o/ }
show("count:") { assert_select "li", count: 2 }
show("minimum: / maximum:") { assert_select "li", minimum: 1, maximum: 2 }
show("a failure") { assert_select "li", 3 }
show("false, but present") { assert_select "h1", false }
