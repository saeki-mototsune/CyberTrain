require "stringio"
require "tmpdir"
require "cybertrain"
require "cybertrain/test"
require "cybertrain/test/client"
require "cybertrain/test/http_receiver"

# Spec section 2.3 and acceptance 1: the framework's times follow
# Cybertrain::Clock, so travel_to / travel / freeze_time move them all: a
# model's timestamps, a cache entry's expiry, a job's run_at and
# perform_in, a rate-limit window (memory store, through a controller), a
# session's stamped absolute lifetime, a signed token's expiry. Waits stay
# on the monotonic clock, so a stream read and an HTTP receiver wait end
# under freeze_time. (The idle limit lives in the generated Authentication
# concern, not here: preflight ruling R4.) One SQLite file; it links
# SQLite through FFI, so the snapshot comes from the compiled binary
# (spikes/NOTES.md rule 23).

DAY = 86_400
DB = Cybertrain::DB
Stream = Cybertrain::Stream

Cybertrain.logger = Cybertrain::Logger.new(StringIO.new)
CONFIG = Cybertrain.config
CONFIG.secret_key_base = "c" * 64
CONFIG.stream_ping_interval = 1
CONFIG.stream_poll_ms = 20

DIR = Dir.mktmpdir("cybertrain-clock-sites")
at_exit do
  Dir.children(DIR).each { |f| File.delete("#{DIR}/#{f}") }
  Dir.rmdir(DIR)
end
DB.connect("#{DIR}/clock_sites.sqlite3")
DB.with do |c|
  c.exec_script("CREATE TABLE notes (id INTEGER PRIMARY KEY AUTOINCREMENT, title TEXT NOT NULL, " \
                "created_at TEXT, updated_at TEXT);")
end
Stream.install!

# A model in the shape the generator writes (test/model.rb has the full
# one), with only what create needs.
class Note < Cybertrain::Model
  def self.table_name = "notes"
  def self.column_names = ["id", "title", "created_at", "updated_at"]
  def model_name = "Note"

  attr_accessor :title, :created_at, :updated_at

  def initialize(attrs = {})
    super()
    @title = ""
    @created_at = nil
    @updated_at = nil
    assign_attributes(attrs)
  end

  def load_row(row)
    set_id(Cybertrain::Cast.int(row["id"]))
    @title = Cybertrain::Cast.str(row["title"])
    @created_at = Cybertrain::Cast.time_or_nil(row["created_at"])
    @updated_at = Cybertrain::Cast.time_or_nil(row["updated_at"])
    mark_persisted!
    nil
  end

  def read_attribute(name)
    case name
    when :id then @id
    when :title then @title
    when :created_at then @created_at
    when :updated_at then @updated_at
    else nil
    end
  end

  def write_attribute(name, value)
    case name
    when :title then @title = Cybertrain::Cast.str(value)
    when :created_at then @created_at = Cybertrain::Cast.time_or_nil(value)
    when :updated_at then @updated_at = Cybertrain::Cast.time_or_nil(value)
    end
    nil
  end

  def assign_attributes(attrs)
    attrs.each { |k, v| write_attribute(k.to_s.to_sym, v) }
    self
  end

  def to_row
    {
      "title" => Cybertrain::Cast.to_sql(@title),
      "created_at" => Cybertrain::Cast.to_sql(@created_at),
      "updated_at" => Cybertrain::Cast.to_sql(@updated_at)
    }
  end

  def self.create(attrs = {})
    rec = Note.new(attrs)
    rec.save
    rec
  end
end

# A job registered by hand, as test/job_helpers.rb registers its jobs, and
# its perform_in in the shape gen/jobs.rb's emitter writes it.
Cybertrain::Job.register("noop") { |run| nil }

class NoopJob
  def self.perform_in(seconds)
    Cybertrain::Job.enqueue("noop", "{}", run_at: Time.current + seconds)
  end
end

def run_at_of(id)
  rows = DB.with { |c| c.execute("SELECT run_at FROM cybertrain_jobs WHERE id = ?", [id]) }
  Cybertrain::Cast.int(rows[0]["run_at"])
end

class ClockSitesController < Cybertrain::Controller
  rate_limit to: 3, within: 60, only: [:limited], store: :memory

  def whoami
    render plain: session["user"].nil? ? "anonymous" : "signed in"
  end

  # Signs in for `days` days, as the generated start_new_session_for does
  # with "remember me": restart_lifetime! first, then stamp_lifetime!.
  def sign_in
    days = Cybertrain::Cast.int(params[:days])
    session.restart_lifetime!
    session.stamp_lifetime!(days * DAY, true)
    session["user"] = "ann"
    render plain: "ok"
  end

  def limited
    render plain: "limited"
  end
end

def build_app
  router = Cybertrain::Router.new
  router.get("/whoami") { |ctx| ClockSitesController.new(ctx).process(:whoami) { |c| c.whoami } }
  router.get("/sign_in") { |ctx| ClockSitesController.new(ctx).process(:sign_in) { |c| c.sign_in } }
  router.get("/limited") { |ctx| ClockSitesController.new(ctx).process(:limited) { |c| c.limited } }
  sessions = Cybertrain::SessionStore.new(router, secret: "clock-sites-secret")
  Stream::Endpoint.new(sessions, CONFIG)
end

APP = build_app
Stream::Poller.start!(CONFIG)

def new_client
  Cybertrain::Test::Client.new(APP)
end

# A signed stream name, as a page's <turbo-stream-source> carries it.
def token
  list = Array.new(0) { "" }
  list << "clock"
  Stream.sign(list)
end

test "model timestamps follow travel_to" do
  travel_to(Time.utc(2026, 11, 1, 9)) { assert_equal Time.utc(2026, 11, 1, 9), Note.create(title: "x").created_at }
end

test "a cache entry expires after travel" do
  freeze_time
  Cybertrain::Cache.write("k", "v", expires_in: 300)
  travel 299
  assert_equal "v", Cybertrain::Cache.read("k")
  travel 2
  assert_nil Cybertrain::Cache.read("k")
end

test "a job's run_at and perform_in follow the clock" do
  travel_to(Time.at(1_000_000)) do
    assert_equal 1_000_000, run_at_of(Cybertrain::Job.enqueue("noop", "{}"))
    assert_equal 1_000_060, run_at_of(NoopJob.perform_in(60))
  end
end

test "a rate-limit window follows the clock" do
  travel_to(Time.at(5_000)) { assert_equal 5_000, Cybertrain::RateLimit.current_time }
  # Through a controller with `rate_limit to: 3, within: 60`: the 4th
  # request at t is a 429, a request at t + 61 is a 200.
  Cybertrain::RateLimit.reset_all!
  client = new_client
  freeze_time
  3.times { client.get("/limited") }
  assert_equal 429, client.get("/limited").status
  travel 61
  assert_equal 200, client.get("/limited").status
end

test "a session's absolute limit follows travel_to" do
  client = new_client
  freeze_time
  client.get("/sign_in?days=14")
  travel 13 * DAY
  assert_equal "signed in", client.get("/whoami").body
  travel 2 * DAY
  assert_equal "anonymous", client.get("/whoami").body
end

test "a signed token expires with the clock" do
  freeze_time
  token = Cybertrain::Token.issue("reset", 7, 900, "digest")
  travel 899
  assert Cybertrain::Token.valid?(token, "reset", "digest")
  travel 2
  refute Cybertrain::Token.valid?(token, "reset", "digest")
end

test "a stream read and a receiver wait do not hang under freeze_time" do
  client = new_client
  freeze_time
  started = Cybertrain::Clock.monotonic
  res = client.get_stream("/cybertrain/stream?s=#{token}", events: 1, timeout: 0.3)
  assert_equal 200, res.status
  receiver = Cybertrain::Test::HttpReceiver.new(accept_window: 0.3)
  receiver.start
  # No request comes: the wait ends.
  assert_nil receiver.received_requests(1, 0.3)[0]
  receiver.stop
  assert Cybertrain::Clock.monotonic - started < 3.0
end

Cybertrain::Test.run!
