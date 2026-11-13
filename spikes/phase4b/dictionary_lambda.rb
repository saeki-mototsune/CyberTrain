# Phase 4b spike, item 6d (D3): the dictionary handed to I18n as stored
# lambdas, and I18n.with_locale's yield / ensure. A record, not a test.
#
# - Gen::Locales (a `case`, as gen/locales.rb would write it) answers
#   `lookup(key)` -> String or nil and `lookup_list(key)` -> Array<String>;
#   `resolver` / `list_resolver` return `->(key) { Gen::Locales.lookup(key) }`
#   and its list twin, and the generated file's last line passes both
#   positionally to I18n.install_dictionary (rules 42 and 82). The same
#   program has gen/assets.rb's `Gen::Assets.resolver`, a lambda answering
#   a String, so `resolver` has two definers returning lambdas of two
#   types.
# - A second, framework-side pair (BundledLocales) is installed the same
#   way; I18n tries the application's lambda, then the bundled one, then
#   the default locale, each called with a local key (rule 97).
# - I18n.with_locale(l) { } saves the thread's locale, yields into a local
#   (rule 90), restores in `ensure` and returns the block's value; called
#   with a block answering a String, one answering an Integer, and one
#   whose only statement is `raise` (rule 79's shape), rescued by the
#   caller, after which the locale is the saved one.
#
# Run (Spinel 2026.11.04.7026, from spikes/phase4b/):
#   time spinel $(spin flags) dictionary_lambda.rb -o $TMPDIR/dictionary_lambda && $TMPDIR/dictionary_lambda > $TMPDIR/dl_spinel.txt
#   LANG=C.UTF-8 ruby dictionary_lambda.rb > $TMPDIR/dl_cruby.txt
#   diff $TMPDIR/dl_spinel.txt $TMPDIR/dl_cruby.txt && echo same
# Output (5.7 s to compile, a 559,968-byte binary; a 4-vCPU cloud machine;
# CRuby 3.3.6 prints the same, so the diff prints `same`):
#   before install: translation missing: en.posts.index.title
#   en posts.index.title: Posts
#   ja posts.index.title: 投稿 (6 bytes)
#   ja errors.messages.blank: を入力してください
#   ja greeting (from en): Hello Ann
#   ja nope: translation missing: ja.nope
#   resolver on an absent key: nil? true
#   resolver on a present key: 投稿 String
#   ja abbr_day_names: 日,月,火,水,木,金,土
#   en abbr_day_names (bundled): Sun,Mon,Tue,Wed,Thu,Fri,Sat
#   en nope list: 0
#   assets resolver: /assets/app-0123abcd.css
#   with_locale(:ja) String block: 投稿, after: :en
#   with_locale(:ja) Integer block: 2, after: :en
#   with_locale(:ja) raising block: rescued boom (inside ja), after: :en
#   with_locale(:ja) raise-only block: rescued only raise, after: :en
#   nested: en/fr/en, after: :ja
# Verdict: PASS. A stored lambda answers String or nil (nil is kept, so
# I18n::MISSING is not needed), two `resolver` methods returning lambdas of
# different types compile side by side, and with_locale's yield into a
# local with the restore in `ensure` compiles for String, Integer and
# raise-only blocks (rule 79 needs a `rescue` in the yielding method; this
# one has none) and restores the locale each time.
module I18n
  KEY = :cybertrain_i18n_locale

  # The lambdas before install_dictionary: no key is found. Returned by
  # methods, not module-body literals (rule 82).
  def self.no_texts = ->(key) { I18n.nothing(key) }
  def self.no_lists = ->(key) { I18n.no_items(key) }

  def self.nothing(key)
    return "" if key == "\u0000"

    nil
  end

  def self.no_items(key) = key.empty? ? [""] : []

  @app_texts = I18n.no_texts
  @app_lists = I18n.no_lists
  @bundled_texts = I18n.no_texts
  @bundled_lists = I18n.no_lists

  def self.install_dictionary(texts, lists)
    @app_texts = texts
    @app_lists = lists
    nil
  end

  def self.install_bundled(texts, lists)
    @bundled_texts = texts
    @bundled_lists = lists
    nil
  end

  def self.default_locale = :en

  def self.locale
    value = Thread.current[KEY]
    value.nil? ? I18n.default_locale : value
  end

  def self.locale=(value)
    Thread.current[KEY] = value
  end

  # The text of key in the locale, or nil: the application's dictionary,
  # then the bundled one.
  def self.text_in(locale, key)
    full = "#{locale}.#{key}"
    found = @app_texts.call(full)
    return found unless found.nil?

    @bundled_texts.call(full)
  end

  # I18n.t without options: the locale, then the default locale, then
  # "translation missing: ...".
  def self.t(key)
    k = key.to_s
    found = I18n.text_in(I18n.locale, k)
    found = I18n.text_in(I18n.default_locale, k) if found.nil?
    return found unless found.nil?

    message = "translation missing: #{I18n.locale}.#{k}"
    message
  end

  def self.translate_list(key)
    full = "#{I18n.locale}.#{key}"
    items = @app_lists.call(full)
    return items unless items.empty?

    @bundled_lists.call(full)
  end

  def self.with_locale(value)
    saved = Thread.current[KEY]
    I18n.locale = value
    begin
      result = yield
    ensure
      Thread.current[KEY] = saved
    end
    result
  end
end

module Gen
  module Locales
    def self.lookup(key)
      case key
      when "en.posts.index.title" then "Posts"
      when "ja.posts.index.title" then "投稿"
      when "en.greeting" then "Hello %{name}"
      end
    end

    def self.lookup_list(key)
      case key
      when "ja.date.abbr_day_names" then ["日", "月", "火", "水", "木", "金", "土"]
      else []
      end
    end

    def self.resolver = ->(key) { Gen::Locales.lookup(key) }
    def self.list_resolver = ->(key) { Gen::Locales.lookup_list(key) }
  end

  # gen/assets.rb's resolver, as assets_emitter.rb writes it.
  module Assets
    def self.digest_path(name) = "/assets/#{name.sub(".css", "-0123abcd.css")}"
    def self.resolver = ->(name) { digest_path(name) }
  end
end

module Cybertrain
  module BundledLocales
    def self.lookup(key)
      case key
      when "en.errors.messages.blank" then "can't be blank"
      when "ja.errors.messages.blank" then "を入力してください"
      when "en.posts.index.title" then "(bundled, shadowed)"
      end
    end

    def self.lookup_list(key)
      case key
      when "en.date.abbr_day_names" then %w[Sun Mon Tue Wed Thu Fri Sat]
      else []
      end
    end

    def self.resolver = ->(key) { Cybertrain::BundledLocales.lookup(key) }
    def self.list_resolver = ->(key) { Cybertrain::BundledLocales.lookup_list(key) }
  end
end

puts "before install: #{I18n.t("posts.index.title")}"
I18n.install_bundled(Cybertrain::BundledLocales.resolver, Cybertrain::BundledLocales.list_resolver)
# The generated file's last line.
I18n.install_dictionary(Gen::Locales.resolver, Gen::Locales.list_resolver)

key = "posts.index.title"
puts "en #{key}: #{I18n.t(key)}"
I18n.locale = :ja
puts "ja #{key}: #{I18n.t(key)} (#{I18n.t(key).bytesize} bytes)"
puts "ja errors.messages.blank: #{I18n.t("errors.messages.blank")}"
puts "ja greeting (from en): #{I18n.t("greeting").sub("%{name}", "Ann")}"
puts "ja nope: #{I18n.t("nope")}"
direct = Gen::Locales.resolver.call("ja.nope")
puts "resolver on an absent key: nil? #{direct.nil?}"
present = Gen::Locales.resolver.call("ja.posts.index.title")
puts "resolver on a present key: #{present.nil? ? "nil" : present.upcase} #{present.class}"
puts "ja abbr_day_names: #{I18n.translate_list("date.abbr_day_names").join(",")}"
I18n.locale = :en
puts "en abbr_day_names (bundled): #{I18n.translate_list("date.abbr_day_names").join(",")}"
puts "en nope list: #{I18n.translate_list("nope").size}"
puts "assets resolver: #{Gen::Assets.resolver.call("app.css")}"

inside = I18n.with_locale(:ja) { I18n.t(key) }
puts "with_locale(:ja) String block: #{inside}, after: #{I18n.locale.inspect}"
count = I18n.with_locale(:ja) { I18n.t(key).size }
puts "with_locale(:ja) Integer block: #{count}, after: #{I18n.locale.inspect}"
seen = ""
begin
  I18n.with_locale(:ja) do
    seen = I18n.locale.to_s
    raise ArgumentError, "boom"
  end
rescue ArgumentError => e
  puts "with_locale(:ja) raising block: rescued #{e.message} (inside #{seen}), after: #{I18n.locale.inspect}"
end
begin
  I18n.with_locale(:ja) { raise ArgumentError, "only raise" }
rescue ArgumentError => e
  puts "with_locale(:ja) raise-only block: rescued #{e.message}, after: #{I18n.locale.inspect}"
end
I18n.locale = :ja
nested = I18n.with_locale(:en) { "#{I18n.locale}/#{I18n.with_locale(:fr) { I18n.locale.to_s }}/#{I18n.locale}" }
puts "nested: #{nested}, after: #{I18n.locale.inspect}"
