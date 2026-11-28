require "stringio"
require "cybertrain/db"
require "cybertrain/test"
require "cybertrain/config"
require "cybertrain/controller"

# Answers of the database layer's callers that the review of the MySQL
# adapter found wrong, on either adapter: a `rescue_from` of a DB::Error
# subclass is not shadowed by one of Cybertrain::DB::Error declared before
# it, and DATABASE_URL is read without the newline a secrets file leaves.
# The controller pulls in the SQLite FFI bindings, so the snapshot comes
# from the compiled binary (spikes/NOTES.md rule 23).

Cybertrain.logger = Cybertrain::Logger.new(StringIO.new)

# The general handler first, then the special case: the natural order.
class GeneralFirstController < Cybertrain::Controller
  rescue_from(Cybertrain::DB::Error) { |c, e| c.render plain: "database: #{e.class.name}", status: 500 }
  rescue_from(Cybertrain::DB::UniqueViolation) { |c, e| c.render plain: "duplicate", status: 422 }

  def unique
    raise Cybertrain::DB::UniqueViolation, "UNIQUE constraint failed: users.email"
  end

  def deadlock
    raise Cybertrain::DB::Deadlock, "deadlock"
  end
end

# The special case first.
class SpecialFirstController < Cybertrain::Controller
  rescue_from(Cybertrain::DB::UniqueViolation) { |c, e| c.render plain: "duplicate", status: 422 }
  rescue_from(Cybertrain::DB::Error) { |c, e| c.render plain: "database: #{e.class.name}", status: 500 }

  def unique
    raise Cybertrain::DB::UniqueViolation, "UNIQUE constraint failed: users.email"
  end

  def deadlock
    raise Cybertrain::DB::Deadlock, "deadlock"
  end
end

# A subclass whose own general handler meets its parent's special one: the
# exact class still wins.
class InheritingController < SpecialFirstController
  rescue_from(Cybertrain::DB::Error) { |c, e| c.render plain: "child database: #{e.class.name}", status: 503 }
end

def ctx
  Cybertrain::Context.new(Cybertrain::Request.new("GET", "/", { "host" => "example.test" }, ""))
end

def answer(controller, action)
  case action
  when :unique then controller.process(:unique) { |x| x.unique }
  else controller.process(:deadlock) { |x| x.deadlock }
  end
  "#{controller.response.status} #{controller.response.body}"
end

test "rescue_from of a DB::Error subclass wins over Cybertrain::DB::Error declared before it" do
  assert_equal "422 duplicate", answer(GeneralFirstController.new(ctx), :unique)
  assert_equal "500 database: Cybertrain::DB::Deadlock", answer(GeneralFirstController.new(ctx), :deadlock)
end

test "rescue_from of a DB::Error subclass declared first still wins" do
  assert_equal "422 duplicate", answer(SpecialFirstController.new(ctx), :unique)
  assert_equal "500 database: Cybertrain::DB::Deadlock", answer(SpecialFirstController.new(ctx), :deadlock)
end

test "an inherited exact rescue_from wins over the subclass's Cybertrain::DB::Error" do
  assert_equal "422 duplicate", answer(InheritingController.new(ctx), :unique)
  assert_equal "503 child database: Cybertrain::DB::Deadlock", answer(InheritingController.new(ctx), :deadlock)
end

test "DATABASE_URL is read without surrounding white space" do
  ENV["DATABASE_URL"] = "mysql://app@db.internal/shop_production\n"
  assert_equal "mysql://app@db.internal/shop_production", Cybertrain::Config.new.database_url
  ENV["DATABASE_URL"] = " mysql://app@db.internal/shop "
  assert_equal "mysql://app@db.internal/shop", Cybertrain::Config.new.database_url
  ENV.delete("DATABASE_URL")
  assert_equal "", Cybertrain::Config.new.database_url
end

Cybertrain::Test.run!
