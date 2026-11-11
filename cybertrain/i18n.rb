require "date"
require "cybertrain/locales/bundled"
require "cybertrain/strftime"

# I18n, a top-level module as in Rails (plan decision D1), so application
# code writes `I18n.t` and `I18n.locale` as there.
#
# Two dictionaries answer: the application's (`config/locales/**/*.yml`,
# compiled by `spin run gen` into gen/locales.rb, which installs it with
# {I18n.install_dictionary} when it loads) and the framework's bundled one
# (cybertrain/locales/en.yml and ja.yml, rails-i18n's keys, compiled into
# cybertrain/locales/bundled.rb). A key is looked up in the current locale,
# the application's dictionary first, then in the default locale the same
# way (D2): an application's key overrides the bundled one.
#
# The current locale belongs to the thread (`Thread.current`, under
# {LOCALE_KEY}), so connections served at the same time keep their own;
# every controller action starts at the default locale (D5-D7, R4).
#
# @example
#   # config/locales/ja.yml:  ja: { greeting: "こんにちは、%{name}" }
#   I18n.locale = :ja
#   I18n.t("greeting", name: "Ann")             # => "こんにちは、Ann"
#   I18n.t("errors.messages.blank")             # => "を入力してください" (bundled)
#   I18n.with_locale(:en) { I18n.t("errors.messages.blank") }  # => "can't be blank"
# @api public
module I18n
  # The `Thread.current` key holding the thread's locale (a Symbol); nil
  # there means {I18n.default_locale}.
  # @api public
  LOCALE_KEY = :cybertrain_i18n_locale

  # The plural sub-keys a counted entry may have (CLDR's categories).
  # @api private
  PLURAL_KEYS = %w[zero one two few many other].freeze

  # Raised by {I18n.t} for a key no dictionary holds, when
  # {I18n.raise_on_missing=} is on (the `i18n_raise_on_missing` setting).
  # @api public
  class MissingTranslationData < ::ArgumentError
  end

  # Raised for a locale name that is not one of {I18n.available_locales}.
  # @api public
  class InvalidLocale < ::ArgumentError
  end

  # Raised by {I18n.t} when the text has a `%{name}` the call gave no value
  # for.
  # @api public
  class MissingInterpolationArgument < ::ArgumentError
  end

  # The dictionary before install_dictionary: no key is found. Built by
  # methods, never a lambda literal in the module body (spikes/NOTES.md
  # rule 82).
  # @api private
  def self.no_texts = ->(key) { I18n.no_text(key) }

  # @api private
  def self.no_lists = ->(key) { I18n.no_list(key) }

  # nil for every key; the unreachable branch types the result String or
  # nil, as a generated lookup's is.
  # @api private
  def self.no_text(key)
    return "" if key == "\u0000"

    nil
  end

  # An empty list for every key; the unreachable branch types it.
  # @api private
  def self.no_list(key) = key == "\u0000" ? [""] : []

  @app_texts = I18n.no_texts
  @app_lists = I18n.no_lists
  @default_locale = :en
  @available_locales = [:en]
  @raise_on_missing = false
  @mark_missing = true

  # Installs the application's dictionary. gen/locales.rb's last line calls
  # it with `Gen::Locales.resolver` and `Gen::Locales.list_resolver`;
  # the bundled dictionary needs no installing (I18n reads
  # Cybertrain::BundledLocales directly). Called once, at load, before any
  # request.
  # @param texts [Proc] answers the String at a full key
  #   (`"ja.posts.index.title"`), or nil when there is none
  # @param lists [Proc] answers the Array<String> at a full key, empty
  #   when there is none
  # @return [nil]
  # @api public
  def self.install_dictionary(texts, lists)
    @app_texts = texts
    @app_lists = lists
    nil
  end

  # The locale every thread starts at, and the one a key falls back to
  # (`config.i18n_default_locale`, set at boot).
  # @return [Symbol]
  # @api public
  def self.default_locale = @default_locale

  # @param value [Symbol]
  # @return [Symbol]
  # @api public
  def self.default_locale=(value)
    @default_locale = value
  end

  # The locales `I18n.locale=` accepts (`config.i18n_available_locales`,
  # set at boot); just the default locale until set.
  # @return [Array<Symbol>]
  # @api public
  def self.available_locales
    list = @available_locales
    return [@default_locale] if list.empty?

    list
  end

  # @param list [Array<Symbol>] empty means the default locale alone
  # @return [Array<Symbol>]
  # @api public
  def self.available_locales=(list)
    @available_locales = list
  end

  # Whether {I18n.t} raises {MissingTranslationData} for a missing key
  # (the `i18n_raise_on_missing` setting, set at boot).
  # @param value [Boolean]
  # @return [Boolean]
  # @api public
  def self.raise_on_missing=(value)
    @raise_on_missing = value
  end

  # Whether a missing key answers `"translation missing: ja.foo.bar"`
  # (development and test, the default) or the humanised last segment,
  # `"Bar"` (production; boot sets it to `!production?`).
  # @param value [Boolean]
  # @return [Boolean]
  # @api public
  def self.mark_missing=(value)
    @mark_missing = value
  end

  # The thread's locale: the one `I18n.locale=` set on this thread, or the
  # default locale. A controller action starts at the default locale.
  # @return [Symbol]
  # @api public
  def self.locale
    value = Thread.current[LOCALE_KEY]
    value.nil? ? I18n.default_locale : value
  end

  # Sets this thread's locale. The value is compared with the names of
  # {I18n.available_locales} and never turned into
  # a Symbol itself, so a request parameter can be passed as is; nil goes
  # back to the default locale.
  # @example
  #   I18n.locale = params[:locale] if I18n.locale_available?(params[:locale])
  # @param value [Symbol, String, nil]
  # @return [nil]
  # @raise [InvalidLocale] `"\"xx\" is not an available locale"`
  # @api public
  def self.locale=(value)
    if value.nil?
      Thread.current[LOCALE_KEY] = nil
    else
      Thread.current[LOCALE_KEY] = I18n.resolve_locale(value)
    end
    nil
  end

  # Whether value names one of {I18n.available_locales}, exactly (`"ja"`
  # or `:ja`; `"JA"` and `"ja-JP"` do not).
  # @param value [Symbol, String, nil]
  # @return [Boolean]
  # @api public
  def self.locale_available?(value)
    return false if value.nil?

    name = value.to_s
    I18n.available_locales.each { |l| return true if l.to_s == name }
    false
  end

  # The available locale named value: exactly what locale_available?
  # accepts, as in Rails (the default locale must be in the list too).
  # @api private
  def self.resolve_locale(value)
    name = value.to_s
    I18n.available_locales.each { |l| return l if l.to_s == name }
    message = "\"#{name}\" is not an available locale"
    raise InvalidLocale, message
  end

  # Runs the block with this thread's locale set to value, then puts the
  # previous one back, also when the block raises.
  # @example
  #   I18n.with_locale(:ja) { I18n.t("posts.index.title") }   # => "投稿"
  # @param value [Symbol, String]
  # @return [String] the block's value
  # @raise [InvalidLocale] before the block runs
  # @api public
  def self.with_locale(value)
    saved = Thread.current[LOCALE_KEY]
    I18n.locale = value
    begin
      result = yield
    ensure
      Thread.current[LOCALE_KEY] = saved
    end
    result
  end

  # The text at key (`"posts.index.title"`): the current locale's,
  # application dictionary first, then the default locale's.
  #
  # Options: `default:` (a String, or a Symbol naming another key) answers
  # when no dictionary holds the key; `count:` (an Integer) picks the
  # plural form under the key (`zero` for 0 when present, then the
  # locale's category, then `other`; see {I18n.plural_category}) and fills
  # `%{count}`; `count_text:` (a String) fills `%{count}` without picking
  # a form; `locale:` looks up in another locale. Every other option fills
  # the `%{name}` of its name; `%%` is a literal `%`, so `%%{x}` gives
  # `%{x}`.
  #
  # A missing key answers `"translation missing: ja.foo.bar"`, or `"Bar"`
  # after `I18n.mark_missing = false`, or raises after
  # `I18n.raise_on_missing = true`.
  # @example
  #   I18n.t("greeting", name: "Ann")                  # "Hello, %{name}" => "Hello, Ann"
  #   I18n.t("errors.template.header", count: 2, model: "post")
  #   # => "2 errors prohibited this post from being saved"
  #   I18n.t("nope", default: "Nothing")              # => "Nothing"
  # @param key [String, Symbol]
  # @param options [Hash{Symbol => Object}]
  # @return [String]
  # @raise [ArgumentError] `"count: must be an Integer (got String)"`
  # @raise [MissingInterpolationArgument] for a `%{name}` with no value
  # @raise [MissingTranslationData] for a missing key, when asked to
  # @raise [InvalidLocale] for a `locale:` that is not available
  # @api public
  def self.t(key, options = {})
    found = I18n.find_translation(key, options)
    return found unless found.nil?

    I18n.missing_answer(I18n.option_locale(options), key.to_s)
  end

  # What {I18n.t} answers for key, or nil when no dictionary holds it and
  # there is no `default:` (no missing-key answer, no raise): the template
  # `t` helper answers its own `<span class="translation_missing">` then.
  # @param key [String, Symbol]
  # @param options [Hash{Symbol => Object}] as for {I18n.t}
  # @return [String, nil]
  # @api private
  def self.find_translation(key, options = {})
    k = key.to_s
    loc = I18n.option_locale(options)
    vars = I18n.interpolation_vars(options)
    count = options[:count]
    counted = count.is_a?(Integer)
    n = counted ? count.to_i : 0
    found = I18n.find_in_locales(loc, k, counted, n)
    if found.nil?
      fallback = options[:default]
      if fallback.is_a?(Symbol)
        found = I18n.find_in_locales(loc, fallback.to_s, counted, n)
      elsif !fallback.nil?
        found = fallback.to_s
      end
    end
    return nil if found.nil?

    I18n.interpolate_vars(found, vars)
  end

  # The `%{name}` values of options, keyed by name: `count:` (an Integer,
  # else ArgumentError) and `count_text:` both fill `%{count}`, count:
  # first; `default:` and `locale:` are no values.
  # @api private
  def self.interpolation_vars(options)
    vars = { "" => "" }
    vars.delete("")
    options.each do |name, value|
      if name == :count
        unless value.is_a?(Integer)
          message = "count: must be an Integer (got #{value.class.name})"
          raise ArgumentError, message
        end
        vars["count"] = value.to_i.to_s
      elsif name == :count_text
        vars["count"] = value.to_s unless options.key?(:count)
      elsif name != :default && name != :locale
        vars[name.to_s] = value.to_s
      end
    end
    vars
  end

  # The locale of a `locale:` option, else the thread's.
  # @api private
  def self.option_locale(options)
    wanted = options[:locale]
    wanted.nil? ? I18n.locale : I18n.resolve_locale(wanted)
  end

  # The same as {I18n.t}.
  # @param key [String, Symbol]
  # @param options [Hash{Symbol => Object}]
  # @return [String]
  # @api public
  def self.translate(key, options = {}) = I18n.t(key, options)

  # Whether key's text is HTML, as Rails decides it: the key ends in
  # `_html` or `.html` (or is `html`). The template `t` and
  # Controller#t escape the values interpolated into such a text.
  # @param key [String]
  # @return [Boolean]
  # @api public
  def self.html_key?(key)
    k = key.to_s
    k == "html" || k.end_with?("_html") || k.end_with?(".html")
  end

  # Whether a missing key answers the marked text (development and test)
  # rather than the humanised last segment (production); see
  # {I18n.mark_missing=}.
  # @return [Boolean]
  # @api public
  def self.mark_missing? = @mark_missing

  # value as text in the locale's format, as Rails' `I18n.l`: a Time in
  # `time.formats.<format>`, a Date in `date.formats.<format>`. `format:`
  # is a Symbol naming the format (`:default` when not given, `:short`,
  # `:long`, or any other the dictionaries hold) or a strftime pattern
  # String; `locale:` formats in another locale. `%a %A %b %B` take the
  # dictionary's `date.abbr_day_names`, `date.day_names`,
  # `date.abbr_month_names` and `date.month_names`, `%p` and `%P` its
  # `time.am` / `time.pm` (upper- and lower-cased, as the i18n gem does;
  # "" for a Date), `%^a` and the like upper-case the name; every other
  # directive is strftime's.
  # @example
  #   I18n.l(Time.utc(2026, 11, 10, 9, 5), format: :long)    # => "November 10, 2026 09:05"
  #   I18n.l(Date.new(2026, 11, 10), locale: :ja)            # => "2026/11/10"
  #   I18n.l(Time.utc(2026, 11, 10, 9, 5), format: "%a %p", locale: :ja)  # => "火 午前"
  # @param value [Time, Date]
  # @param options [Hash{Symbol => Object}]
  # @return [String]
  # @raise [ArgumentError] `"l: expected a Time or a Date (got Integer)"`,
  #   or a pattern directive the strftime walk does not know
  # @raise [MissingTranslationData] `"translation missing: en.time.formats.nope"`
  #   for a format Symbol no dictionary holds
  # @raise [InvalidLocale] for a `locale:` that is not available
  # @api public
  def self.l(value, options = {})
    loc = I18n.option_locale(options)
    kind = ""
    wday = 0
    mon = 0
    hour = -1
    case value
    when Time
      kind = "time"
      wday = value.wday
      mon = value.mon
      hour = value.hour
    when Date
      kind = "date"
      wday = value.wday
      mon = value.mon
    else
      message = "l: expected a Time or a Date (got #{value.class.name})"
      raise ArgumentError, message
    end
    format = options[:format]
    pattern = ""
    if format.nil? || format.is_a?(Symbol)
      name = format.nil? ? "default" : format.to_s
      key = "#{kind}.formats.#{name}"
      found = I18n.find_in_locales(loc, key, false, 0)
      if found.nil?
        message = I18n.missing_text("#{loc}.#{key}")
        raise MissingTranslationData, message
      end
      pattern = found
    elsif format.is_a?(String)
      pattern = format.to_s
    else
      message = "l: format: must be a Symbol or a String (got #{format.class.name})"
      raise ArgumentError, message
    end
    named = I18n.localized_names(pattern, loc, wday, mon, hour)
    Cybertrain::Strftime.walk(value, named, "l format")
  end

  # The same as {I18n.l}.
  # @param value [Time, Date]
  # @param options [Hash{Symbol => Object}]
  # @return [String]
  # @api public
  def self.localize(value, options = {}) = I18n.l(value, options)

  # pattern with `%a %A %b %B %p %P` (and `%^a` ...) replaced by the
  # locale's names, a `%` in a name doubled; `%%` and every other
  # directive are left for the strftime walk. A name the dictionaries do
  # not hold leaves its directive to strftime (English). hour is -1 for a
  # Date.
  # @api private
  def self.localized_names(pattern, loc, wday, mon, hour)
    s = pattern.to_s # NOTES rule 62: plain byte reads
    return s unless s.include?("%")

    out = +""
    n = s.bytesize
    start = 0
    i = 0
    while i < n
      if s.getbyte(i) != 37 # "%"
        i += 1
        next
      end
      j = i + 1
      upper = false
      if j < n && s.getbyte(j) == 94 # "^"
        upper = true
        j += 1
      end
      c = j < n ? s.getbyte(j) : 0
      if c == 37 && !upper
        i = j + 1
        next
      end
      name = I18n.directive_name(c, loc, wday, mon, hour)
      if name.nil?
        i += 1
        next
      end
      out << s.byteslice(start, i - start) if i > start
      text = upper ? name.upcase : name
      out << (text.include?("%") ? text.gsub("%", "%%") : text)
      i = j + 1
      start = i
    end
    out << s.byteslice(start, n - start) if n > start
    out
  end

  # The locale's text for one directive byte (a A b B p P), nil for any
  # other byte or a name no dictionary holds.
  # @api private
  def self.directive_name(c, loc, wday, mon, hour)
    case c
    when 97 then I18n.list_name("date.abbr_day_names", loc, wday)  # a
    when 65 then I18n.list_name("date.day_names", loc, wday)       # A
    when 98 then I18n.list_name("date.abbr_month_names", loc, mon) # b
    when 66 then I18n.list_name("date.month_names", loc, mon)      # B
    when 112, 80 # p P
      return "" if hour < 0

      found = I18n.find_in_locales(loc, hour < 12 ? "time.am" : "time.pm", false, 0)
      return nil if found.nil?

      c == 112 ? found.upcase : found.downcase
    end
  end

  # The index-th name of the list at key, nil when there is none.
  # @api private
  def self.list_name(key, loc, index)
    list = I18n.list_in_locale(loc, key)
    list = I18n.list_in_locale(I18n.default_locale, key) if list.empty?
    return nil if index >= list.size

    list[index]
  end

  # The list at key (`"date.abbr_day_names"`), from the same dictionaries
  # in the same order as {I18n.t}; empty when none holds it. `locale:` is
  # the one option.
  # @example
  #   I18n.translate_list("date.abbr_day_names")   # => ["Sun", "Mon", ...]
  # @param key [String, Symbol]
  # @param options [Hash{Symbol => Object}]
  # @return [Array<String>]
  # @api public
  def self.translate_list(key, options = {})
    k = key.to_s
    wanted = options[:locale]
    loc = wanted.nil? ? I18n.locale : I18n.resolve_locale(wanted)
    found = I18n.list_in_locale(loc, k)
    return found unless found.empty?

    I18n.list_in_locale(I18n.default_locale, k)
  end

  # The CLDR plural category of an integer count in a locale (D7), decided
  # by the locale's language (`pt-BR` by `pt`): ja and zh `other`; fr `one`
  # for 0 and 1, `many` for a non-zero multiple of 1,000,000, else `other`;
  # ru `one` (1, 21, 101), `few` (2-4, 22-24), else `many`; en and every
  # other language `one` for 1, else `other`.
  # @example
  #   I18n.plural_category(:ru, 22)   # => :few
  # @param locale [Symbol]
  # @param count [Integer]
  # @return [Symbol]
  # @api public
  def self.plural_category(locale, count)
    s = locale.to_s
    lang = I18n.base_language(s)
    n = count.abs
    case lang
    when "ja", "zh"
      :other
    when "fr"
      return :one if n < 2
      return :many if n % 1_000_000 == 0

      :other
    when "ru"
      d = n % 10
      h = n % 100
      return :one if d == 1 && h != 11
      return :few if d >= 2 && d <= 4 && (h < 12 || h > 14)

      :many
    else
      n == 1 ? :one : :other
    end
  end

  # `"pt"` from `"pt-BR"` (or `"pt_BR"`).
  # @api private
  def self.base_language(name)
    s = name.to_s
    i = 0
    n = s.bytesize
    while i < n
      b = s.getbyte(i)
      return s.byteslice(0, i) if b == 45 || b == 95 # "-" "_"

      i += 1
    end
    s
  end

  # A key segment as words, Rails' `humanize`: `"bar_baz"` → `"Bar baz"`.
  # What a missing key shows in production.
  # @param segment [String]
  # @return [String]
  # @api public
  def self.humanize_key(segment)
    s = segment.to_s
    spaced = s.tr("_", " ")
    spaced.capitalize
  end

  # An attribute name as words, Rails' `humanize`: a trailing `_id` goes,
  # `_` becomes a space and the first letter is capitalized
  # (`"published_at"` → `"Published at"`, `"author_id"` → `"Author"`).
  # Intermediate results are bound to locals, never chained: in threaded
  # programs an unnamed temporary can be collected while the next call in
  # the chain still reads it (see Inflector.underscore).
  # @param name [String]
  # @return [String]
  # @api public
  def self.humanize_attribute(name)
    s = name.to_s
    base = s.end_with?("_id") && s.length > 3 ? s[0, s.length - 3].to_s : s
    spaced = base.tr("_", " ")
    spaced.capitalize
  end

  # An attribute's name for people, as Rails' `human_attribute_name`:
  # `activerecord.attributes.<model>.<attr>`, else the humanised attribute
  # ({I18n.humanize_attribute}). A generated model answers it as
  # `Post.human_attribute_name(:title)`.
  # @example
  #   # ja.yml: ja: { activerecord: { attributes: { post: { title: "タイトル" } } } }
  #   I18n.with_locale(:ja) { I18n.human_attribute_name("post", :title) }  # => "タイトル"
  #   I18n.human_attribute_name("post", :author_id)                       # => "Author"
  # @param model_key [String] the model's key, `Inflector.underscore` of its
  #   class name (`"post"`, `"admin/post"`); `""` skips the dictionary
  # @param attr [Symbol, String]
  # @return [String]
  # @api public
  def self.human_attribute_name(model_key, attr)
    a = attr.to_s
    mk = model_key.to_s
    unless mk.empty?
      found = I18n.find_translation("activerecord.attributes.#{mk}.#{a}")
      return found unless found.nil?
    end
    I18n.humanize_attribute(a)
  end

  # A model's name for people, as Rails' `model_name.human`:
  # `activerecord.models.<model>` (its `one:` form when it has plural
  # forms), else the last segment of the key humanised (`"blog_comment"`
  # → `"Blog comment"`, `"admin/post"` → `"Post"`).
  # @param model_key [String]
  # @return [String]
  # @api public
  def self.human_model_name(model_key)
    mk = model_key.to_s
    found = I18n.find_translation("activerecord.models.#{mk}", { count: 1 })
    return found unless found.nil?

    slash = mk.rindex("/")
    element = slash.nil? ? mk : mk[(slash + 1)..].to_s
    I18n.humanize_attribute(element)
  end

  # A validation message, looked up when the validator runs, along Rails'
  # chain (plan decision D10):
  # `activerecord.errors.models.<model>.attributes.<attr>.<type>`,
  # `activerecord.errors.models.<model>.<type>`,
  # `activerecord.errors.messages.<type>`, `errors.attributes.<attr>.<type>`,
  # `errors.messages.<type>`; the whole chain in the current locale, then in
  # the default one (as Rails' fallbacks run the defaults per locale).
  # `%{attribute}` and `%{model}` are the human names, `%{count}` the
  # `count:` (an Integer, which also picks the plural form) or `count_text:`
  # (a String, numericality's limit: no plural form).
  # @example
  #   I18n.error_message("post", :title, :too_short, { count: 8 })
  #   # => "is too short (minimum is 8 characters)"
  #   I18n.error_message("post", :rating, :greater_than, { count_text: "1.5" })
  #   # => "must be greater than 1.5"
  # @param model_key [String] `""` skips the two model keys
  # @param attr [Symbol, String]
  # @param type [Symbol, String] Rails' key: `:blank`, `:too_short`, ...
  # @param options [Hash{Symbol => Object}] `count:`, `count_text:`, other
  #   interpolation values
  # @return [String]
  # @raise [MissingTranslationData] for a type no dictionary holds, when
  #   asked to (the text names the most specific key)
  # @api public
  def self.error_message(model_key, attr, type, options = {})
    mk = model_key.to_s
    a = attr.to_s
    ty = type.to_s
    keys = Array.new(0) { "" }
    unless mk.empty?
      keys << "activerecord.errors.models.#{mk}.attributes.#{a}.#{ty}"
      keys << "activerecord.errors.models.#{mk}.#{ty}"
    end
    keys << "activerecord.errors.messages.#{ty}"
    keys << "errors.attributes.#{a}.#{ty}"
    keys << "errors.messages.#{ty}"
    vars = I18n.interpolation_vars(options)
    count = options[:count]
    counted = count.is_a?(Integer)
    n = counted ? count.to_i : 0
    loc = I18n.locale
    found = I18n.first_in_locale(loc, keys, counted, n)
    default = I18n.default_locale
    found = I18n.first_in_locale(default, keys, counted, n) if found.nil? && default != loc
    return I18n.missing_answer(loc, keys[0]) if found.nil?

    # The human names cost a lookup each: made only for a text that uses them.
    vars["attribute"] = I18n.human_attribute_name(mk, a) if found.include?("%{attribute}") && !vars.key?("attribute")
    vars["model"] = I18n.human_model_name(mk) if found.include?("%{model}") && !vars.key?("model")
    I18n.interpolate_vars(found, vars)
  end

  # One message of `errors.full_messages`: `errors.format`
  # (`"%{attribute} %{message}"`, ja `"%{attribute}%{message}"`) with the
  # attribute's human name; a `:base` message stands alone.
  # @param model_key [String]
  # @param attr [Symbol, String]
  # @param message [String]
  # @return [String]
  # @api public
  def self.full_message(model_key, attr, message)
    a = attr.to_s
    m = message.to_s
    return m if a == "base"

    attribute = I18n.human_attribute_name(model_key, a)
    I18n.t("errors.format", { default: "%{attribute} %{message}", attribute: attribute, message: m })
  end

  # The first of keys one locale holds (no default-locale fallback).
  # @api private
  def self.first_in_locale(loc, keys, counted, n)
    keys.each do |key|
      found = I18n.text_in_locale(loc, key, counted, n)
      return found unless found.nil?
    end
    nil
  end

  # `"translation missing: ja.foo.bar"` for the full key `"ja.foo.bar"`.
  # @param full_key [String]
  # @return [String]
  # @api public
  def self.missing_text(full_key) = "translation missing: #{full_key}"

  # What t answers for a key no dictionary holds (D5).
  # @api private
  def self.missing_answer(loc, key)
    full = "#{loc}.#{key}"
    text = I18n.missing_text(full)
    raise MissingTranslationData, text if @raise_on_missing
    return text if @mark_missing

    dot = key.rindex(".")
    last = dot.nil? ? key : key[(dot + 1)..]
    I18n.humanize_key(last.to_s)
  end

  # The text at key in the locale, then in the default locale; nil when
  # neither holds it.
  # @api private
  def self.find_in_locales(loc, key, counted, n)
    found = I18n.text_in_locale(loc, key, counted, n)
    return found unless found.nil?

    default = I18n.default_locale
    return nil if default == loc

    I18n.text_in_locale(default, key, counted, n)
  end

  # The text at key in one locale, the two dictionaries merged as Rails'
  # deep merge of an application file over rails-i18n merges them: a text
  # at the key replaces whatever the other holds there (the application's
  # first); the application's plural forms replace a bundled text at the
  # key; and two sets of plural forms merge form by form, the
  # application's first, so an application adding only `zero:` keeps the
  # bundled `one:` and `other:`. Without count:, plural forms are no text.
  # @api private
  def self.text_in_locale(loc, key, counted, n)
    full = "#{loc}.#{key}"
    text = I18n.dictionary_text(true, full)
    return text unless text.nil?

    bundled = I18n.dictionary_text(false, full)
    # Probed only here, off the common path: the application's forms hide
    # a bundled text.
    return bundled unless bundled.nil? || I18n.plural_forms_at?(true, full)
    return nil unless counted

    if n == 0
      zero = I18n.merged_form(full, "zero")
      return zero unless zero.nil?
    end
    category = I18n.plural_category(loc, n)
    form = I18n.merged_form(full, category.to_s)
    return form unless form.nil?

    I18n.merged_form(full, "other")
  end

  # The plural form under full, the application's, else the bundled one.
  # @api private
  def self.merged_form(full, form)
    sub = "#{full}.#{form}"
    found = I18n.dictionary_text(true, sub)
    return found unless found.nil?

    I18n.dictionary_text(false, sub)
  end

  # Whether one dictionary holds any plural form under full.
  # @api private
  def self.plural_forms_at?(app, full)
    PLURAL_KEYS.each do |form|
      sub = "#{full}.#{form}"
      return true unless I18n.dictionary_text(app, sub).nil?
    end
    false
  end

  # The application's (app) or the bundled dictionary's text at full.
  # @api private
  def self.dictionary_text(app, full)
    return @app_texts.call(full) if app

    Cybertrain::BundledLocales.lookup(full)
  end

  # The list at key in one locale, the application's first.
  # @api private
  def self.list_in_locale(loc, key)
    full = "#{loc}.#{key}"
    found = @app_lists.call(full)
    return found unless found.empty?

    Cybertrain::BundledLocales.lookup_list(full)
  end

  # text with `%{name}` filled from vars and `%%` made `%`.
  # @api private
  def self.interpolate_vars(text, vars)
    s = text.to_s
    return s unless s.include?("%")

    out = +""
    n = s.bytesize
    start = 0
    i = 0
    while i < n
      if s.getbyte(i) != 37 # "%"
        i += 1
        next
      end
      nxt = i + 1 < n ? s.getbyte(i + 1) : 0
      if nxt == 37
        out << s.byteslice(start, i + 1 - start)
        i += 2
        start = i
        next
      end
      # A name is \w+ (ASCII letters, digits, "_"), as in the i18n gem's
      # pattern; `%{a b}`, `%{}` and an unclosed `%{` stay literal.
      close = i + 2
      close += 1 while nxt == 123 && close < n && I18n.name_byte?(s.getbyte(close))
      if nxt != 123 || close >= n || close == i + 2 || s.getbyte(close) != 125 # "{" "}"
        i += 1
        next
      end
      name = s.byteslice(i + 2, close - i - 2)
      value = vars[name]
      if value.nil?
        message = "missing interpolation argument :#{name} in \"#{s}\""
        raise MissingInterpolationArgument, message
      end
      out << s.byteslice(start, i - start) if i > start
      out << value
      i = close + 1
      start = i
    end
    out << s.byteslice(start, n - start) if n > start
    out
  end

  # Whether byte b may be part of an interpolation name: [A-Za-z0-9_].
  # @api private
  def self.name_byte?(b)
    (b >= 97 && b <= 122) || (b >= 65 && b <= 90) || (b >= 48 && b <= 57) || b == 95
  end
end
