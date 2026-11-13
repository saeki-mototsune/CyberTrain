require "cybertrain/test"
require "cybertrain/generator/locale_yaml"

# Gen::LocaleYaml.parse reads the YAML subset of spec section 8 that gen uses
# for config/locales/**/*.yml, and refuses the rest with "path:line: problem".
# Every scalar is kept as its text (D4): `3` is "3", `no` is "no", `~` is "".

def entries(yaml) = Cybertrain::Gen::LocaleYaml.parse(yaml, "config/locales/x.yml")
def entry_of(yaml, key) = entries(yaml).find { |e| e.entry_key == key }
def text_of(yaml, key) = entry_of(yaml, key).entry_text
def list_of(yaml, key) = entry_of(yaml, key).entry_list
def refusal(yaml) = (begin; entries(yaml); ""; rescue ArgumentError => e; e.message; end)

def en_entries = entries(File.read("test/fixtures/i18n/rails-i18n/en.yml"))
def ja_entries = entries(File.read("test/fixtures/i18n/rails-i18n/ja.yml"))

test "nested mappings flatten to dotted keys" do
  assert_equal "Posts", text_of("ja:\n  posts:\n    index:\n      title: Posts\n", "ja.posts.index.title")
  e = entries("en:\n  a:\n    b: x\n    c: y\n  d: z\n")
  assert_equal ["en.a.b", "en.a.c", "en.d"], e.map { |x| x.entry_key }
  assert_equal [3, 4, 5], e.map { |x| x.entry_line }
  assert_equal "config/locales/x.yml", e[0].entry_file
  assert_equal false, e[0].entry_is_list
  assert_equal [], e[0].entry_list
end

test "plain, single and double quoted scalars with escapes" do
  assert_equal "it's", text_of("en:\n  a: 'it''s'\n", "en.a")
  assert_equal "a\nb \"c\" é", text_of("en:\n  a: \"a\\nb \\\"c\\\" \\u00e9\"\n", "en.a")
  assert_equal "t\tb\\s/", text_of("en:\n  a: \"t\\tb\\\\s\\/\"\n", "en.a")
  assert_equal "a\\nb", text_of("en:\n  a: 'a\\nb'\n", "en.a")
  assert_equal "x y  z", text_of("en:\n  a: x y  z\n", "en.a")
  assert_equal "%{count} items", text_of("en:\n  a: \"%{count} items\"\n", "en.a")
end

test "block scalars | and >" do
  assert_equal "line 1\nline 2\n", text_of("en:\n  a: |\n    line 1\n    line 2\n", "en.a")
  assert_equal "one two\n", text_of("en:\n  a: >\n    one\n    two\n", "en.a")
  assert_equal "line 1\nline 2", text_of("en:\n  a: |-\n    line 1\n    line 2\n", "en.a")
  assert_equal "one two", text_of("en:\n  a: >-\n    one\n    two\n", "en.a")
  assert_equal "x\n\n", text_of("en:\n  a: |+\n    x\n\n", "en.a")
  assert_equal "p\n  q\nr\n", text_of("en:\n  a: |\n    p\n      q\n    r\n  b: s\n", "en.a")
  assert_equal "s", text_of("en:\n  a: |\n    p\n  b: s\n", "en.b")
end

test "sequences of scalars, block and flow, with ~ as empty" do
  e = entries("en:\n  date:\n    abbr_day_names: [Sun, Mon]\n    month_names:\n      - ~\n      - January\n")
  assert_equal ["Sun", "Mon"], e.find { |x| x.entry_key == "en.date.abbr_day_names" }.entry_list
  assert_equal ["", "January"], e.find { |x| x.entry_key == "en.date.month_names" }.entry_list
  assert_equal true, e[0].entry_is_list
  assert_equal "", e[0].entry_text
  assert_equal ["a, b", "c"], list_of("en:\n  a: ['a, b', \"c\"]\n", "en.a")
  assert_equal [], list_of("en:\n  a: []\n", "en.a")
  assert_equal ["x", "y"], list_of("en:\n  a:\n  - x\n  - y\n  b: z\n", "en.a")
  assert_equal "z", text_of("en:\n  a:\n  - x\n  - y\n  b: z\n", "en.b")
end

test "YAML 1.1 scalars, quotes, BOM, CRLF and tabs" do
  assert_equal "no", text_of("en:\n  a: no\n", "en.a")
  assert_equal "3", text_of("en:\n  a: 3\n", "en.a")
  assert_equal "1_000", text_of("en:\n  a: 1_000\n", "en.a")
  assert_equal "false", text_of("en:\n  a: false\n", "en.a")
  assert_equal "", text_of("en:\n  a: ~\n", "en.a")
  assert_equal "", text_of("en:\n  a: null\n", "en.a")
  assert_equal "", text_of("en:\n  a:\n  b: x\n", "en.a")
  assert_equal "a: b # c", text_of("en:\n  a: \"a: b # c\" # note\n", "en.a")
  assert_equal "a#b", text_of("en:\n  a: a#b # note\n", "en.a")
  assert_equal "x", text_of("\uFEFFen:\r\n  a: x\r\n", "en.a")
  assert_equal "x", text_of("---\n# c\nen:\n  # d\n  a: x\n", "en.a")
  assert_equal "config/locales/x.yml:2: tabs are not allowed in indentation", refusal("en:\n\ta: x\n")
end

test "refusals name file and line" do
  assert_equal "config/locales/x.yml:2: anchors and aliases are not supported", refusal("en:\n  a: &x y\n  b: *x\n")
  assert_equal "config/locales/x.yml:3: anchors and aliases are not supported", refusal("en:\n  a: y\n  b: *x\n")
  assert_equal "config/locales/x.yml:2: tags are not supported", refusal("en:\n  a: !ruby/object x\n")
  assert_equal "config/locales/x.yml:3: only one document per file", refusal("en:\n  a: x\n---\nja:\n  a: y\n")
  assert_equal "config/locales/x.yml:2: flow mappings are not supported; flow sequences may hold only scalars", refusal("en:\n  a: {b: c}\n")
  assert_equal "config/locales/x.yml:2: flow mappings are not supported; flow sequences may hold only scalars", refusal("en:\n  a: [b, [c]]\n")
  assert_equal "config/locales/x.yml:3: duplicate key \"a\"", refusal("en:\n  a: x\n  a: y\n")
  assert_equal "", refusal("en:\n  a:\n    b: x\n  c:\n    b: y\n")
  assert_equal "config/locales/x.yml:2: unterminated quoted string", refusal("en:\n  a: \"x\n")
  assert_equal "config/locales/x.yml:2: unterminated quoted string", refusal("en:\n  a: 'x\n")
  assert_equal "config/locales/x.yml:1: the top-level key must be a locale such as en or pt-BR (got \"posts\")", refusal("posts:\n  a: x\n")
  assert_equal "", refusal("pt-BR:\n  a: x\n")
  assert_equal "config/locales/x.yml:3: sequences may hold only scalars", refusal("en:\n  a:\n    - b: c\n")
end

test "rails-i18n's en.yml and ja.yml parse" do
  ja = ja_entries
  assert_equal "%Y/%m/%d", ja.find { |x| x.entry_key == "ja.date.formats.default" }.entry_text
  assert_equal ["日", "月", "火", "水", "木", "金", "土"], ja.find { |x| x.entry_key == "ja.date.abbr_day_names" }.entry_list
  assert_equal "を入力してください", ja.find { |x| x.entry_key == "ja.errors.messages.blank" }.entry_text
  assert_equal ["", "1月", "2月", "3月", "4月", "5月", "6月", "7月", "8月", "9月", "10月", "11月", "12月"],
    ja.find { |x| x.entry_key == "ja.date.abbr_month_names" }.entry_list
  assert_equal [":year", ":month", ":day"], ja.find { |x| x.entry_key == "ja.date.order" }.entry_list
  assert_equal "%{count}年", ja.find { |x| x.entry_key == "ja.datetime.distance_in_words.x_years" }.entry_text
  en = en_entries
  assert_equal "is too short (minimum is %{count} character)", en.find { |x| x.entry_key == "en.errors.messages.too_short.one" }.entry_text
  assert_equal "is too short (minimum is %{count} characters)", en.find { |x| x.entry_key == "en.errors.messages.too_short.other" }.entry_text
  assert_equal "$", en.find { |x| x.entry_key == "en.number.currency.format.unit" }.entry_text
  assert_equal "%u%n", en.find { |x| x.entry_key == "en.number.currency.format.format" }.entry_text
  assert_equal "false", en.find { |x| x.entry_key == "en.number.currency.format.significant" }.entry_text
  assert_equal "2", en.find { |x| x.entry_key == "en.number.currency.format.precision" }.entry_text
  assert_equal true, en.all? { |x| x.entry_key.start_with?("en.") }
  assert_equal true, ja.all? { |x| x.entry_key.start_with?("ja.") }
end

test "quoted keys are refused, not read with their quotes" do
  assert_equal "config/locales/x.yml:2: quoted keys are not supported", refusal("en:\n  \"b\": y\n")
  assert_equal "config/locales/x.yml:3: quoted keys are not supported", refusal("en:\n  a: x\n  'no': y\n")
  assert_equal "y", text_of("en:\n  b: \"y\"\n", "en.b")
end

test "a block sequence item must be a plain or quoted scalar" do
  m = "config/locales/x.yml:3: sequences may hold only scalars"
  assert_equal m, refusal("en:\n  a:\n    - [a, b]\n")
  assert_equal m, refusal("en:\n  a:\n    - - a\n")
  assert_equal m, refusal("en:\n  a:\n    - |\n")
  assert_equal m, refusal("en:\n  a:\n    - >\n")
  assert_equal m, refusal("en:\n  a:\n    - {b: c}\n")
  assert_equal ["[a, b]", "- a", "-x"], list_of("en:\n  a:\n    - \"[a, b]\"\n    - '- a'\n    - -x\n", "en.a")
end

test "text after a closed quoted scalar or flow sequence is refused" do
  assert_equal "config/locales/x.yml:2: unexpected text after a quoted string", refusal("en:\n  a: \"x\" !tag\n")
  assert_equal "config/locales/x.yml:2: unexpected text after a quoted string", refusal("en:\n  a: 'x' junk\n")
  assert_equal "config/locales/x.yml:2: unexpected text after a flow sequence", refusal("en:\n  a: [a, b] junk\n")
  assert_equal "config/locales/x.yml:2: unexpected text after a flow sequence", refusal("en:\n  a: [a][b]\n")
  assert_equal "config/locales/x.yml:3: unexpected text after a quoted string", refusal("en:\n  a:\n    - 'x' y\n")
  assert_equal "x", text_of("en:\n  a: \"x\"   # note\n", "en.a")
  assert_equal ["a", "b"], list_of("en:\n  a: [a, b]  # note\n", "en.a")
  assert_equal ["a]b"], list_of("en:\n  a: ['a]b']\n", "en.a")
end

test "\\u escapes need four hex digits and a valid code point" do
  m = "config/locales/x.yml:2: invalid \\u escape"
  assert_equal m, refusal("en:\n  a: \"\\u00zz\"\n")
  assert_equal m, refusal("en:\n  a: \"\\u00e\"\n")
  assert_equal m, refusal("en:\n  a: \"\\ud83d\"\n")
  assert_equal m, refusal("en:\n  a: \"\\ude00\"\n")
  assert_equal m, refusal("en:\n  a: \"\\ud83dx\"\n")
  assert_equal "\u{1F600}", text_of("en:\n  a: \"\\ud83d\\ude00\"\n", "en.a")
  assert_equal "é", text_of("en:\n  a: \"\\u00E9\"\n", "en.a")
end

test "multi-line scalars, a tag after --- and odd block headers are refused" do
  assert_equal "config/locales/x.yml:3: expected a key followed by \":\"; multi-line scalars are not supported, use | or >", refusal("en:\n  a: one\n    two\n")
  assert_equal "config/locales/x.yml:2: unterminated quoted string", refusal("en:\n  a: \"one\n    two\"\n")
  assert_equal "config/locales/x.yml:1: nothing may follow --- on its line", refusal("--- !tag\nen:\n  a: x\n")
  assert_equal "x", text_of("--- # c\nen:\n  a: x\n", "en.a")
  assert_equal "config/locales/x.yml:2: unsupported block scalar header \"|2\"", refusal("en:\n  a: |2\n      x\n")
  assert_equal "config/locales/x.yml:2: unsupported block scalar header \"|x\"", refusal("en:\n  a: |x\n    y\n")
  assert_equal "y\n", text_of("en:\n  a: | # note\n    y\n", "en.a")
end

Cybertrain::Test.run!
