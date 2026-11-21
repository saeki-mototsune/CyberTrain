# NOTES 48: `rescue_from JSON::ParserError` on the framework's own
# Controller, with a block and with `with:`, and the same error with no
# handler registered.
#
# Needs the framework on the load path, so from the repository root:
#   spinel --strict-require -I . spikes/rechecks/differing/rescue_from_json_error.rb -O 0 -o "$TMPDIR/rescue_from_json" && "$TMPDIR/rescue_from_json"
#
# Linux x86_64, Spinel 2026.11.04.7026 (a2d06115, GCC 13.3.0), 2026-11-20,
# compiled:
#   block handler: 422 bad json: JSON::ParserError
#   no error: 200 fine
#   with handler: 400 with: JSON::ParserError
#   unhandled: re-raised JSON::ParserError
#   value: JSON::ParserError
#
# Only the compiled side was run: cybertrain/controller loads the SQLite FFI
# bindings, which CRuby cannot load without the preview's shim. The lines
# above are what the program is written to print, so this file is here for
# needing the framework, not for differing. It is one program with three
# small controllers, not an application: each handler is found by the
# class's name in Controller#rescue_with_handler.
require "stringio"
require "json"
require "cybertrain/controller"
require "cybertrain/router"
require "cybertrain/app"

# Keep the error log off the output.
Cybertrain.logger = Cybertrain::Logger.new(StringIO.new)

class ParseController < Cybertrain::Controller
  rescue_from(JSON::ParserError) { |c, e| c.render plain: "bad json: #{e.class.name}", status: 422 }

  def broken
    JSON.parse("{")
    render plain: "parsed"
  end

  def fine
    render plain: "fine"
  end
end

class NamedController < Cybertrain::Controller
  rescue_from JSON::ParserError, with: :bad_json

  def broken
    JSON.parse("[1,")
    render plain: "parsed"
  end

  def bad_json
    render plain: "with: #{rescued_exception.class.name}", status: 400
  end

  def run_callback(name)
    case name
    when :bad_json then bad_json
    else super
    end
  end
end

class PlainController < Cybertrain::Controller
  def broken
    JSON.parse("{")
    render plain: "parsed"
  end
end

def ctx
  Cybertrain::Context.new(Cybertrain::Request.new("GET", "/x", { "host" => "example.test" }, ""))
end

c = ParseController.new(ctx)
c.process(:broken) { |x| x.broken }
puts "block handler: #{c.response.status} #{c.response.body}"
c = ParseController.new(ctx)
c.process(:fine) { |x| x.fine }
puts "no error: #{c.response.status} #{c.response.body}"
c = NamedController.new(ctx)
c.process(:broken) { |x| x.broken }
puts "with handler: #{c.response.status} #{c.response.body}"
c = PlainController.new(ctx)
begin
  c.process(:broken) { |x| x.broken }
  puts "unhandled: not raised"
rescue StandardError => e
  puts "unhandled: re-raised #{e.class.name}"
end
klass = JSON::ParserError
puts "value: #{klass.name}"
