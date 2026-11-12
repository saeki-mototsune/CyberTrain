# Phase 5a spike, item 2's second program: `1.month`, which phase 5a does
# not define (spec section 17), in a program where ZonedTime#month and
# Integer's duration methods exist. Is it refused at build, or does it
# raise NoMethodError when reached? A record, not a test.
#
# Run (Spinel 2026.11.04.7026, from the repository root):
#   spinel --strict-require -I . -I spikes/phase5 spikes/phase5/durations_month.rb -o $TMPDIR/m
#   $TMPDIR/m; $TMPDIR/m 1 2 3 4 5 6
# Output: it builds (12 s). With no arguments it prints `before: 300` and
# `after`; with six it prints `before: 300`, then
#   undefined method 'month' for an instance of Integer (NoMethodError)
# and exits 1, as CRuby does.
# The same lines with nothing in the program defining `month` (only
# `class Integer; def minutes = self * 60; end`) are refused at build:
#   spinel: bare.rb:5: undefined method 'month' for an instance of Integer (NoMethodError)
#   spinel: 1 refusal, nothing written
# Verdict: the refusal holds only while no class defines `month`. Phase 5a
# gives ZonedTime#month, so in an application `1.month` builds and raises
# NoMethodError when reached (spec section 16's run-time fallback).
require "standins/clock"

puts "before: #{5.minutes}"
puts "a month: #{1.month}" if ARGV.size > 5
puts "after"
