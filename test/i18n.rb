require "cybertrain/test"
require "cybertrain/i18n"
require "cybertrain/generator/locale_yaml"
require_relative "support/zone_swap"

# I18n (plan decisions D2 and D5-D7, Task 4): t with interpolation,
# defaults, count: plurals and the fallback to the default locale, the
# missing-key modes, the plural rules, and the thread-local locale. Runs
# under CRuby (`ruby -I. test/i18n.rb`) and compiled (`spin test
# test/i18n.rb`): the application dictionary is the hand-written pair of
# lookups below, installed as gen/locales.rb installs Gen::Locales; the
# bundled dictionary is cybertrain/locales/bundled.rb.
module TestLocales
  def self.lookup(key)
    case key
    when "en.greeting" then "Hello, %{name}"
    when "ja.greeting" then "こんにちは、%{name}"
    when "en.only_en" then "Only English"
    when "en.literal" then "100%%{x}"
    when "en.two_vars" then "%{a} and %{b}, 50%% off"
    when "en.inbox.zero" then "No messages"
    when "en.inbox.one" then "One message"
    when "en.inbox.other" then "%{count} messages"
    when "en.items.one" then "%{count} item"
    when "en.items.other" then "%{count} items"
    when "ja.items.other" then "%{count}個"
    when "ru.apples.one" then "%{count} яблоко"
    when "ru.apples.few" then "%{count} яблока"
    when "ru.apples.many" then "%{count} яблок"
    when "fr.lines.one" then "%{count} ligne"
    when "fr.lines.other" then "%{count} lignes"
    when "en.hello" then "Hello"
    when "ja.hello" then "こんにちは"
    when "en.errors.messages.blank" then "Overridden"
    # A plural mapping where the bundled ja dictionary holds a scalar, and
    # a scalar where the bundled en dictionary holds a plural mapping.
    when "ja.errors.template.header.other" then "%{model}: %{count}件のエラー"
    when "en.datetime.distance_in_words.x_minutes" then "%{count} minute(s)"
    # Only the zero form of a bundled one/other key, and only the one form of
    # bundled about_x_months.
    when "en.datetime.distance_in_words.x_days.zero" then "today"
    when "en.datetime.distance_in_words.about_x_months.one" then "about a month"
    when "en.odd_marks" then "%{a b}, %{}, %{x-y}, 5% and %{"
    end
  end

  def self.lookup_list(key)
    case key
    when "en.colors" then ["red", "green"]
    when "ja.date.abbr_month_names" then ["", "一月", "二月"]
    else []
    end
  end

  def self.resolver = ->(key) { TestLocales.lookup(key) }
  def self.list_resolver = ->(key) { TestLocales.lookup_list(key) }
end

I18n.install_dictionary(TestLocales.resolver, TestLocales.list_resolver)

# The state each test starts from: English default, en/ja/fr/ru available,
# the development missing-key mode, and :en on this thread.
def reset_i18n
  I18n.default_locale = :en
  I18n.available_locales = [:en, :ja, :fr, :ru]
  I18n.raise_on_missing = false
  I18n.mark_missing = true
  I18n.locale = :en
  nil
end

# One request's worth on its own thread: set the locale, wait until the
# other thread has set its own and rendered, then render.
module LocaleThreads
  def self.request_a(ready, go, out)
    I18n.locale = :ja
    ready.push("a set ja")
    go.pop
    text = "a: #{I18n.locale} #{I18n.t("hello")}"
    out.push(text)
    nil
  end

  def self.request_b(ready, go, out)
    ready.pop
    I18n.locale = :en
    text = "b: #{I18n.locale} #{I18n.t("hello")}"
    out.push(text)
    go.push("b done")
    nil
  end

  def self.start_a(ready, go, out) = Thread.new { LocaleThreads.request_a(ready, go, out) }
  def self.start_b(ready, go, out) = Thread.new { LocaleThreads.request_b(ready, go, out) }
end

test "t with interpolation, default and fallback to the default locale" do
  reset_i18n
  I18n.locale = :ja
  assert_equal "こんにちは、Ann", I18n.t("greeting", name: "Ann")
  assert_equal "Only English", I18n.t("only_en")
  assert_equal "fallback", I18n.t("nope", default: "fallback")
  assert_equal "Only English", I18n.t("nope", default: :only_en)
  assert_equal "Hello, Bo", I18n.t("greeting", name: "Bo", locale: :en)
  assert_equal "Hello, Cy", I18n.translate("greeting", name: "Cy", locale: "en")
  assert_equal "こんにちは", I18n.t(:hello)
  # A String default is interpolated too; a Symbol default that is itself
  # missing reports the key asked for.
  assert_equal "Hi Di", I18n.t("nope", default: "Hi %{name}", name: "Di")
  assert_equal "translation missing: ja.nope", I18n.t("nope", default: :also_nope)
  assert_raises("I18n::InvalidLocale") { I18n.t("hello", locale: :xx) }
  assert_equal :ja, I18n.locale
end

test "interpolation, %%, count zero and a missing argument" do
  reset_i18n
  assert_equal "100%{x}", I18n.t("literal")
  assert_equal "100%{x}", I18n.t("literal", x: "ignored")
  assert_equal "1 and 2, 50% off", I18n.t("two_vars", a: 1, b: "2")
  assert_equal "No messages", I18n.t("inbox", count: 0)
  assert_equal "One message", I18n.t("inbox", count: 1)
  assert_equal "7 messages", I18n.t("inbox", count: 7)
  assert_equal "0 items", I18n.t("items", count: 0)
  assert_equal "1 item", I18n.t("items", count: 1)
  assert_equal "2 items", I18n.t("items", count: 2)
  message = assert_raises("I18n::MissingInterpolationArgument") { I18n.t("greeting") }
  assert_equal "missing interpolation argument :name in \"Hello, %{name}\"", message
  message = assert_raises("ArgumentError") { I18n.t("items", count: "2") }
  assert_equal "count: must be an Integer (got String)", message
  # ja has only `other`; ru and fr pick their own categories.
  assert_equal "1個", I18n.t("items", count: 1, locale: :ja)
  assert_equal ["21 яблоко", "3 яблока", "11 яблок"], [21, 3, 11].map { |n| I18n.t("apples", count: n, locale: :ru) }
  assert_equal ["0 ligne", "2 lignes"], [0, 2].map { |n| I18n.t("lines", count: n, locale: :fr) }
  # count_text: interpolates %{count} without choosing a plural form.
  assert_equal "1.5 messages", I18n.t("inbox.other", count_text: "1.5")
  # A count on a scalar entry only interpolates.
  assert_equal "Only English", I18n.t("only_en", count: 3)
end

test "plural rules for en, fr, ru, ja and zh" do
  reset_i18n
  assert_equal [:one, :other], [1, 2].map { |n| I18n.plural_category(:en, n) }
  assert_equal [:other, :other], [0, 21].map { |n| I18n.plural_category(:en, n) }
  assert_equal [:one, :one, :other, :many], [0, 1, 2, 1_000_000].map { |n| I18n.plural_category(:fr, n) }
  assert_equal [:many, :other], [3_000_000, 1_500_000].map { |n| I18n.plural_category(:fr, n) }
  assert_equal [:one, :few, :many, :many, :one, :few, :many], [1, 2, 5, 11, 21, 22, 112].map { |n| I18n.plural_category(:ru, n) }
  assert_equal [:many, :many, :few, :many], [0, 12, 104, 114].map { |n| I18n.plural_category(:ru, n) }
  assert_equal [:other, :other], [I18n.plural_category(:ja, 1), I18n.plural_category(:zh, 1)]
  assert_equal :other, I18n.plural_category(:"zh-TW", 1)
  assert_equal :one, I18n.plural_category(:"pt-BR", 1)
  assert_equal :other, I18n.plural_category(:"pt-BR", 2)
  assert_equal :many, I18n.plural_category(:"ru-RU", 5)
  assert_equal :one, I18n.plural_category(:xx, 1)
end

test "missing keys: development text, production humanised, raise" do
  reset_i18n
  assert_equal "translation missing: en.posts.no_such_key", I18n.t("posts.no_such_key")
  I18n.locale = :ja
  assert_equal "translation missing: ja.posts.no_such_key", I18n.t("posts.no_such_key")
  I18n.locale = :en
  I18n.mark_missing = false
  assert_equal "No such key", I18n.t("posts.no_such_key")
  assert_equal "Nope", I18n.t("nope")
  I18n.raise_on_missing = true
  message = assert_raises("I18n::MissingTranslationData") { I18n.t("posts.no_such_key") }
  assert_equal "translation missing: en.posts.no_such_key", message
  # A default still answers before the missing-key mode applies.
  assert_equal "kept", I18n.t("posts.no_such_key", default: "kept")
  assert_equal "Bar baz", I18n.humanize_key("bar_baz")
  assert_equal "Title", I18n.humanize_key("TITLE")
  assert_equal "", I18n.humanize_key("")
  assert_equal "translation missing: ja.foo.bar", I18n.missing_text("ja.foo.bar")
end

test "with_locale restores the locale on raise and answers the block's value" do
  reset_i18n
  assert_equal "こんにちは", I18n.with_locale(:ja) { I18n.t("hello") }
  assert_equal :en, I18n.locale
  inside = ""
  begin
    I18n.with_locale(:ja) do
      inside = I18n.locale.to_s
      raise ArgumentError, "x"
    end
  rescue ArgumentError => e
    inside = "#{inside} #{e.message}"
  end
  assert_equal "ja x", inside
  assert_equal :en, I18n.locale
  I18n.locale = :ja
  nested = I18n.with_locale(:en) { "#{I18n.locale}/#{I18n.with_locale(:fr) { I18n.locale.to_s }}/#{I18n.locale}" }
  assert_equal "en/fr/en", nested
  assert_equal :ja, I18n.locale
  assert_raises("I18n::InvalidLocale") { I18n.with_locale(:xx) { "never" } }
  assert_equal :ja, I18n.locale
end

test "overlapping requests on two threads keep their own locales" do
  reset_i18n
  ready = Queue.new
  go = Queue.new
  out = Queue.new
  a = LocaleThreads.start_a(ready, go, out)
  b = LocaleThreads.start_b(ready, go, out)
  a.join
  b.join
  # B rendered while A held :ja, then A rendered after B set :en.
  assert_equal "b: en Hello", out.pop
  assert_equal "a: ja こんにちは", out.pop
  assert_equal :en, I18n.locale
  I18n.locale = :ja
  c = Thread.new { I18n.locale.to_s }
  # A new thread starts at the default locale, whatever this one holds.
  assert_equal "en", c.value
  assert_equal :ja, I18n.locale
end

test "locale= accepts names of available locales only" do
  reset_i18n
  I18n.locale = "ja"
  assert_equal :ja, I18n.locale
  I18n.locale = :fr
  assert_equal :fr, I18n.locale
  message = assert_raises("I18n::InvalidLocale") { I18n.locale = "xx" }
  assert_equal "\"xx\" is not an available locale", message
  assert_raises("I18n::InvalidLocale") { I18n.locale = "JA" }
  assert_raises("I18n::InvalidLocale") { I18n.locale = :zh }
  assert_equal :fr, I18n.locale
  assert_equal false, I18n.locale_available?("../en")
  assert_equal false, I18n.locale_available?("JA")
  assert_equal false, I18n.locale_available?("xx")
  assert_equal false, I18n.locale_available?("")
  assert_equal true, I18n.locale_available?("ja")
  assert_equal true, I18n.locale_available?(:ru)
  assert_equal [:en, :ja, :fr, :ru], I18n.available_locales
  # nil puts the thread back on the default locale.
  I18n.locale = nil
  assert_equal :en, I18n.locale
  I18n.default_locale = :ja
  assert_equal :ja, I18n.locale
  assert_equal :ja, I18n.default_locale
  I18n.available_locales = []
  assert_equal [:ja], I18n.available_locales
  # locale= accepts exactly what locale_available? accepts: a default
  # locale missing from the list is refused, as in Rails.
  I18n.default_locale = :en
  I18n.available_locales = [:ja]
  assert_equal false, I18n.locale_available?(:en)
  message = assert_raises("I18n::InvalidLocale") { I18n.locale = :en }
  assert_equal "\"en\" is not an available locale", message
  I18n.locale = nil
  assert_equal :en, I18n.locale
end

test "translate_list reads arrays; the application overrides the bundled dictionary" do
  reset_i18n
  assert_equal "Sun", I18n.translate_list("date.abbr_day_names")[0]
  assert_equal 7, I18n.translate_list("date.abbr_day_names").size
  assert_equal "Overridden", I18n.t("errors.messages.blank")
  assert_equal "を入力してください", I18n.t("errors.messages.blank", locale: :ja)
  assert_equal ["red", "green"], I18n.translate_list("colors")
  assert_equal ["red", "green"], I18n.translate_list("colors", locale: :ja)
  assert_equal ["", "一月", "二月"], I18n.translate_list("date.abbr_month_names", locale: :ja)
  assert_equal "日", I18n.translate_list("date.abbr_day_names", locale: :ja)[0]
  assert_equal [], I18n.translate_list("nope")
end

test "a plural mapping and a scalar at one key: the application's shape wins" do
  reset_i18n
  # Bundled ja holds errors.template.header as a scalar; the application a
  # mapping with `other`: the application's form answers.
  assert_equal "投稿: 2件のエラー", I18n.t("errors.template.header", count: 2, model: "投稿", locale: :ja)
  # Without count: a mapping is no text, and the application's mapping
  # hides the bundled scalar: the key falls back to en, where it is a
  # bundled mapping again, so it is missing.
  assert_equal "translation missing: ja.errors.template.header", I18n.t("errors.template.header", model: "x", locale: :ja)
  # Bundled en holds x_minutes as a one/other mapping; the application a
  # scalar, which answers for every count.
  assert_equal "1 minute(s)", I18n.t("datetime.distance_in_words.x_minutes", count: 1)
  assert_equal "5 minute(s)", I18n.t("datetime.distance_in_words.x_minutes", count: 5)
  # The bundled forms answer where the application has nothing.
  assert_equal "about 1 hour", I18n.t("datetime.distance_in_words.about_x_hours", count: 1)
  assert_equal "about 3 hours", I18n.t("datetime.distance_in_words.about_x_hours", count: 3)
  assert_equal "1 error prohibited this post from being saved", I18n.t("errors.template.header", count: 1, model: "post")
end

test "an application form beside a bundled plural mapping merges with the bundled forms" do
  reset_i18n
  # The application adds only x_days.zero; bundled en holds one/other.
  assert_equal "today", I18n.t("datetime.distance_in_words.x_days", count: 0)
  assert_equal "1 day", I18n.t("datetime.distance_in_words.x_days", count: 1)
  assert_equal "5 days", I18n.t("datetime.distance_in_words.x_days", count: 5)
  # The application overrides only about_x_months.one; other stays bundled.
  assert_equal "about a month", I18n.t("datetime.distance_in_words.about_x_months", count: 1)
  assert_equal "about 4 months", I18n.t("datetime.distance_in_words.about_x_months", count: 4)
  # ja is untouched: bundled ja's scalar answers.
  assert_equal "5日", I18n.t("datetime.distance_in_words.x_days", count: 5, locale: :ja)
end

test "interpolation names are \\w+; anything else stays literal" do
  reset_i18n
  assert_equal "%{a b}, %{}, %{x-y}, 5% and %{", I18n.t("odd_marks")
  assert_equal "%{a b}, %{}, %{x-y}, 5% and %{", I18n.t("odd_marks", "a b": "z", "x-y": "w")
  assert_equal "ok_1 then 9", I18n.t("nope", default: "%{ok_1} then %{N9}", ok_1: "ok_1", N9: 9)
end

# Tuesday, 2026-11-10, 09:05 UTC (the morning) and 15:30:07 (the afternoon).
L_MORNING = Time.utc(2026, 11, 10, 9, 5)
L_AFTERNOON = Time.utc(2026, 11, 10, 15, 30, 7)
L_DAY = Date.new(2026, 11, 10)

test "l with :default, :short, :long and a pattern in en and ja" do
  reset_i18n
  # en: time.formats default "%a, %d %b %Y %H:%M:%S %z", short "%d %b %H:%M",
  # long "%B %d, %Y %H:%M"; date.formats "%Y-%m-%d", "%b %d", "%B %d, %Y".
  assert_equal "Tue, 10 Nov 2026 09:05:00 +0000", I18n.l(L_MORNING)
  assert_equal "Tue, 10 Nov 2026 09:05:00 +0000", I18n.l(L_MORNING, format: :default)
  assert_equal "10 Nov 09:05", I18n.l(L_MORNING, format: :short)
  assert_equal "November 10, 2026 09:05", I18n.l(L_MORNING, format: :long)
  assert_equal "2026-11-10", I18n.l(L_DAY)
  assert_equal "Nov 10", I18n.l(L_DAY, format: :short)
  assert_equal "November 10, 2026", I18n.l(L_DAY, format: :long)
  # ja (rails-i18n's ja.yml): time.formats default
  # "%Y年%m月%d日(%a) %H時%M分%S秒 %z", short "%m/%d %H:%M", long
  # "%Y/%m/%d %H:%M"; date.formats "%Y/%m/%d", "%m/%d", "%Y年%m月%d日(%a)";
  # each directive expanded by hand (%a of a Tuesday is 火).
  assert_equal "2026/11/10 09:05", I18n.l(L_MORNING, format: :long, locale: :ja)
  assert_equal "11/10 09:05", I18n.l(L_MORNING, format: :short, locale: :ja)
  assert_equal "2026年11月10日(火) 09時05分00秒 +0000", I18n.l(L_MORNING, locale: :ja)
  assert_equal "2026/11/10", I18n.l(L_DAY, locale: "ja")
  assert_equal "11/10", I18n.l(L_DAY, format: :short, locale: :ja)
  assert_equal "2026年11月10日(火)", I18n.l(L_DAY, format: :long, locale: :ja)
  # The thread's locale answers when there is no locale:.
  I18n.locale = :ja
  assert_equal "2026/11/10", I18n.l(L_DAY)
  assert_equal "2026/11/10 09:05", I18n.localize(L_MORNING, format: :long)
  # A pattern: the names are the dictionary's; %p upper-cased and %P
  # lower-cased as the i18n gem does (ja's 午前 / 午後 have no case).
  assert_equal "火 午前", I18n.l(L_MORNING, format: "%a %p")
  assert_equal "火曜日 午後 午後", I18n.l(L_AFTERNOON, format: "%A %p %P")
  I18n.locale = :en
  assert_equal "Tue Tuesday Nov November AM am", I18n.l(L_MORNING, format: "%a %A %b %B %p %P")
  assert_equal "PM pm 3:30:07", I18n.l(L_AFTERNOON, format: "%p %P %-I:%M:%S")
  # %^ upper-cases a name; %% stays a literal; the other directives are
  # strftime's (%y %e %z %-d %-m among them).
  assert_equal "TUE NOVEMBER %a %% 26 10 +0000 10 11", I18n.l(L_MORNING, format: "%^a %^B %%a %%%% %y %e %z %-d %-m")
  assert_equal "Tuesday, November 10", I18n.l(L_DAY, format: "%A, %B %-d")
  # A Date has no hour: %p and %P are empty, as in the i18n gem.
  assert_equal "[][]", I18n.l(L_DAY, format: "[%p][%P]")
  # The application's list answers before the bundled one (TestLocales:
  # ja.date.abbr_month_names is ["", "一月", "二月"]); an index past the
  # end of that list leaves the directive to strftime.
  assert_equal "一月 2日", I18n.l(Date.new(2026, 1, 2), format: "%b %-d日", locale: :ja)
  assert_equal "Nov", I18n.l(L_DAY, format: "%b", locale: :ja)
end

test "l refuses what it cannot format" do
  reset_i18n
  msg = assert_raises("ArgumentError") { I18n.l(5) }
  assert_equal "l: expected a Time or a Date (got Integer)", msg
  msg = assert_raises("ArgumentError") { I18n.l("2026-11-10") }
  assert_equal "l: expected a Time or a Date (got String)", msg
  msg = assert_raises("I18n::MissingTranslationData") { I18n.l(L_MORNING, format: :nope) }
  assert_equal "translation missing: en.time.formats.nope", msg
  msg = assert_raises("I18n::MissingTranslationData") { I18n.l(L_DAY, format: :nope, locale: :ja) }
  assert_equal "translation missing: ja.date.formats.nope", msg
  msg = assert_raises("ArgumentError") { I18n.l(L_MORNING, format: "%Y %Q") }
  assert_equal "l format: unknown directive %Q in \"%Y %Q\"", msg
  msg = assert_raises("ArgumentError") { I18n.l(L_MORNING, format: 3) }
  assert_equal "l: format: must be a Symbol or a String (got Integer)", msg
  msg = assert_raises("I18n::InvalidLocale") { I18n.l(L_DAY, locale: :xx) }
  assert_equal "\"xx\" is not an available locale", msg
end

test "l renders a Time in Time.zone, or once in zone:; a Date as it is" do
  reset_i18n
  t = Time.utc(2026, 11, 11, 20)
  ZoneSwap.during("Asia/Tokyo") do
    assert_equal "05:00 JST", I18n.l(t, format: "%H:%M %Z")
    assert_equal "15:00", I18n.l(t, format: "%H:%M", zone: "America/New_York")
    assert_equal "2026-11-11", I18n.l(Date.new(2026, 11, 11))
    assert_equal "2026-11-11", I18n.l(Date.new(2026, 11, 11), zone: "America/New_York")
    # The day and month names and %p are the zone's wall clock's: Thursday
    # morning in Tokyo, Wednesday afternoon in New York.
    assert_equal "Thu, 12 Nov 2026 05:00:00 +0900", I18n.l(t)
    assert_equal "Thursday AM +09:00 1794427200", I18n.l(t, format: "%A %p %:z %s")
    assert_equal "2026年11月12日(木) 05時00分00秒 +0900", I18n.l(t, locale: :ja)
    assert_equal "Wednesday PM -0500 EST", I18n.l(t, format: "%A %p %z %Z", zone: "America/New_York")
    # A Time that carries an offset of its own keeps it, unless zone: is given.
    k = t.getlocal("-05:30")
    assert_equal "14:30 -0530", I18n.l(k, format: "%H:%M %z")
    assert_equal "05:00 +0900 JST", I18n.l(k, format: "%H:%M %z %Z", zone: "Asia/Tokyo")
  end
  # Back in UTC every format is as before.
  assert_equal "Wed, 11 Nov 2026 20:00:00 +0000", I18n.l(t)
  assert_equal "20:00 UTC", I18n.l(t, format: "%H:%M %Z")
  assert_equal "05:00 JST", I18n.l(t, format: "%H:%M %Z", zone: "Asia/Tokyo")
  msg = assert_raises("ArgumentError") { I18n.l(t, zone: "Mars/Base") }
  assert_equal "unknown time zone \"Mars/Base\"", msg
end

test "every bundled date and time format formats in every bundled locale" do
  reset_i18n
  seen = Array.new(0) { "" }
  ["en", "ja"].each do |loc|
    path = "cybertrain/locales/#{loc}.yml"
    Cybertrain::Gen::LocaleYaml.parse(File.read(path), path).each do |entry|
      key = entry.entry_key
      date = key.start_with?("#{loc}.date.formats.")
      next unless date || key.start_with?("#{loc}.time.formats.")

      dot = key.rindex(".").to_i
      name = key[dot + 1, key.size - dot - 1].to_s
      text = date ? I18n.l(L_DAY, format: name.to_sym, locale: loc) : I18n.l(L_AFTERNOON, format: name.to_sym, locale: loc)
      # Every directive was expanded: no "%" is left, and the day is there.
      assert !text.include?("%"), "#{key} left a directive: #{text}"
      assert text.include?("10"), "#{key} gave #{text}"
      seen << key
    end
  end
  assert_equal "en.date.formats.default en.date.formats.long en.date.formats.short en.time.formats.default " \
               "en.time.formats.long en.time.formats.short ja.date.formats.default ja.date.formats.long " \
               "ja.date.formats.short ja.time.formats.default ja.time.formats.long ja.time.formats.short",
               seen.sort.join(" ")
end

Cybertrain::Test.run!
