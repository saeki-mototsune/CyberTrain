require "stringio"
require "cybertrain/test"
require "cybertrain/main"

# Application-defined settings (Config#setting_string / setting_int /
# setting_bool): typed values read once from the environment, the
# fallback-with-warning for unusable values, secrets kept out of the
# listings, and `help` showing the declarations. Requires cybertrain/main
# for Main.usage, which links SQLite through FFI, so the snapshot comes
# from the compiled binary (spikes/NOTES.md rule 23). Names are always
# Symbols (rule 51); each block's locals have names of their own (rule 63).

# Runs the block with Cybertrain.logger writing into a StringIO and returns
# what was logged.
def captured_log(&block)
  saved = Cybertrain.logger
  sink = StringIO.new
  Cybertrain.logger = Cybertrain::Logger.new(sink)
  block.call
  Cybertrain.logger = saved
  sink.string
end

test "a string setting reads its variable, an empty one means the default" do
  ENV["CT_TEST_BASE_URL"] = "https://example.com"
  ENV["CT_TEST_NAME"] = ""
  conf = Cybertrain::Config.new
  conf.setting_string :base_url, env: "CT_TEST_BASE_URL", default: ""
  conf.setting_string :site_name, env: "CT_TEST_NAME", default: "Blog"
  conf.setting_string :unset_one, env: "CT_TEST_NEVER_SET", default: "fallback"
  assert_equal "https://example.com", conf.string_setting(:base_url)
  assert_equal "Blog", conf.string_setting(:site_name)
  assert_equal "fallback", conf.string_setting(:unset_one)
end

test "a boolean setting takes 1/true and 0/false" do
  ENV["CT_TEST_ON1"] = "1"
  ENV["CT_TEST_ON2"] = "true"
  ENV["CT_TEST_OFF1"] = "0"
  ENV["CT_TEST_OFF2"] = "false"
  ENV["CT_TEST_EMPTY"] = ""
  flags = Cybertrain::Config.new
  flags.setting_bool :on1, env: "CT_TEST_ON1", default: false
  flags.setting_bool :on2, env: "CT_TEST_ON2", default: false
  flags.setting_bool :off1, env: "CT_TEST_OFF1", default: true
  flags.setting_bool :off2, env: "CT_TEST_OFF2", default: true
  flags.setting_bool :empty_on, env: "CT_TEST_EMPTY", default: true
  flags.setting_bool :empty_off, env: "CT_TEST_EMPTY", default: false
  assert flags.bool_setting(:on1)
  assert flags.bool_setting(:on2)
  refute flags.bool_setting(:off1)
  refute flags.bool_setting(:off2)
  assert flags.bool_setting(:empty_on)
  refute flags.bool_setting(:empty_off)
end

test "an integer setting parses digits and an optional minus within its bounds" do
  ENV["CT_TEST_INTERVAL"] = "60"
  ENV["CT_TEST_ZEROS"] = "0000000000000000000000042"
  ENV["CT_TEST_NEG"] = "-5"
  ENV["CT_TEST_LOW"] = "1"
  ENV["CT_TEST_HIGH"] = "9999999"
  nums = Cybertrain::Config.new
  nums.setting_int :interval, env: "CT_TEST_INTERVAL", default: 3600, min: 1, max: 9_999_999
  nums.setting_int :zeros, env: "CT_TEST_ZEROS", default: 1
  nums.setting_int :neg, env: "CT_TEST_NEG", default: 0, min: -10
  nums.setting_int :low, env: "CT_TEST_LOW", default: 3600, min: 1, max: 9_999_999
  nums.setting_int :high, env: "CT_TEST_HIGH", default: 3600, min: 1, max: 9_999_999
  nums.setting_int :absent, env: "CT_TEST_NEVER_SET", default: 7
  assert_equal 60, nums.int_setting(:interval)
  assert_equal 42, nums.int_setting(:zeros)
  assert_equal(-5, nums.int_setting(:neg))
  assert_equal 1, nums.int_setting(:low)
  assert_equal 9_999_999, nums.int_setting(:high)
  assert_equal 7, nums.int_setting(:absent)
end

test "an unparsable or out-of-range value falls back to the default with a warning" do
  ENV["CT_TEST_BAD_INT"] = "12abc"
  ENV["CT_TEST_HUGE"] = "123456789012345678901234567890"
  ENV["CT_TEST_ZERO"] = "0"
  ENV["CT_TEST_ABOVE"] = "10000000"
  ENV["CT_TEST_MINUS"] = "-"
  ENV["CT_TEST_BAD_BOOL"] = "yes"
  bad = Cybertrain::Config.new
  logged = captured_log do
    bad.setting_int :bad_int, env: "CT_TEST_BAD_INT", default: 3600, min: 1, max: 9_999_999
    bad.setting_int :huge, env: "CT_TEST_HUGE", default: 3600
    bad.setting_int :zero, env: "CT_TEST_ZERO", default: 3600, min: 1, max: 9_999_999
    bad.setting_int :above, env: "CT_TEST_ABOVE", default: 3600, min: 1, max: 9_999_999
    bad.setting_int :minus, env: "CT_TEST_MINUS", default: 3600, min: 1
    bad.setting_bool :bad_bool, env: "CT_TEST_BAD_BOOL", default: true
  end
  assert_equal 3600, bad.int_setting(:bad_int)
  assert_equal 3600, bad.int_setting(:huge)
  assert_equal 3600, bad.int_setting(:zero)
  assert_equal 3600, bad.int_setting(:above)
  assert_equal 3600, bad.int_setting(:minus)
  assert bad.bool_setting(:bad_bool)
  print logged
  assert_includes logged, "[WARN] CT_TEST_BAD_INT=\"12abc\" is not an integer; using the default 3600"
  assert_includes logged, "[WARN] CT_TEST_ZERO=0 is out of range (1..9999999); using the default 3600"
  assert_includes logged, "[WARN] CT_TEST_BAD_BOOL=\"yes\" is not a boolean (1/true or 0/false); using the default true"
end

test "a usable value logs nothing" do
  ENV["CT_TEST_FINE"] = "10"
  quiet = Cybertrain::Config.new
  silence = captured_log do
    quiet.setting_int :fine, env: "CT_TEST_FINE", default: 1, min: 1, max: 100
    quiet.setting_bool :fine_flag, env: "CT_TEST_NEVER_SET", default: false
  end
  assert_equal "", silence
end

test "CYBERTRAIN_HEALTH_FEED_STALE sets health_feed_stale; unset or bad is 180; below 1 is refused" do
  ENV.delete("CYBERTRAIN_HEALTH_FEED_STALE")
  assert_equal 180, Cybertrain::Config.new.health_feed_stale
  ENV["CYBERTRAIN_HEALTH_FEED_STALE"] = "60"
  assert_equal 60, Cybertrain::Config.new.health_feed_stale
  ENV["CYBERTRAIN_HEALTH_FEED_STALE"] = "soon"
  assert_equal 180, Cybertrain::Config.new.health_feed_stale
  ENV["CYBERTRAIN_HEALTH_FEED_STALE"] = "0"
  assert_includes Cybertrain::Config.new.health_error, "health_feed_stale must be at least 1"
  ENV.delete("CYBERTRAIN_HEALTH_FEED_STALE")
end

test "time_zone from the environment and its check" do
  ENV.delete("CYBERTRAIN_TIME_ZONE")
  assert_equal "UTC", Cybertrain::Config.new.time_zone
  assert_equal "", Cybertrain::Config.new.time_zone_error
  ENV["CYBERTRAIN_TIME_ZONE"] = "Asia/Tokyo"
  tokyo = Cybertrain::Config.new
  assert_equal "Asia/Tokyo", tokyo.time_zone
  assert_equal "", tokyo.time_zone_error
  assert_equal "", tokyo.validation_error
  # An empty variable counts as unset.
  ENV["CYBERTRAIN_TIME_ZONE"] = ""
  assert_equal "UTC", Cybertrain::Config.new.time_zone
  ENV["CYBERTRAIN_TIME_ZONE"] = "Mars/Base"
  mars = Cybertrain::Config.new
  assert_equal "time_zone \"Mars/Base\" is not a known time zone", mars.time_zone_error
  assert_equal "time_zone \"Mars/Base\" is not a known time zone", mars.validation_error
  ENV.delete("CYBERTRAIN_TIME_ZONE")
  assigned = Cybertrain::Config.new
  assigned.time_zone = "../zoneinfo/Asia/Tokyo"
  assert_equal "time_zone \"../zoneinfo/Asia/Tokyo\" is not a known time zone", assigned.validation_error
  assigned.time_zone = "America/New_York"
  assert_equal "", assigned.validation_error
end

test "mail_delivery_method from the environment and its check" do
  saved_env = ENV["CYBERTRAIN_ENV"].to_s
  ENV.delete("CYBERTRAIN_MAIL_DELIVERY_METHOD")
  ENV.delete("CYBERTRAIN_ENV")
  # :test in the test environment only; :smtp everywhere else.
  assert_equal :smtp, Cybertrain::Config.new.mail_delivery_method
  ENV["CYBERTRAIN_ENV"] = "production"
  assert_equal :smtp, Cybertrain::Config.new.mail_delivery_method
  ENV["CYBERTRAIN_ENV"] = "test"
  in_test = Cybertrain::Config.new
  assert_equal :test, in_test.mail_delivery_method
  assert_equal "", in_test.mail_delivery_error
  # The variable decides whatever the environment.
  ENV["CYBERTRAIN_MAIL_DELIVERY_METHOD"] = "smtp"
  assert_equal :smtp, Cybertrain::Config.new.mail_delivery_method
  ENV["CYBERTRAIN_ENV"] = "development"
  ENV["CYBERTRAIN_MAIL_DELIVERY_METHOD"] = "test"
  assert_equal :test, Cybertrain::Config.new.mail_delivery_method
  # In any case, as CYBERTRAIN_SMTP_TLS.
  ENV["CYBERTRAIN_MAIL_DELIVERY_METHOD"] = "SMTP"
  assert_equal :smtp, Cybertrain::Config.new.mail_delivery_method
  # An empty variable counts as unset.
  ENV["CYBERTRAIN_MAIL_DELIVERY_METHOD"] = ""
  assert_equal :smtp, Cybertrain::Config.new.mail_delivery_method
  ENV["CYBERTRAIN_MAIL_DELIVERY_METHOD"] = "letter_opener"
  opener = Cybertrain::Config.new
  assert_equal :letter_opener, opener.mail_delivery_method
  assert_equal "mail_delivery_method must be :smtp or :test (got :letter_opener)", opener.mail_delivery_error
  assert_equal "mail_delivery_method must be :smtp or :test (got :letter_opener)", opener.validation_error
  ENV.delete("CYBERTRAIN_MAIL_DELIVERY_METHOD")
  assigned = Cybertrain::Config.new
  assigned.mail_delivery_method = :sendmail
  assert_equal "mail_delivery_method must be :smtp or :test (got :sendmail)", assigned.validation_error
  assigned.mail_delivery_method = :test
  assert_equal "", assigned.validation_error
  if saved_env.empty?
    ENV.delete("CYBERTRAIN_ENV")
  else
    ENV["CYBERTRAIN_ENV"] = saved_env
  end
end

test "boot refuses a health_feed_stale not above feed_status_interval while health_feeds is on" do
  c = Cybertrain::Config.new
  c.feed_status_interval = 300
  c.health_feed_stale = 180
  assert_equal "health_feed_stale (180) must be more than feed_status_interval (300) while health_feeds is on",
               c.health_error
  c.health_feed_stale = 300
  assert_includes c.health_error, "health_feed_stale (300) must be more than feed_status_interval (300)"
  c.health_feed_stale = 301
  assert_equal "", c.health_error
  # With the feed check off the two are unrelated.
  c.health_feed_stale = 180
  c.health_feeds = false
  assert_equal "", c.health_error
  # With the health check off (no path) nothing reads health_feed_stale.
  c.health_feeds = true
  c.health_path = ""
  assert_equal "", c.health_error
end

test "a bad declaration is an ArgumentError" do
  wrong = Cybertrain::Config.new
  wrong.setting_string :taken, env: "CT_TEST_TAKEN", default: ""
  assert_equal "setting taken is declared twice",
               assert_raises("ArgumentError") { wrong.setting_bool :taken, env: "CT_TEST_TAKEN2", default: true }
  assert_equal "setting no_env: env must name an environment variable",
               assert_raises("ArgumentError") { wrong.setting_string :no_env, env: "", default: "" }
  assert_equal "setting outside: default 0 is out of range (1..10)",
               assert_raises("ArgumentError") { wrong.setting_int :outside, env: "CT_TEST_OUTSIDE", default: 0, min: 1, max: 10 }
end

test "reading an undeclared or differently typed setting is an ArgumentError" do
  typed = Cybertrain::Config.new
  typed.setting_string :label, env: "CT_TEST_LABEL", default: "x"
  assert_equal "no integer setting label (declare it with setting_int)",
               assert_raises("ArgumentError") { typed.int_setting(:label) }
  assert_equal "no boolean setting missing (declare it with setting_bool)",
               assert_raises("ArgumentError") { typed.bool_setting(:missing) }
  assert_equal "no string setting missing (declare it with setting_string)",
               assert_raises("ArgumentError") { typed.string_setting(:missing) }
end

test "tests can reassign a setting through the writers" do
  ENV["CT_TEST_WORKER"] = "1"
  writable = Cybertrain::Config.new
  writable.setting_string :host_url, env: "CT_TEST_NEVER_SET", default: "a"
  writable.setting_int :every, env: "CT_TEST_NEVER_SET", default: 5, min: 1, max: 10
  writable.setting_bool :worker, env: "CT_TEST_WORKER", default: false
  writable.set_string_setting(:host_url, "b")
  writable.set_int_setting(:every, 50)
  writable.set_bool_setting(:worker, false)
  assert_equal "b", writable.string_setting(:host_url)
  assert_equal 50, writable.int_setting(:every)
  refute writable.bool_setting(:worker)
  assert_raises("ArgumentError") { writable.set_int_setting(:host_url, 1) }
end

test "a secret's value stays out of the summary and the listing" do
  ENV["CT_TEST_SMTP_PASSWORD"] = "hunter2"
  ENV["CT_TEST_SMTP_HOST"] = "mail.example.com"
  hidden = Cybertrain::Config.new
  hidden.setting_string :smtp_host, env: "CT_TEST_SMTP_HOST", default: "localhost"
  hidden.setting_string :smtp_password, env: "CT_TEST_SMTP_PASSWORD", default: "devpass", secret: true
  assert_equal "hunter2", hidden.string_setting(:smtp_password)
  summary = hidden.settings_summary
  listing = hidden.settings_usage
  puts summary
  print listing
  assert_equal "smtp_host=\"mail.example.com\" smtp_password=[FILTERED]", summary
  refute listing.index("hunter2")
  refute listing.index("devpass")
  assert_includes listing, "CT_TEST_SMTP_PASSWORD  smtp_password: string, secret"
end

test "nothing declared lists nothing" do
  empty = Cybertrain::Config.new
  assert_equal "", empty.settings_summary
  assert_equal "", empty.settings_usage
end

test "help lists every declared setting with its variable and default" do
  ENV["CT_TEST_PRUNE"] = "120"
  Cybertrain.config = Cybertrain::Config.new
  Cybertrain.configure do |c|
    c.setting_string :base_url, env: "CT_TEST_NEVER_SET", default: ""
    c.setting_bool :worker, env: "CT_TEST_NEVER_SET", default: true
    c.setting_int :prune_interval, env: "CT_TEST_PRUNE", default: 3600, min: 1, max: 9_999_999
    c.setting_int :retries, env: "CT_TEST_NEVER_SET", default: 3, min: 0
    c.setting_string :api_key, env: "CT_TEST_NEVER_SET", default: "dev-key", secret: true
  end
  assert_equal 120, Cybertrain.config.int_setting(:prune_interval)
  help = Cybertrain::Main.usage("blog")
  print help
  assert_includes help, "./blog help\n\nSettings (environment variables):\n"
  assert_includes help, "  CT_TEST_PRUNE      prune_interval: integer 1..9999999, default 3600\n"
  assert_includes help, "  CT_TEST_NEVER_SET  worker: boolean (1/true, 0/false), default true\n"
  assert_includes help, "  CT_TEST_NEVER_SET  retries: integer >= 0, default 3\n"
  assert_includes help, "  CT_TEST_NEVER_SET  base_url: string, default \"\"\n"
  refute help.index("dev-key")
  assert_equal "base_url=\"\" worker=true prune_interval=120 retries=3 api_key=[FILTERED]",
               Cybertrain.config.settings_summary
end

# The encryption key (cybertrain/encryptor.rb uses it; the checks here are
# string-level and need no openssl). A set but malformed key fails boot;
# an empty one only when the generated app declares `encrypts`
# (Config.encryption_required, set by gen/app.rb).
VALID_KEY = "0123456789abcdef0123456789abcdef0123456789ABCDEF0123456789abcdef"

test "the encryption keys are read from their variables, the previous ones as a comma list" do
  ENV["CYBERTRAIN_ENCRYPTION_KEY"] = VALID_KEY
  ENV["CYBERTRAIN_ENCRYPTION_KEY_PREVIOUS"] = " #{"a" * 64}, ,#{"b" * 64}"
  keyed = Cybertrain::Config.new
  assert_equal VALID_KEY, keyed.encryption_key
  assert_equal ["a" * 64, "b" * 64], keyed.encryption_keys_previous
  # Surrounding whitespace (a .env line's newline) is not part of the key.
  ENV["CYBERTRAIN_ENCRYPTION_KEY"] = " #{VALID_KEY}\n"
  padded = Cybertrain::Config.new
  assert_equal VALID_KEY, padded.encryption_key
  assert_equal "", padded.encryption_error
  ENV["CYBERTRAIN_ENCRYPTION_KEY"] = ""
  ENV["CYBERTRAIN_ENCRYPTION_KEY_PREVIOUS"] = ""
  unkeyed = Cybertrain::Config.new
  assert_equal "", unkeyed.encryption_key
  assert_equal 0, unkeyed.encryption_keys_previous.size
end

test "encryption_error: a malformed key fails, an unset one only when encryption is required" do
  checked = Cybertrain::Config.new
  checked.encryption_key = ""
  assert_equal "", checked.encryption_error
  checked.encryption_key = VALID_KEY
  assert_equal "", checked.encryption_error
  checked.encryption_key = VALID_KEY[0, 63].to_s
  assert_equal "CYBERTRAIN_ENCRYPTION_KEY must be 64 hex characters; make one with `cybertrain secret --hex`",
               checked.encryption_error
  checked.encryption_key = VALID_KEY[0, 63].to_s + "g"
  assert_equal "CYBERTRAIN_ENCRYPTION_KEY must be 64 hex characters; make one with `cybertrain secret --hex`",
               checked.encryption_error
  checked.encryption_key = VALID_KEY
  checked.encryption_keys_previous = [VALID_KEY, "abc"]
  assert_equal "CYBERTRAIN_ENCRYPTION_KEY_PREVIOUS entry 2 must be 64 hex characters", checked.encryption_error
  checked.encryption_keys_previous = [VALID_KEY]
  assert_equal "", checked.encryption_error
  checked.encryption_key = ""
  Cybertrain::Config.encryption_required = true
  assert_equal "CYBERTRAIN_ENCRYPTION_KEY is not set; make one with `cybertrain secret --hex`",
               checked.encryption_error
  checked.encryption_key = VALID_KEY
  assert_equal "", checked.encryption_error
  Cybertrain::Config.encryption_required = false
  assert_equal false, Cybertrain::Config.encryption_required
end

test "the transport and policy settings default off, permissions_policy on" do
  ENV.delete("CYBERTRAIN_FORCE_SSL")
  ENV.delete("CYBERTRAIN_HOSTS")
  conf = Cybertrain::Config.new
  refute conf.force_ssl
  assert conf.hosts_from_env.empty?
  assert_equal "camera=(), microphone=(), geolocation=()", conf.permissions_policy
  assert_nil conf.content_security_policy_value
  refute conf.content_security_policy_report_only
  assert conf.content_security_policy_nonce_directives.empty?
  assert_equal "", conf.security_error
end

test "CYBERTRAIN_FORCE_SSL takes 1/true and 0/false; anything else stops the boot" do
  ["1", "true"].each do |on|
    ENV["CYBERTRAIN_FORCE_SSL"] = on
    forced = Cybertrain::Config.new
    assert forced.force_ssl
    assert_equal "", forced.security_error
  end
  ["0", "false", ""].each do |off|
    ENV["CYBERTRAIN_FORCE_SSL"] = off
    plain = Cybertrain::Config.new
    refute plain.force_ssl
    assert_equal "", plain.security_error
  end
  ENV["CYBERTRAIN_FORCE_SSL"] = "yes"
  bad = Cybertrain::Config.new
  refute bad.force_ssl
  assert_equal "CYBERTRAIN_FORCE_SSL must be 1, true, 0, false or empty (got \"yes\")", bad.security_error
  ENV.delete("CYBERTRAIN_FORCE_SSL")
end

test "force_ssl makes cookies Secure whatever session_secure says" do
  ENV.delete("CYBERTRAIN_FORCE_SSL")
  conf = Cybertrain::Config.new
  conf.session_secure = false
  refute conf.secure_cookies?
  conf.force_ssl = true
  assert conf.secure_cookies?
  conf.force_ssl = false
  conf.session_secure = true
  assert conf.secure_cookies?
end

test "a nonce directive that is not a directive, or a CR in permissions_policy, stops the boot" do
  conf = Cybertrain::Config.new
  conf.content_security_policy_nonce_directives = %w[script-src scripts-src]
  assert_equal "content_security_policy_nonce_directives: \"scripts-src\" is not a directive", conf.security_error
  conf.content_security_policy_nonce_directives = %w[script-src style-src]
  assert_equal "", conf.security_error
  conf.permissions_policy = "camera=()\r\nSet-Cookie: x=1"
  assert_equal "permissions_policy must not contain CR or LF", conf.security_error
end

test "content_security_policy builds the policy once and yields it" do
  conf = Cybertrain::Config.new
  conf.content_security_policy do |p|
    p.default_src :self
    p.script_src :self, "https://cdn.jsdelivr.net"
  end
  conf.content_security_policy { |p| p.style_src :self, :unsafe_inline }
  policy = conf.content_security_policy_value
  refute policy.nil?
  assert_equal "default-src 'self'; script-src 'self' https://cdn.jsdelivr.net; style-src 'self' 'unsafe-inline'",
               policy.header_value("", [])
end


def clear_i18n_auth_env
  ["CYBERTRAIN_I18N_DEFAULT_LOCALE", "CYBERTRAIN_AUTH_LOCKOUT_ATTEMPTS", "CYBERTRAIN_AUTH_LOCKOUT_PERIOD",
   "CYBERTRAIN_AUTH_REMEMBER_FOR", "CYBERTRAIN_AUTH_IDLE_TIMEOUT"].each { |name| ENV[name] = "" }
end

test "i18n settings from the environment and their checks" do
  clear_i18n_auth_env
  conf = Cybertrain::Config.new
  assert_equal :en, conf.i18n_default_locale
  assert_equal [], conf.i18n_available_locales
  assert_equal [:en], conf.i18n_locales
  assert_equal false, conf.i18n_raise_on_missing
  assert_equal "", conf.i18n_error

  ENV["CYBERTRAIN_I18N_DEFAULT_LOCALE"] = "ja"
  conf = Cybertrain::Config.new
  assert_equal :ja, conf.i18n_default_locale
  assert_equal [:ja], conf.i18n_locales
  assert_equal "", conf.i18n_error

  ENV["CYBERTRAIN_I18N_DEFAULT_LOCALE"] = "pt-BR"
  conf = Cybertrain::Config.new
  assert_equal :"pt-BR", conf.i18n_default_locale
  assert_equal "", conf.i18n_error

  ENV["CYBERTRAIN_I18N_DEFAULT_LOCALE"] = "x y"
  conf = Cybertrain::Config.new
  assert_equal "i18n_default_locale (or CYBERTRAIN_I18N_DEFAULT_LOCALE) must be a locale name such as en or pt-BR (got \"x y\")", conf.i18n_error

  ["e", "english-language", "../en", "en/", "-en", "en-", "en--US", "1n", "en-U", "JA\n", "a" * 40].each do |junk|
    ENV["CYBERTRAIN_I18N_DEFAULT_LOCALE"] = junk
    conf = Cybertrain::Config.new
    assert_equal "i18n_default_locale (or CYBERTRAIN_I18N_DEFAULT_LOCALE) must be a locale name such as en or pt-BR (got #{junk.inspect})", conf.i18n_error
  end
  ["en", "ja", "pt-BR", "pt_BR", "zh-Hant-TW", "EN", "es-419"].each do |name|
    assert_equal true, Cybertrain::Config.locale_name?(name)
  end

  ENV["CYBERTRAIN_I18N_DEFAULT_LOCALE"] = ""
  conf = Cybertrain::Config.new
  conf.i18n_default_locale = :fr
  conf.i18n_available_locales = [:en, :ja]
  assert_equal "i18n_default_locale :fr is not in i18n_available_locales [:en, :ja]", conf.i18n_error
  assert_equal [:en, :ja], conf.i18n_locales
  conf.i18n_default_locale = :ja
  assert_equal "", conf.i18n_error
  # Set in config/app.rb rather than the environment: the message names both.
  conf.i18n_default_locale = :"e n"
  assert_equal "i18n_default_locale (or CYBERTRAIN_I18N_DEFAULT_LOCALE) must be a locale name such as en or pt-BR (got \"e n\")", conf.i18n_error
  conf.i18n_default_locale = :ja
  conf.i18n_available_locales = [:en, :"j a"]
  assert_equal "i18n_available_locales entries must be locale names such as en or pt-BR (got \"j a\")", conf.i18n_error
end

test "auth settings and their checks" do
  clear_i18n_auth_env
  conf = Cybertrain::Config.new
  assert_equal 10, conf.auth_lockout_attempts
  assert_equal 3600, conf.auth_lockout_period
  assert_equal 2_592_000, conf.auth_remember_for
  assert_equal 604_800, conf.auth_idle_timeout
  assert_equal "", conf.auth_error

  ENV["CYBERTRAIN_AUTH_LOCKOUT_ATTEMPTS"] = "5"
  ENV["CYBERTRAIN_AUTH_LOCKOUT_PERIOD"] = "60"
  ENV["CYBERTRAIN_AUTH_REMEMBER_FOR"] = "120"
  ENV["CYBERTRAIN_AUTH_IDLE_TIMEOUT"] = "30"
  conf = Cybertrain::Config.new
  assert_equal 5, conf.auth_lockout_attempts
  assert_equal 60, conf.auth_lockout_period
  assert_equal 120, conf.auth_remember_for
  assert_equal 30, conf.auth_idle_timeout
  assert_equal "", conf.auth_error

  # not a number: the default
  ENV["CYBERTRAIN_AUTH_LOCKOUT_ATTEMPTS"] = "many"
  assert_equal 10, Cybertrain::Config.new.auth_lockout_attempts

  # 0 is off for attempts and idle timeout
  clear_i18n_auth_env
  conf = Cybertrain::Config.new
  conf.auth_lockout_attempts = 0
  conf.auth_idle_timeout = 0
  assert_equal "", conf.auth_error

  conf.auth_lockout_attempts = -1
  assert_equal "auth_lockout_attempts must be 0 (off) or more (got -1)", conf.auth_error
  conf.auth_lockout_attempts = 10
  conf.auth_lockout_period = 0
  assert_equal "auth_lockout_period must be at least 1 second (got 0)", conf.auth_error
  conf.auth_lockout_period = 3600
  conf.auth_remember_for = 0
  assert_equal "auth_remember_for must be at least 1 second (got 0)", conf.auth_error
  conf.auth_remember_for = 1
  conf.auth_idle_timeout = -5
  assert_equal "auth_idle_timeout must be 0 (off) or more (got -5)", conf.auth_error
  conf.auth_idle_timeout = 1
  assert_equal "", conf.auth_error

  # a value from the environment that boot refuses is kept as written
  ENV["CYBERTRAIN_AUTH_REMEMBER_FOR"] = "0"
  assert_equal "auth_remember_for must be at least 1 second (got 0)", Cybertrain::Config.new.auth_error
  clear_i18n_auth_env
end

Cybertrain::Test.run!
