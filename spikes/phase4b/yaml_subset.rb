# Phase 4b spike, item 6a (spec section 12): the YAML subset reader
# (locale_yaml.rb, beside this file) in a compiled program shaped like an
# application's bin/gen.rb (the generator, a routes draw, the paths from
# ARGV), on rails-i18n's en.yml and ja.yml and the 2,000-key generated
# keys2000.yml. Each file is flattened to sorted `key=value` lines (a
# sequence as `key=[a|b|c]`, "\n" written as \n) and the output diffed
# with CRuby's run of the same program, and with yaml_reference.rb, which
# reads the same files through CRuby's Psych.parse (scalar node text, so
# no YAML 1.1 typing). A record, not a test.
#
# Ruling F1 of the phase 4b pre-flight dropped R3's Psych branch, so this
# program measures the subset reader only (the brief's yaml_psych.rb).
#
# Run (Spinel 2026.11.04.7026, from spikes/phase4b/):
#   time spinel $(spin flags) yaml_subset.rb -o $TMPDIR/yaml_subset && ls -l $TMPDIR/yaml_subset
#   F="../../test/fixtures/i18n/rails-i18n/en.yml ../../test/fixtures/i18n/rails-i18n/ja.yml keys2000.yml"
#   $TMPDIR/yaml_subset $F > $TMPDIR/spinel.txt
#   ruby -I../.. yaml_subset.rb $F > $TMPDIR/cruby.txt
#   ruby yaml_reference.rb $F > $TMPDIR/psych.txt
#   diff <(grep -v '^#' $TMPDIR/spinel.txt) <(grep -v '^#' $TMPDIR/cruby.txt) && diff <(grep -v '^#' $TMPDIR/spinel.txt) $TMPDIR/psych.txt && echo same
# Output (14.1 s to compile, an 840,680-byte binary; one cloud vCPU of 4):
#   # en.yml: 127 keys (5 sequences), parsed in 0.44 ms
#   # ja.yml: 108 keys (5 sequences), parsed in 0.45 ms
#   # keys2000.yml: 2000 keys (20 sequences), parsed in 6.23 ms
#   ...2,235 sorted key=value lines, then the two diffs print nothing:
#   same
# Three runs: 0.43 to 0.50 ms for each rails-i18n file and 5.3 to 6.2 ms
# for keys2000.yml; CRuby 3.3.6 runs the same reader in 3.6 to 6.1 ms and
# 33 to 52 ms. Sample lines (the Spinel, CRuby and Psych outputs agree on
# every one):
#   ja.date.abbr_month_names=[|1月|2月|3月|4月|5月|6月|7月|8月|9月|10月|11月|12月]
#   ja.date.order=[:year|:month|:day]
#   ja.number.format.precision=3
#   en.number.format.precision=3
#   en.section_00.key_04=Line one of 4\nLine two of %{x}\n
#   en.section_00.key_07=Café %{name} "7"
# Also checked, with the same three-way diff, a file with a BOM, CRLF line
# ends, a `>` scalar with a blank line, `|-`, `|+`, `[Sun, "Mon", ~]`,
# `1_000` and `no` (kept as written, D4); and Task 2's nine refusal inputs
# (anchor, second document, tab, unterminated quote, top-level key, a
# mapping in a sequence, duplicate key, flow mapping, tag), each refused
# with the plan's message and line, the same compiled and under CRuby.
# Verdict: PASS; gen uses the subset reader (Psych is not in the program).
require "cybertrain/generator"
require_relative "locale_yaml"

Cybertrain::Routes.draw do
  root "articles#index"
end

def flat_value(e)
  text = e.entry_is_list ? "[#{e.entry_list.join("|")}]" : e.entry_text
  text.gsub("\n", "\\n")
end

status = 0
ARGV.each do |path|
  text = File.read(path)
  t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  entries = []
  begin
    entries = Cybertrain::Gen::LocaleYaml.parse(text, path)
  rescue ArgumentError => e
    puts "# refused: #{e.message}"
    status = 1
  end
  t1 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  lists = 0
  entries.each { |x| lists += 1 if x.entry_is_list }
  # Timing lines start with "#", so the diff can drop them.
  puts "# #{File.basename(path)}: #{entries.size} keys (#{lists} sequences), parsed in #{((t1 - t0) * 1000).round(2)} ms"
  lines = entries.map { |x| "#{x.entry_key}=#{flat_value(x)}" }
  lines.sort.each { |l| puts l }
end
exit(status)
