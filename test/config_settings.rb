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

Cybertrain::Test.run!
