# Phase 4b spike, item 6c (R4): a thread-local locale under Spinel, in a
# program with the whole framework (`require "cybertrain"`) and the db
# pool in use, so Thread.current also holds a Connection under the pool's
# TRANSACTION_KEY. Two green threads each set
# Thread.current[:cybertrain_i18n_locale] (:ja in one, :en in the other),
# open a DB.transaction, `sleep 0` (so the other thread runs in between)
# and read their own locale back; a key never set reads nil. A record,
# not a test.
#
# Run (Spinel 2026.11.04.7026, from spikes/phase4b/; SQLite through FFI,
# so compiled only):
#   time spinel $(spin flags) thread_locale.rb -o $TMPDIR/thread_locale && $TMPDIR/thread_locale
#   SPINEL_WORKERS=4 $TMPDIR/thread_locale
# Output (79 to 80 s to compile, a 3,289,448-byte binary; a 4-vCPU cloud
# machine):
#   main before: :en (raw nil)
#   thread en: set :en
#   thread ja: set :ja
#   thread en: in the transaction, read :en (raw :en), transaction connection held: true
#   thread en: after the transaction :en, held none
#   thread ja: in the transaction, read :ja (raw :ja), transaction connection held: true
#   thread ja: after the transaction :ja, held none
#   main after: :fr
#   missing entry: nil
#   rows: [{"n" => 2}]
# With SPINEL_WORKERS=4 the threads ran in the other order (ja first), with
# the same values. Each thread reads its own Symbol after the other set
# its own, the main thread keeps :fr, and a Symbol beside the pool's
# Connection under another key of Thread.current needs nothing special.
# Verdict: PASS; I18n.locale is thread-local (R4), no Context field.
require "cybertrain"

module LocaleSpike
  KEY = :cybertrain_i18n_locale

  # As I18n.locale would read it: the thread's Symbol, or the default.
  def self.current
    value = Thread.current[KEY]
    value.nil? ? :en : value
  end

  def self.current=(value)
    Thread.current[KEY] = value
  end

  # One request's worth: set, yield the thread, read back, inside a
  # transaction (Thread.current[TRANSACTION_KEY] holds its Connection).
  def self.work(name, locale, out)
    LocaleSpike.current = locale
    first = "#{name}: set #{locale.inspect}"
    out << first
    sleep 0
    Cybertrain::DB.transaction do |conn|
      conn.execute("INSERT INTO t (who) VALUES (?)", [name])
      sleep 0
      held = Thread.current[Cybertrain::DB::Pool::TRANSACTION_KEY]
      line = "#{name}: in the transaction, read #{LocaleSpike.current.inspect} " \
             "(raw #{Thread.current[KEY].inspect}), transaction connection held: #{!held.nil?}"
      out << line
    end
    sleep 0
    line = "#{name}: after the transaction #{LocaleSpike.current.inspect}, held #{Thread.current[Cybertrain::DB::Pool::TRANSACTION_KEY].nil? ? "none" : "one"}"
    out << line
    nil
  end

  def self.start(name, locale, out)
    Thread.new { LocaleSpike.work(name, locale, out) }
  end
end

Cybertrain::DB.connect(":memory:", size: 1)
Cybertrain::DB.with { |c| c.execute("CREATE TABLE t (who TEXT)") }
out = Queue.new
puts "main before: #{LocaleSpike.current.inspect} (raw #{Thread.current[LocaleSpike::KEY].inspect})"
a = LocaleSpike.start("thread ja", :ja, out)
b = LocaleSpike.start("thread en", :en, out)
LocaleSpike.current = :fr
a.join
b.join
lines = []
lines << out.pop until out.empty?
# In the order the threads wrote them: each set comes before the other
# thread's read.
lines.each { |l| puts l }
puts "main after: #{LocaleSpike.current.inspect}"
puts "missing entry: #{Thread.current[:cybertrain_i18n_nope].inspect}"
rows = Cybertrain::DB.with { |c| c.execute("SELECT COUNT(*) AS n FROM t") }
puts "rows: #{rows.inspect}"
