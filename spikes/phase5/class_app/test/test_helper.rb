ENV["CYBERTRAIN_ENV"] ||= "test"
require_relative "../config/app"
# `require "cybertrain/test_help"` in the real file (Task 6); the spike's
# stand-in has another name so it never shadows that file.
require "standins/test_case"

class ActiveSupport::TestCase
  fixtures :all

  # Helper methods used by all tests go here.
  def title_upcased(article) = article.title.upcase
end

# An application base class with setup / teardown overrides, instance
# variables and a private helper.
class ApplicationIntegrationTest < ActionDispatch::IntegrationTest
  def setup
    super
    @user = users(:alice)
    @trail = Array.new(0) { "" }
    note("setup")
    nil
  end

  def teardown
    note("teardown")
    TRAIL << @trail.join(",")
    super
    nil
  end

  private

  def note(step)
    @trail << step
    nil
  end
end

TRAIL = Array.new(0) { "" }
