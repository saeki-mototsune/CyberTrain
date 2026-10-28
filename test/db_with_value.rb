# What a Cybertrain::DB.with block computes, used after the block: an
# instance of an application class, and a Boolean used as a condition
# (issues #27 and #90, NOTES rule 77). On Spinel 2026.10.26.7019 DB.with's
# own value lost an application class once the program's DB.with blocks
# returned different types (the framework's return Arrays and Integers),
# so the class instance had to go through a local declared before the
# block; 2026.10.27.7020 carries the fix (matz/spinel#10415), and the
# block's own value is used directly too. A Boolean (a builtin value) is
# used as it comes. The whole framework is required, so those other
# DB.with blocks are in the program.
#
# It links SQLite through FFI, so it cannot run under CRuby: its snapshot
# comes from the compiled binary (spikes/NOTES.md rule 23).
require "cybertrain"
require "cybertrain/test"

USERS_SQL = "CREATE TABLE users (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, " \
            "active INTEGER NOT NULL);"

class LoginResult
  attr_reader :status

  def initialize(status)
    @status = status
  end

  def ok?
    @status == "ok"
  end
end

class Auth
  def login(conn, name)
    rows = conn.execute("SELECT active FROM users WHERE name = ?", [name])
    return LoginResult.new("unknown") if rows.empty?

    Cybertrain::Cast.int(rows[0]["active"]) == 1 ? LoginResult.new("ok") : LoginResult.new("inactive")
  end

  def active?(conn, name)
    rows = conn.execute("SELECT 1 AS one FROM users WHERE name = ? AND active = 1", [name])
    !rows.empty?
  end
end

AUTH = Auth.new

def connect_users
  Cybertrain::DB.connect(":memory:", size: 1)
  Cybertrain::DB.with do |c|
    c.exec_script(USERS_SQL)
    c.execute("INSERT INTO users (name, active) VALUES (?, ?)", ["alice", 1])
    c.execute("INSERT INTO users (name, active) VALUES (?, ?)", ["bob", 0])
  end
  nil
end

# The class instance through a typed local: the local's type comes from
# its first assignment, not from DB.with.
def login_result(name)
  result = LoginResult.new("none")
  Cybertrain::DB.with do |conn|
    result = AUTH.login(conn, name)
  end
  result
end

# The same, the object built in the block itself.
def status_of(name)
  result = LoginResult.new("none")
  Cybertrain::DB.with do |conn|
    rows = conn.execute("SELECT active FROM users WHERE name = ?", [name])
    result = LoginResult.new(rows.empty? ? "unknown" : "found")
  end
  result
end

# The class instance as the block's own value, the reporter's form: it
# raised NoMethodError on 2026.10.26.7019.
def login_result_direct(name)
  Cybertrain::DB.with do |conn|
    AUTH.login(conn, name)
  end
end

# A Boolean returned straight from the block.
def active_user?(name)
  Cybertrain::DB.with do |conn|
    AUTH.active?(conn, name)
  end
end

def active_label(name)
  if active_user?(name)
    "active"
  else
    "not active"
  end
end

test "a DB.with block's class instance, through a typed local: its methods are callable" do
  connect_users
  r = login_result("alice")
  assert r.ok?
  assert_equal "ok", r.status
  assert_equal "inactive", login_result("bob").status
  assert !login_result("carol").ok?
  assert_equal "found", status_of("bob").status
  assert_equal "unknown", status_of("carol").status
  Cybertrain::DB.disconnect
end

test "a DB.with block's class instance, as the block's own value: its methods are callable" do
  connect_users
  r = login_result_direct("alice")
  assert r.ok?
  assert_equal "ok", r.status
  assert_equal "inactive", login_result_direct("bob").status
  assert !login_result_direct("carol").ok?
  Cybertrain::DB.disconnect
end

test "a DB.with block's Boolean as a condition" do
  connect_users
  assert_equal "active", active_label("alice")
  assert_equal "not active", active_label("bob")
  assert(active_user?("alice") ? true : false)
  assert_equal "no", (active_user?("carol") ? "yes" : "no")
  count = 0
  ["alice", "bob", "carol"].each { |n| count += 1 unless active_user?(n) }
  assert_equal 2, count
  Cybertrain::DB.disconnect
end

Cybertrain::Test.run!
