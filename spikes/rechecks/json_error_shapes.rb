# Reduced shapes only: NOTES 33, 48 and 61. Not the framework's own
# `rescue_from`, and not the superclass walk of NOTES status 54.
require "json"

# 33/61: `rescue StandardError` and a bare `rescue` against JSON's errors.
begin
  JSON.parse("{")
rescue StandardError => e
  puts "caught by StandardError: " + e.class.name
end
begin
  JSON.parse("[1,")
rescue => e
  puts "caught by bare rescue: " + e.class.name
end
deep = []
cur = deep
150.times { n = []; cur << n; cur = n }
begin
  JSON.generate(deep)
  puts "no error"
rescue StandardError => e
  puts "generate caught by StandardError: " + e.class.name
end

# 48: `JSON::ParserError` as a value, in a `rescue`, and passed to a
# registering class method in a class body.
klass = JSON::ParserError
puts klass.name
puts JSON::ParserError.ancestors.include?(StandardError)
begin
  JSON.parse("nope")
rescue klass => e
  puts "rescued via value"
end
is_standard = begin; JSON.parse("{"); rescue JSON::ParserError => e; e.is_a?(StandardError); end
puts is_standard
class Handler
  attr_reader :class_name
  def initialize(k); @class_name = k.name; end
end
class Ctl
  @handlers = [Handler.new(StandardError)]
  @handlers.clear
  def self.rescue_from(klass); @handlers << Handler.new(klass); end
  def self.handlers = @handlers
  rescue_from(JSON::ParserError)
  rescue_from(ArgumentError)
  rescue_from(JSON::NestingError)
end
begin
  JSON.parse("{")
rescue JSON::NestingError, JSON::ParserError, StandardError => e
  Ctl.handlers.each { |h| puts "handler for " + h.class_name if h.class_name == e.class.name }
end
puts Ctl.handlers.size
