require "cybertrain/test"
require "cybertrain/durations"
require "cybertrain/time_ext"

# `1.month` is not a duration (spec section 3.1): a month has no fixed
# length in seconds, so Integer has no `month(s)` or `year(s)`. In an
# application it builds under Spinel and raises NoMethodError when reached,
# as under CRuby: Spinel refuses an undefined instance method at build only
# while no class in the program defines that name, and an application
# always has one (Cybertrain::ZonedTime#month and #year,
# Cron::Expression#months; spikes/phase5/durations_month.rb). Billing below
# stands in for them, so this program is an application's case and not the
# bare-program refusal. CRuby 3.3 quotes the name with a
# backtick, Spinel and CRuby 3.4 with a quote: the message is compared with
# the backtick turned into a quote.

class Billing
  def month = 11
  def months = [11, 12]
  def year = 2026
end

test "1.month raises NoMethodError at run time" do
  message = assert_raises("NoMethodError") { 1.month }
  assert_equal "undefined method 'month' for an instance of Integer", message.tr("`", "'")
  assert_equal 11, Billing.new.month
  assert_equal [11, 12], Billing.new.months
  assert_equal 2026, Billing.new.year
end

test "1.year and 2.months raise it too" do
  assert_includes assert_raises("NoMethodError") { 2.months }, "months"
  assert_includes assert_raises("NoMethodError") { 1.year }, "year"
end

test "the calendar-aware forms replace them" do
  travel_to(Time.utc(2026, 3, 31, 12)) do
    assert_equal Time.utc(2026, 2, 28, 12), Time.current.months_ago(1)
    assert_equal Time.utc(2025, 3, 31, 12), Time.current.years_ago(1)
  end
end

Cybertrain::Test.run!
