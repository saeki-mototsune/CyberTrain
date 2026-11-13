ENV["CYBERTRAIN_ENV"] ||= "test"
require_relative "../config/app"
require "cybertrain/test_help"

class ActiveSupport::TestCase
  fixtures :all

  # Helper methods used by all tests go here.
end

require_relative "support/session_test_helper"

class ActionDispatch::IntegrationTest
  include SessionTestHelper
end

# The blog's own helpers (form tokens, job rows, broadcasts), called as
# BlogTestHelper.form_token(response.body) and so on.
require_relative "support/blog_test_helper"
