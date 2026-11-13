# Phase 5a spike: a statement `case` on a plain Integer, compiled after a
# statement `case` on a nullable Integer (a getbyte value) in another
# method. A record, not a test.
#
# Found when test/test_render_inline.rb and test/test_classes.rb failed to
# build: "html_reader.rb:276: error: '_o24' undeclared" in
# sp_HtmlReader_s_parse, at `case kind` (kind = tag_kind(...), a plain
# Integer). Cybertrain::Html.escape, compiled earlier in every program, has
# a statement `case b` on `b = str.getbyte(i)` (Integer or nil), and in
# those two programs it got the same temporary number (24) as `case kind`.
# Commit 50bbcb8 changed parse's code before the case, which moved the
# temporary number in test_integration.rb but not in every program: which
# number a temporary gets depends on how the code before it compiles,
# which depends on the types the whole program infers. Reduced to this
# program.
#
# Run (Spinel 2026.11.04.7026, from the repository root):
#   spinel spikes/phase5/case_nullable_temp.rb -o "${TMPDIR:-/tmp}/case_nullable_temp" && "${TMPDIR:-/tmp}/case_nullable_temp"
# Output: the C compilation fails:
#   case_nullable_temp.rb:...: error: '_o1' undeclared (first use in this function); did you mean '_t1'?
#   spinel: C compilation failed
# CRuby prints
#   amp
#   long
#
# What Spinel does (spinel ... -c -o x.c): `case b` in esc declares
# `sp_oint _o1 = lv_b; sp_int _t1 = _o1.v;` and switches on
# `_o1.nil ? 0LL : _t1`; `case k` in parse declares only `sp_int _t1 = lv_k;`
# but switches on `_o1.nil ? 0LL : _t1` too: the "subject is nullable"
# mark is remembered by temporary number across methods, and the later
# case with the same number takes it.
#
# Variations (each its own program, same build):
#   the two methods in the other order (parse first)   compiles; parse's
#     switch is `switch (_t1)`, esc's the nullable one
#   both cases as the method's value (`case ... end` returned, an
#     expression): compiles (`_o2` and `_t2`, each declared in its own
#     statement expression)
#   parse with an if / elsif chain on k instead of `case`: nothing to
#     take the mark (cybertrain/test/html_reader.rb's fix)
#
# Framework exposure: HtmlReader.parse (`case kind`, fixed with an if
# chain). Html.escape's `case b` is the nullable one that leaks; any later
# statement `case` on a plain Integer whose temporary lands on the same
# number in some program would fail the same way.
def esc(s)
  out = +""
  b = s.getbyte(0)
  case b
  when 38 then out << "amp"
  else out << "other"
  end
  out
end

def kind_of(s)
  return 1 if s.bytesize > 3

  0
end

def parse(s)
  out = +""
  k = kind_of(s)
  case k
  when 1 then out << "long"
  else out << "short"
  end
  out
end

puts esc("&x")
puts parse("abcd")
