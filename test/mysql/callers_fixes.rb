require "stringio"
require "cybertrain/db/base"
require "cybertrain/db/mysql"
require "cybertrain/config"
require "cybertrain/console"
require "cybertrain/job"
require "cybertrain/jobs_page"
require "cybertrain/stream"
require "cybertrain/middleware/health_check"
require "cybertrain/test"
require_relative "support/tables"
require_relative "support/services"

# MySQL answers of the database layer's callers that the review of the
# MySQL adapter found wrong, against the server CYBERTRAIN_TEST_MYSQL_URL
# names (script/test-mysql runs this program): the console's find and
# find_by (a derived table needs an alias on MySQL), JobsPage.discard_job's
# updated_at (MySQL evaluates SET left to right), Stream.prune beside a
# broadcast in an open transaction (it must not wait for that row's lock),
# a job claim asked again once its lock is held, the health check's
# query, and Model#insert_row on a table whose id is no AUTO_INCREMENT.

DB = Cybertrain::DB
Job = Cybertrain::Job
Stream = Cybertrain::Stream

Cybertrain.config.secret_key_base = "s" * 64
Cybertrain.logger = Cybertrain::Logger.new(StringIO.new)

URL = ENV.fetch("CYBERTRAIN_TEST_MYSQL_URL", "")
if URL.empty?
  puts "skipped: CYBERTRAIN_TEST_MYSQL_URL is not set (script/mysql-dev starts a server)"
  exit 2
end

OWN_TABLES = ["cf_articles"].freeze

def fresh_db
  MySQLServices.fresh_db(URL, OWN_TABLES)
  nil
end

SEEN = Array.new(0) { "" }
Job.handle("record") { |payload| SEEN << payload }

# ---- the console --------------------------------------------------------

# One model of the shape gen/models emits (test/console.rb's Article).
class CfArticleRelation < Cybertrain::Relation
  def where(h) = (add_where(h); self)

  def to_a
    out = Array.new(0) { CfArticle.new }
    found = rows
    i = 0
    while i < found.size
      out << CfArticle.from_row(found[i])
      i += 1
    end
    out
  end
end

class CfArticle < Cybertrain::Model
  def self.table_name = "cf_articles"
  def self.column_names = ["id", "title"]
  def model_name = "CfArticle"

  attr_accessor :title

  def initialize(attrs = {})
    super()
    @title = ""
    assign_attributes(attrs) unless attrs.empty?
  end

  def self.from_row(row)
    rec = CfArticle.new(Cybertrain::Model::NO_ATTRIBUTES)
    rec.load_row(row)
    rec
  end

  def load_row(row)
    set_id(Cybertrain::Cast.int(row["id"]))
    @title = Cybertrain::Cast.str(row["title"])
    mark_persisted!
    nil
  end

  def read_attribute(name)
    case name
    when :id then @id
    when :title then @title
    else nil
    end
  end

  def write_attribute(name, value)
    case name
    when :title then @title = Cybertrain::Cast.str(value)
    end
    nil
  end

  def assign_attributes(attrs)
    attrs.each { |k, v| write_attribute(k.to_s.to_sym, v) }
    self
  end

  def to_row
    { "title" => Cybertrain::Cast.to_sql(@title) }
  end

  def self.all = CfArticleRelation.new("cf_articles")

  def self.create(attrs = {})
    rec = CfArticle.new(attrs)
    rec.save
    rec
  end
end

def console_scope(name)
  case name
  when "CfArticle" then CfArticle.all
  else Cybertrain::Console.unknown_model(name)
  end
end

def console_records(relation)
  case relation
  when CfArticleRelation then relation.to_a
  else Cybertrain::Console.no_records(relation)
  end
end

def console_create(name, attrs)
  case name
  when "CfArticle" then CfArticle.create(attrs)
  else Cybertrain::Console.unknown_record(name)
  end
end

def scope_lambda = ->(name) { console_scope(name) }
def records_lambda = ->(relation) { console_records(relation) }
def create_lambda = ->(name, attrs) { console_create(name, attrs) }

Cybertrain::Console.scope_builder = scope_lambda
Cybertrain::Console.records_builder = records_lambda
Cybertrain::Console.create_builder = create_lambda
Cybertrain::Console.model_names = ["CfArticle"]

BANNER = "Cybertrain console (test). Type help for commands, exit to quit.\n"

def session(lines)
  config = Cybertrain::Config.new
  config.env = "test"
  output = StringIO.new
  status = Cybertrain::Console.run(StringIO.new(lines), output, config)
  "#{status}|#{output.string}"
end

test "the console's find and find_by answer on MySQL" do
  fresh_db
  DB.with { |c| c.exec_script("CREATE TABLE cf_articles (id BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY, title VARCHAR(255) NOT NULL)") }
  CfArticle.create(title: "first")
  CfArticle.create(title: "second")
  lines = +""
  lines << "CfArticle.find(2).title\n"
  lines << "CfArticle.find_by(title: \"first\").id\n"
  lines << "CfArticle.where(title: \"second\").find_by(title: \"first\")\n"
  lines << "CfArticle.find(9)\n"
  expected = +"0|"
  expected << BANNER
  expected << ">> \"second\"\n"
  expected << ">> 1\n"
  expected << ">> nil\n"
  expected << ">> Cybertrain::RecordNotFound: Couldn't find CfArticle with id=9\n"
  expected << ">> \n"
  assert_equal expected, session(lines)
end

# ---- the jobs page --------------------------------------------------------

def job_updated_at(id)
  rows = DB.with { |c| c.execute("SELECT updated_at FROM cybertrain_jobs WHERE id = ?", [id]) }
  Cybertrain::Cast.int(rows[0]["updated_at"])
end

test "discard_job stamps a failed job's updated_at, and keeps a discarded one's" do
  fresh_db
  id = Job.enqueue("record", "x", run_at: Time.at(1000))
  DB.with { |c| c.execute("UPDATE cybertrain_jobs SET state = 'failed', updated_at = 1000 WHERE id = ?", [id]) }
  assert Cybertrain::JobsPage.discard_job(id)
  stamped = job_updated_at(id)
  assert stamped > 1000
  DB.with { |c| c.execute("UPDATE cybertrain_jobs SET updated_at = 2000 WHERE id = ?", [id]) }
  assert Cybertrain::JobsPage.discard_job(id)
  assert_equal 2000, job_updated_at(id)
end

# ---- Stream.prune ---------------------------------------------------------

def message_ids
  rows = DB.with { |c| c.execute("SELECT id FROM cybertrain_messages ORDER BY id") }
  rows.map { |r| Cybertrain::Cast.int(r["id"]).to_s }.join(",")
end

# A broadcast kept open in a transaction on a connection of its own: the
# prune, on the pool's, deletes the old rows at once instead of waiting for
# the open row's lock (innodb_lock_wait_timeout, 50 seconds by default:
# the poller, which prunes, would deliver nothing meanwhile). The pool's
# two connections wait one second for a lock here, so the old answer fails
# fast (DB::LockTimeout); the other connection is closed whatever happens,
# which rolls its transaction back.
def prune_beside_open_broadcast
  holder = DB::Connection.new(URL)
  count = 0
  begin
    holder.begin!
    holder.execute("INSERT INTO cybertrain_messages (stream, payload, created_at) VALUES ('a', 'open', 5000)")
    DB.with do |a|
      a.execute("SET SESSION innodb_lock_wait_timeout = 1")
      DB.with { |b| b.execute("SET SESSION innodb_lock_wait_timeout = 1") }
    end
    count = Stream.prune(1000)
    holder.commit!
  ensure
    holder.close
  end
  count
end

test "Stream.prune does not wait for a broadcast in an open transaction" do
  fresh_db
  Stream.install!
  DB.with do |c|
    c.execute("INSERT INTO cybertrain_messages (stream, payload, created_at) VALUES ('a', 'old', 100)")
    c.execute("INSERT INTO cybertrain_messages (stream, payload, created_at) VALUES ('a', 'old', 100)")
  end
  assert_equal 2, prune_beside_open_broadcast
  assert_equal "3", message_ids
  # Nothing old is left: nothing to delete.
  assert_equal 0, Stream.prune(1000)
end

# ---- the job claim --------------------------------------------------------

# What the claim on the other thread answered (a constant: NOTES rule 64).
CLAIMED = Array.new(0) { 0 }

def claim_on_thread(generation)
  Thread.new { CLAIMED << Job::Store.claim(2000, "host-b:1:1", generation).run_id }
end

# The worker is stopped while a claim waits for a row lock another
# connection holds: once the lock is free the claim, asked again under it,
# takes nothing (SQLite asks under its write lock at BEGIN IMMEDIATE; on
# MySQL BEGIN takes no lock, and the wait is at the claim's SELECT).
test "a claim that waited for its lock is asked again before it takes the row" do
  fresh_db
  id = Job.enqueue("record", "late", run_at: Time.at(1000))
  config = Cybertrain::Config.new
  config.job_threads = 0
  assert Job::Worker.start!(config)
  generation = 1
  generation += 1 until Job::Worker.pool_live?(generation) || generation > 100
  holder = DB::Connection.new(URL)
  holder.begin!
  holder.execute("SELECT id FROM cybertrain_jobs WHERE id = ? FOR UPDATE", [id])
  claimer = claim_on_thread(generation)
  sleep 0.3
  waited = CLAIMED.empty?
  Job::Worker.request_stop
  holder.commit!
  claimer.join
  Job::Worker.stop!
  holder.close
  assert waited
  assert_equal [-1], CLAIMED
  assert_equal 1, Job.state_count("queued")
end

# ---- the health check -----------------------------------------------------

test "the health check's database query answers on MySQL" do
  fresh_db
  assert Cybertrain::HealthCheck.database_ok?
end

# ---- Model#insert_row's id -------------------------------------------------

def cf_count
  rows = DB.with { |c| c.execute("SELECT COUNT(*) AS n FROM cf_articles") }
  Cybertrain::Cast.int(rows[0]["n"])
end

test "a record whose INSERT generates no id does not take the connection's earlier id" do
  fresh_db
  # One connection, so the broadcast's INSERT and the record's share it.
  DB.connect(URL, size: 1)
  DB.with do |c|
    c.exec_script("CREATE TABLE cf_articles (id BIGINT UNSIGNED NOT NULL DEFAULT (UUID_SHORT()) PRIMARY KEY, " \
                  "title VARCHAR(255) NOT NULL)")
  end
  assert_equal 1, Stream.broadcast("s", "x")
  # The id is the column's default expression, not an AUTO_INCREMENT
  # value: the OK packet reports insert id 0, and the record must not keep
  # the broadcast's 1 (an update would then write WHERE id = 1).
  rec = CfArticle.create(title: "a")
  assert_equal 0, rec.id
  assert_equal 1, cf_count
  # An AUTO_INCREMENT table on the same connection still answers its id.
  DB.with { |c| c.exec_script("DROP TABLE cf_articles") }
  DB.with { |c| c.exec_script("CREATE TABLE cf_articles (id BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY, title VARCHAR(255) NOT NULL)") }
  assert_equal 1, CfArticle.create(title: "b").id
end

Cybertrain::Test.run!
