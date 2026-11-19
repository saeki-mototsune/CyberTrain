# Reduced shapes only: NOTES 61, beyond what json_error_shapes.rb has. The
# NestingError that `JSON.generate` raises for a document 150 levels deep,
# against three rescue clauses that do not name it, and on a Thread whose
# `ensure` must run. The document is built in Ruby: how deep `JSON.parse`
# accepts differs between the runtimes (101 levels raise under CRuby, 201
# were accepted compiled) and is not part of this program. Not the
# framework's request thread, where the rule was seen.
require "json"

def deep_document
  top = []
  cur = top
  150.times do
    inner = []
    cur << inner
    cur = inner
  end
  top
end

def parser_error_then_standard(doc)
  JSON.generate(doc)
rescue JSON::ParserError, StandardError => e
  "ParserError, StandardError: #{e.class.name}"
end

def standard_alone(doc)
  JSON.generate(doc)
rescue StandardError => e
  "StandardError alone: #{e.class.name}"
end

def parser_error_alone(doc)
  JSON.generate(doc)
rescue JSON::ParserError => e
  "ParserError alone: #{e.class.name}"
end

def on_a_thread(doc)
  Thread.new do
    begin
      JSON.generate(doc)
      puts "thread: no error"
    rescue StandardError => e
      puts "thread: #{e.class.name}"
    ensure
      puts "thread: ensure ran"
    end
  end
end

doc = deep_document
puts parser_error_then_standard(doc)
puts standard_alone(doc)
puts parser_error_alone(doc)
on_a_thread(doc).join
