require "cybertrain/http/query"
require "cybertrain/http/multipart"
require "cybertrain/http/request"
require "cybertrain/http/client_error"
require "cybertrain/context"
require "cybertrain/test"

# ClientError decides on the full class NAME, so an app's own class that
# shares the last part of a framework fault's name is still the app's 500.

module Billing
  class Invalid < StandardError
  end
end

module Other
  class QueryMalformed < StandardError
  end

  class ParameterMissing < StandardError
  end
end

test "every query fault and ParameterMissing is a 400" do
  assert_equal 400, Cybertrain::ClientError.status_for(Cybertrain::QueryTooMany.new("x"))
  assert_equal 400, Cybertrain::ClientError.status_for(Cybertrain::QueryTooDeep.new("x"))
  assert_equal 400, Cybertrain::ClientError.status_for(Cybertrain::QueryLimitExceeded.new("x"))
  assert_equal 400, Cybertrain::ClientError.status_for(Cybertrain::QueryInvalid.new("x"))
  assert_equal 400, Cybertrain::ClientError.status_for(Cybertrain::QueryMalformed.new("x"))
  assert_equal 400, Cybertrain::ClientError.status_for(Cybertrain::Params::ParameterMissing.new("x"))
end

test "an app or library exception that shares a bare name is the app's fault (500)" do
  assert_equal 500, Cybertrain::ClientError.status_for(Billing::Invalid.new("x"))
  assert_equal 500, Cybertrain::ClientError.status_for(Other::QueryMalformed.new("x"))
  assert_equal 500, Cybertrain::ClientError.status_for(Other::ParameterMissing.new("x"))
end

test "status of the framework's own exceptions" do
  assert_equal 400, Cybertrain::ClientError.status_for(Cybertrain::QueryTooMany.new("x"))
  assert_equal 400, Cybertrain::ClientError.status_for(Cybertrain::QueryMalformed.new("x"))
  assert_equal 400, Cybertrain::ClientError.status_for(Cybertrain::Params::ParameterMissing.new("x"))
  assert_equal 400, Cybertrain::ClientError.status_for(Cybertrain::BodyUndecodable.new("x"))
  assert_equal 400, Cybertrain::ClientError.status_for(Cybertrain::BodyTooLarge.new("x"))
  assert_equal 500, Cybertrain::ClientError.status_for(ArgumentError.new("x"))
end

test "the multipart faults are listed as client faults" do
  names = ["MultipartMalformed", "MultipartTooManyParts", "MultipartPartTooLarge", "MultipartHeaderTooLarge"]
  names.each do |bare|
    assert Cybertrain::ClientError::CLIENT_FAULTS.include?("Cybertrain::#{bare}")
  end
end

test "status of the multipart exceptions the parser raises" do
  assert_equal 400, Cybertrain::ClientError.status_for(Cybertrain::MultipartMalformed.new("x"))
  assert_equal 400, Cybertrain::ClientError.status_for(Cybertrain::MultipartTooManyParts.new("x"))
  assert_equal 400, Cybertrain::ClientError.status_for(Cybertrain::MultipartPartTooLarge.new("x"))
  assert_equal 400, Cybertrain::ClientError.status_for(Cybertrain::MultipartHeaderTooLarge.new("x"))
end

# Records what classify logs, and at which level.
class RecordingLogger
  attr_reader :infos, :errors

  def initialize
    @infos = Array.new(0) { "" }
    @errors = Array.new(0) { "" }
  end

  def info(message)
    @infos << message
    nil
  end

  def error(message)
    @errors << message
    nil
  end
end

# classify is called from a rescue clause, as every error path calls it: an
# exception built with .new and never raised has no #message under Spinel
# (NoMethodError; NOTES rule 53), so the test raises and rescues too.
def classify_raised_client_fault(logger)
  raise Cybertrain::QueryTooMany, "too many parameters (limit 4096)"
rescue Cybertrain::QueryTooMany => e
  Cybertrain::ClientError.classify(e, logger)
end

def classify_raised_argument_error(logger)
  raise ArgumentError, "x"
rescue ArgumentError => e
  Cybertrain::ClientError.classify(e, logger)
end

def classify_raised_multipart_fault(logger)
  raise Cybertrain::MultipartPartTooLarge, "uploaded file too large (limit 10 bytes)"
rescue Cybertrain::MultipartPartTooLarge => e
  Cybertrain::ClientError.classify(e, logger)
end

test "a raised multipart fault is a 400 at info level, with its message" do
  logger = RecordingLogger.new
  assert_equal 400, classify_raised_multipart_fault(logger)
  assert_equal 1, logger.infos.length
  assert_equal 0, logger.errors.length
  assert logger.infos[0].include?("uploaded file too large (limit 10 bytes)"), "the message is logged"
end

test "a client fault is classified as a 400 at info level, an ArgumentError as a 500 at error" do
  logger = RecordingLogger.new
  assert_equal 400, classify_raised_client_fault(logger)
  assert_equal 1, logger.infos.length
  assert_equal 0, logger.errors.length
  assert logger.infos[0].include?("400"), "logged as the 400"
  assert_equal 500, classify_raised_argument_error(logger)
  assert_equal 1, logger.errors.length
end

Cybertrain::Test.run!
