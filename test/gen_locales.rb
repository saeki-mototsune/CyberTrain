# The fixture's checked-in gen/locales.rb comes first, before anything
# that could load cybertrain/i18n: the generated file requires it itself
# (plan decision D3), so this program does not compile (nor load under
# CRuby) if it stops doing so.
require_relative "fixtures/locales_app/gen/locales"
require "tmpdir"
require "cybertrain/test"
require "cybertrain/generator"
require "cybertrain/locales/bundled"

# gen/locales.rb (spec section 8, plan decisions D2-D4): the scan of
# config/locales/**/*.yml, the merge across files, the emitted lookup, the
# Runner's output pair and the bundled dictionaries of script/bundle-locales.
# Runs on a copy of test/fixtures/locales_app in a temporary directory.

FIXTURE = "test/fixtures/locales_app"
TMP = Dir.mktmpdir("cybertrain-gen-locales")
LOCALE_FILES = ["config/locales/en.yml", "config/locales/ja.yml", "config/locales/posts/ja.yml"]

def remove_tree(path)
  if File.directory?(path)
    Dir.children(path).each { |child| remove_tree("#{path}/#{child}") }
    Dir.rmdir(path)
  elsif File.exist?(path)
    File.delete(path)
  end
  nil
end

at_exit { remove_tree(TMP) }

Cybertrain::Gen::Runner.make_dirs("#{TMP}/app/config/locales/posts")
LOCALE_FILES.each { |f| File.write("#{TMP}/app/#{f}", File.read("#{FIXTURE}/#{f}")) }

# A tree of its own under TMP holding `files` (path => text).
def locale_tree(name, files)
  root = "#{TMP}/#{name}"
  files.each do |rel, text|
    Cybertrain::Gen::Runner.make_dirs(File.dirname("#{root}/#{rel}"))
    File.write("#{root}/#{rel}", text)
  end
  root
end

# One line per entry: key, value (a list joined with |), file:line.
def summary(entries)
  out = +""
  entries.each do |e|
    value = e.entry_is_list ? "[#{e.entry_list.join("|")}]" : e.entry_text
    out << "#{e.entry_key}=#{value}@#{e.entry_file}:#{e.entry_line}\n"
  end
  out
end

def scan_refusal(root)
  Cybertrain::Gen::LocaleScan.scan(root)
  ""
rescue ArgumentError => e
  e.message
end

test "the scan merges files, a later file's key wins" do
  expected = <<~'TEXT'
    en.posts.index.title=Posts@config/locales/en.yml:4
    en.posts.index.notice=Say "hi" #{not_ruby}
    then 100%@config/locales/en.yml:5
    en.date.abbr_day_names=[Sun|Mon|Tue|Wed|Thu|Fri|Sat]@config/locales/en.yml:7
    en.date.abbr_month_names=[|Jan|Feb]@config/locales/en.yml:8
    ja.posts.index.title=投稿@config/locales/posts/ja.yml:5
    ja.posts.index.empty=投稿はありません@config/locales/ja.yml:5
    ja.date.abbr_day_names=[日|月]@config/locales/ja.yml:7
  TEXT
  assert_equal expected, summary(Cybertrain::Gen::LocaleScan.scan("#{TMP}/app"))
  # A later file's list replaces an earlier text, and a text an earlier
  # list (both are leaves); keys of one file only are kept.
  root = locale_tree("leaves", { "config/locales/a.yml" => "ja:\n  x: a\n  y: [p, q]\n  only_a: 1\n",
                                 "config/locales/b.yml" => "ja:\n  x: [b, c]\n  y: r\n" })
  assert_equal "ja.x=[b|c]@config/locales/b.yml:2\nja.y=r@config/locales/b.yml:3\nja.only_a=1@config/locales/a.yml:4\n",
               summary(Cybertrain::Gen::LocaleScan.scan(root))
  # Only .yml files count, and no config/locales directory is no entries.
  root = locale_tree("other_files", { "config/locales/en.yml" => "en:\n  a: b\n", "config/locales/README.md" => "en:\n  a: c\n",
                                      "config/locales/en.yml~" => "en:\n  a: d\n" })
  assert_equal "en.a=b@config/locales/en.yml:2\n", summary(Cybertrain::Gen::LocaleScan.scan(root))
  assert_equal 0, Cybertrain::Gen::LocaleScan.scan("#{TMP}/nowhere").size
end

test "a mapping in one file and a scalar in another is refused naming both" do
  root = locale_tree("refused_scalar", { "config/locales/a.yml" => "ja:\n  posts:\n    title:\n      one: x\n",
                                         "config/locales/b.yml" => "# 1\n# 2\n# 3\n# 4\nja:\n  posts:\n    title: y\n" })
  assert_equal "config/locales/b.yml:7: ja.posts.title is a mapping in config/locales/a.yml:3", scan_refusal(root)
  root = locale_tree("refused_mapping", { "config/locales/a.yml" => "ja:\n  posts:\n    title: y\n",
                                          "config/locales/b.yml" => "ja:\n  posts:\n    title:\n      one: x\n" })
  assert_equal "config/locales/b.yml:3: ja.posts.title is a scalar in config/locales/a.yml:3", scan_refusal(root)
  root = locale_tree("refused_list", { "config/locales/a.yml" => "ja:\n  posts:\n    title: [a, b]\n",
                                       "config/locales/b.yml" => "ja:\n  posts:\n    title:\n      one: x\n" })
  assert_equal "config/locales/b.yml:3: ja.posts.title is a list in config/locales/a.yml:3", scan_refusal(root)
  # A scalar where a later file nests a mapping two levels down.
  root = locale_tree("refused_prefix", { "config/locales/a.yml" => "ja:\n  posts: x\n",
                                         "config/locales/b.yml" => "ja:\n  posts:\n    index:\n      title: y\n" })
  assert_equal "config/locales/b.yml:2: ja.posts is a scalar in config/locales/a.yml:2", scan_refusal(root)
  # A subdirectory's file sorts by its path: config/locales/a/x.yml is
  # read before config/locales/b.yml.
  root = locale_tree("refused_nested", { "config/locales/b.yml" => "ja:\n  posts: x\n",
                                         "config/locales/a/x.yml" => "ja:\n  posts:\n    title: y\n" })
  assert_equal "config/locales/b.yml:2: ja.posts is a mapping in config/locales/a/x.yml:2", scan_refusal(root)
  # The other side: mappings in both files merge, as do scalars in both.
  root = locale_tree("merged", { "config/locales/a.yml" => "ja:\n  posts:\n    title:\n      one: x\n",
                                 "config/locales/b.yml" => "ja:\n  posts:\n    title:\n      other: y\n" })
  assert_equal "", scan_refusal(root)
  assert_equal "ja.posts.title.one=x@config/locales/a.yml:4\nja.posts.title.other=y@config/locales/b.yml:4\n",
               summary(Cybertrain::Gen::LocaleScan.scan(root))
  # A file's own refusal (LocaleYaml) names that file.
  root = locale_tree("bad_file", { "config/locales/en.yml" => "en:\n  a: &x b\n" })
  assert_equal "config/locales/en.yml:2: anchors and aliases are not supported", scan_refusal(root)
end

test "the emitted source writes fill methods of at most 50 keys" do
  entries = [Cybertrain::Gen::LocaleEntry.new("ja.b", "x\"#\n", Array.new(0) { "" }, false, "config/locales/ja.yml", 2),
             Cybertrain::Gen::LocaleEntry.new("en.a", "", ["", "y"], true, "config/locales/en.yml", 2),
             Cybertrain::Gen::LocaleEntry.new("en.c", "", Array.new(0) { "" }, true, "config/locales/en.yml", 3)]
  expected = <<~'RUBY'
    # Generated by `spin run gen` from config/locales. Do not edit.
    require "cybertrain/i18n"

    module Gen
      module Locales
        def self.fill_texts_00(h)
          h["ja.b"] = "x\"\#\n"
          nil
        end

        def self.text_table
          h = { "" => "" }
          h.delete("")
          fill_texts_00(h)
          h
        end

        def self.fill_lists_00(h)
          h["en.a"] = ["", "y"]
          h["en.c"] = Array.new(0) { "" }
          nil
        end

        def self.list_table
          h = { "" => [""] }
          h.delete("")
          fill_lists_00(h)
          h
        end

        TEXTS = Gen::Locales.text_table.freeze
        LISTS = Gen::Locales.list_table.freeze

        def self.lookup(key) = TEXTS[key]

        def self.lookup_list(key) = LISTS.fetch(key, [])

        def self.resolver = ->(key) { Gen::Locales.lookup(key) }

        def self.list_resolver = ->(key) { Gen::Locales.lookup_list(key) }
      end
    end

    I18n.install_dictionary(Gen::Locales.resolver, Gen::Locales.list_resolver)
  RUBY
  assert_equal expected, Cybertrain::Gen::LocalesEmitter.emit(entries)
  # Without install: no require, no install line; the module path nests.
  bundled = Cybertrain::Gen::LocalesEmitter.emit(entries, "Cybertrain::BundledLocales", false)
  assert bundled.start_with?("# Generated by script/bundle-locales from cybertrain/locales. Do not edit.\n\nmodule Cybertrain\n  module BundledLocales\n")
  assert_includes bundled, "    TEXTS = Cybertrain::BundledLocales.text_table.freeze\n"
  assert_includes bundled, "    def self.resolver = ->(key) { Cybertrain::BundledLocales.lookup(key) }\n"
  assert bundled.end_with?("{ Cybertrain::BundledLocales.lookup_list(key) }\n  end\nend\n")
  refute bundled.include?("require")
  refute bundled.include?("install_dictionary")
  # 51 texts: 50 stores in fill_texts_00, the last in fill_texts_01; keys
  # sorted.
  many = Array.new(0) { Cybertrain::Gen::LocaleEntry.new("", "", Array.new(0) { "" }, false, "", 0) }
  i = 50
  while i >= 0
    many << Cybertrain::Gen::LocaleEntry.new("en.k#{format("%02d", i)}", "v#{i}", Array.new(0) { "" }, false, "config/locales/en.yml", i + 2)
    i -= 1
  end
  source = Cybertrain::Gen::LocalesEmitter.emit(many)
  assert_includes source, "    def self.fill_texts_00(h)\n      h[\"en.k00\"] = \"v0\"\n"
  assert_includes source, "      h[\"en.k49\"] = \"v49\"\n      nil\n    end\n\n    def self.fill_texts_01(h)\n      h[\"en.k50\"] = \"v50\"\n      nil\n    end\n"
  assert_includes source, "      fill_texts_00(h)\n      fill_texts_01(h)\n      h\n"
  refute source.include?("fill_texts_02")
  # No entries at all: seeded empty tables, no fill methods.
  empty = Cybertrain::Gen::LocalesEmitter.emit(Array.new(0) { Cybertrain::Gen::LocaleEntry.new("", "", Array.new(0) { "" }, false, "", 0) })
  assert_includes empty, "    def self.text_table\n      h = { \"\" => \"\" }\n      h.delete(\"\")\n      h\n    end\n"
  assert_includes empty, "    def self.list_table\n      h = { \"\" => [\"\"] }\n      h.delete(\"\")\n      h\n    end\n"
  refute empty.include?("fill_")
end

# The fixture's checked-in gen/locales.rb, required at the top: a stale
# file is rewritten so that the next build picks it up.
test "the emitted lookup answers Strings, lists and nil" do
  source = Cybertrain::Gen::Runner.locales_source(FIXTURE)
  unless File.read("#{FIXTURE}/gen/locales.rb") == source
    File.write("#{FIXTURE}/gen/locales.rb", source)
    flunk("fixture stale: #{FIXTURE}/gen/locales.rb (rewritten; rebuild and rerun)")
  end
  assert_equal "投稿", Gen::Locales.lookup("ja.posts.index.title")
  assert_equal "Posts", Gen::Locales.lookup("en.posts.index.title")
  assert_equal "投稿はありません", Gen::Locales.lookup("ja.posts.index.empty")
  assert_equal "Say \"hi\" \#{not_ruby}\nthen 100%", Gen::Locales.lookup("en.posts.index.notice")
  assert Gen::Locales.lookup("ja.nope").nil?
  # A list key is no String, a String key no list, a mapping neither.
  assert Gen::Locales.lookup("en.date.abbr_day_names").nil?
  assert Gen::Locales.lookup("ja.posts.index").nil?
  assert_equal "Mon", Gen::Locales.lookup_list("en.date.abbr_day_names")[1]
  assert_equal ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"], Gen::Locales.lookup_list("en.date.abbr_day_names")
  assert_equal ["", "Jan", "Feb"], Gen::Locales.lookup_list("en.date.abbr_month_names")
  assert_equal ["日", "月"], Gen::Locales.lookup_list("ja.date.abbr_day_names")
  assert_equal [], Gen::Locales.lookup_list("en.nope")
  assert_equal [], Gen::Locales.lookup_list("en.posts.index.title")
  # The lambdas handed to I18n.install_dictionary answer the same.
  key = "ja.posts.index.title"
  assert_equal "投稿", Gen::Locales.resolver.call(key)
  absent = "ja.nope"
  assert Gen::Locales.resolver.call(absent).nil?
  list_key = "ja.date.abbr_day_names"
  assert_equal "月", Gen::Locales.list_resolver.call(list_key)[1]
  assert_equal 0, Gen::Locales.list_resolver.call(absent).size
end

test "the generated gen/locales.rb loads on its own, without cybertrain/i18n preloaded" do
  source = File.read("#{FIXTURE}/gen/locales.rb")
  assert source.start_with?("# Generated by `spin run gen` from config/locales. Do not edit.\nrequire \"cybertrain/i18n\"\n")
  assert source.end_with?("\nI18n.install_dictionary(Gen::Locales.resolver, Gen::Locales.list_resolver)\n")
  # A fresh CRuby with nothing else required loads the file, and its
  # lookup answers.
  script = "require \"./#{FIXTURE}/gen/locales\"; " \
           "exit(Gen::Locales.lookup(\"ja.posts.index.title\") == \"\\u6295\\u7A3F\" && Gen::Locales.lookup_list(\"en.date.abbr_day_names\")[1] == \"Mon\" ? 0 : 3)"
  assert system("ruby", "-I", ".", "-e", script)
  # Without the require the same load fails: I18n is undefined.
  stripped = "#{TMP}/without_require.rb"
  File.write(stripped, source.sub("require \"cybertrain/i18n\"\n", ""))
  refute system("ruby", "-I", ".", "-e", "begin; require \"#{stripped}\"; rescue NameError; exit 4; end")
end

test "gen --check reports a stale gen/locales.rb" do
  root = "#{TMP}/app"
  assert_equal 0, Cybertrain::Gen::Runner.run(root, [])
  assert_equal Cybertrain::Gen::Runner.locales_source(root), File.read("#{root}/gen/locales.rb")
  assert_includes File.read("#{root}/gen/locales.rb"), "      h[\"ja.posts.index.title\"] = \"投稿\"\n"
  assert_equal 0, Cybertrain::Gen::Runner.run(root, ["--check"])
  written = File.read("#{root}/gen/locales.rb")
  original = File.read("#{root}/config/locales/ja.yml")
  File.write("#{root}/config/locales/ja.yml", original.sub("投稿はありません", "まだありません"))
  assert_equal 1, Cybertrain::Gen::Runner.run(root, ["--check"])
  assert_equal written, File.read("#{root}/gen/locales.rb")
  assert_equal 0, Cybertrain::Gen::Runner.run(root, [])
  assert_includes File.read("#{root}/gen/locales.rb"), "      h[\"ja.posts.index.empty\"] = \"まだありません\"\n"
  File.write("#{root}/config/locales/ja.yml", original)
  assert_equal 1, Cybertrain::Gen::Runner.run(root, ["--check"])
  assert_equal 0, Cybertrain::Gen::Runner.run(root, [])
  assert_equal 0, Cybertrain::Gen::Runner.run(root, ["--check"])
  # No config/locales: gen/locales.rb is still written, its tables empty.
  bare = "#{TMP}/bare"
  Dir.mkdir(bare)
  assert_equal 0, Cybertrain::Gen::Runner.run(bare, [])
  assert_equal Cybertrain::Gen::LocalesEmitter.emit(Array.new(0) { Cybertrain::Gen::LocaleEntry.new("", "", Array.new(0) { "" }, false, "", 0) }),
               File.read("#{bare}/gen/locales.rb")
  assert_includes File.read("#{bare}/gen/app.rb"), "require_relative \"assets\"\nrequire_relative \"locales\"\n"
end

test "the bundled dictionaries answer rails-i18n's keys" do
  assert_equal "can't be blank", Cybertrain::BundledLocales.lookup("en.errors.messages.blank")
  assert_equal "を入力してください", Cybertrain::BundledLocales.lookup("ja.errors.messages.blank")
  assert_equal "%{attribute} %{message}", Cybertrain::BundledLocales.lookup("en.errors.format")
  assert_equal "%{attribute}%{message}", Cybertrain::BundledLocales.lookup("ja.errors.format")
  assert_equal "is too short (minimum is %{count} character)", Cybertrain::BundledLocales.lookup("en.errors.messages.too_short.one")
  assert_equal "は%{count}文字以上で入力してください", Cybertrain::BundledLocales.lookup("ja.errors.messages.too_short")
  assert_equal "Validation failed: %{errors}", Cybertrain::BundledLocales.lookup("en.activerecord.errors.messages.record_invalid")
  assert_equal "about %{count} hours", Cybertrain::BundledLocales.lookup("en.datetime.distance_in_words.about_x_hours.other")
  assert_equal "約%{count}時間", Cybertrain::BundledLocales.lookup("ja.datetime.distance_in_words.about_x_hours")
  assert_equal "$", Cybertrain::BundledLocales.lookup("en.number.currency.format.unit")
  assert_equal "円", Cybertrain::BundledLocales.lookup("ja.number.currency.format.unit")
  assert_equal "0", Cybertrain::BundledLocales.lookup("ja.number.currency.format.precision")
  assert_equal "false", Cybertrain::BundledLocales.lookup("en.number.format.significant")
  assert_equal "", Cybertrain::BundledLocales.lookup("en.number.human.decimal_units.units.unit")
  assert_equal "Create %{model}", Cybertrain::BundledLocales.lookup("en.helpers.submit.create")
  assert_equal "更新する", Cybertrain::BundledLocales.lookup("ja.helpers.submit.update")
  assert_equal ", and ", Cybertrain::BundledLocales.lookup("en.support.array.last_word_connector")
  assert_equal "%Y/%m/%d", Cybertrain::BundledLocales.lookup("ja.date.formats.default")
  assert_equal "午後", Cybertrain::BundledLocales.lookup("ja.time.pm")
  assert_equal ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"], Cybertrain::BundledLocales.lookup_list("en.date.abbr_day_names")
  assert_equal "", Cybertrain::BundledLocales.lookup_list("ja.date.abbr_month_names")[0]
  assert_equal "12月", Cybertrain::BundledLocales.lookup_list("ja.date.abbr_month_names")[12]
  assert_equal [":year", ":month", ":day"], Cybertrain::BundledLocales.lookup_list("ja.date.order")
  assert_equal ["year", "month", "day"], Cybertrain::BundledLocales.lookup_list("en.date.order")
  # Only the trees the brief imports: rails-i18n's select prompt and
  # datetime.prompts / relative are left out.
  assert Cybertrain::BundledLocales.lookup("en.helpers.select.prompt").nil?
  assert Cybertrain::BundledLocales.lookup("ja.datetime.prompts.year").nil?
  assert Cybertrain::BundledLocales.lookup("en.datetime.relative.past").nil?
  assert_equal [], Cybertrain::BundledLocales.lookup_list("en.nope")
end

# script/bundle-locales on a copy of cybertrain/locales: --check passes on
# the checked-in files, and fails once en.yml changes.
test "script/bundle-locales --check exits 0 on a fresh tree and 1 after en.yml changes" do
  assert system("ruby", "script/bundle-locales", "--check")
  copy = "#{TMP}/bundle"
  Cybertrain::Gen::Runner.make_dirs("#{copy}/cybertrain/locales")
  ["en.yml", "ja.yml", "bundled.rb"].each { |f| File.write("#{copy}/cybertrain/locales/#{f}", File.read("cybertrain/locales/#{f}")) }
  out = "#{TMP}/bundle.out"
  check = "ruby script/bundle-locales --check \"$1\" > \"$2\""
  write = "ruby script/bundle-locales \"$1\" > \"$2\""
  assert system("sh", "-c", check, "sh", copy, out)
  assert_equal "", File.read(out)
  File.write("#{copy}/cybertrain/locales/en.yml", "#{File.read("#{copy}/cybertrain/locales/en.yml")}  zz_touched: x\n")
  refute system("sh", "-c", check, "sh", copy, out)
  assert_equal "stale: cybertrain/locales/bundled.rb\n", File.read(out)
  bundled = File.read("#{copy}/cybertrain/locales/bundled.rb")
  assert system("sh", "-c", write, "sh", copy, out)
  assert_equal "wrote cybertrain/locales/bundled.rb\n", File.read(out)
  refute bundled == File.read("#{copy}/cybertrain/locales/bundled.rb")
  assert_includes File.read("#{copy}/cybertrain/locales/bundled.rb"), "      h[\"en.zz_touched\"] = \"x\"\n"
  assert system("sh", "-c", check, "sh", copy, out)
end

Cybertrain::Test.run!
