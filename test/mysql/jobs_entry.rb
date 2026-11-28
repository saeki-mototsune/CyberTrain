require "stringio"
require "cybertrain/core/mysql"
require "cybertrain/jobs"
require "cybertrain/test"
require_relative "support/tables"
require_relative "support/services"

# The core with the MySQL adapter and the jobs subsystem, as an application
# that requires "cybertrain/core/mysql" and "cybertrain/jobs" is built
# (D85: a subsystem's line after the core's), against the server
# CYBERTRAIN_TEST_MYSQL_URL names (script/test-mysql runs this program):
# that it compiles and links no SQLite, and that `./NAME jobs` (Main, then
# the jobs feature's command) connects to DATABASE_URL and reads the queue
# there. test/mysql/jobs.rb has the queue's own tests.

URL = ENV.fetch("CYBERTRAIN_TEST_MYSQL_URL", "")
if URL.empty?
  puts "skipped: CYBERTRAIN_TEST_MYSQL_URL is not set (script/mysql-dev starts a server)"
  exit 2
end

Job = Cybertrain::Job
# The job lines (with their times) go to a buffer, not the snapshot.
LOG = StringIO.new
Cybertrain.logger = Cybertrain::Logger.new(LOG)
SEEN = Array.new(0) { "" }
Job.handle("record") { |payload| SEEN << payload }

def run_main(argv)
  Cybertrain::Main.run("shop", argv, router: Cybertrain::Router.new, url_resolver: ->(name, args, options) { "/" },
                                     views: { "" => "" })
end

Cybertrain.config.database_url = URL
at_exit { MySQLServices.fresh_db(URL, []) }

test "the program is built with the MySQL adapter and the jobs feature" do
  assert_equal "mysql", Cybertrain::DB::Adapter.adapter_name
  assert Cybertrain::Features.feature_loaded?("jobs")
end

test "a job enqueued on MySQL runs, and ./NAME jobs reads the queue on DATABASE_URL" do
  MySQLServices.fresh_db(URL, [])
  Job.enqueue("record", "a", run_at: Time.at(1_000))
  Job.enqueue("record", "b", run_at: Time.at(2_000_000_000))
  assert Job.work_one(1_000)
  assert_equal ["a"], SEEN
  Cybertrain::DB.disconnect
  # Main connects (a pool of one) to DB::Adapter.connect_target: the URL.
  assert_equal 0, run_main(["jobs", "list", "queued"])
  assert_equal 0, run_main(["jobs", "list", "done"])
end

test "./NAME jobs without DATABASE_URL stops before it connects" do
  Cybertrain.config.database_url = ""
  assert_equal 1, run_main(["jobs", "list", "queued"])
  Cybertrain.config.database_url = URL
end

Cybertrain::Test.run!
