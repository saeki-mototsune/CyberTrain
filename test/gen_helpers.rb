require "tmpdir"
require "cybertrain/test"
require "cybertrain/generator/helper_scan"
require "cybertrain/generator/helpers_emitter"

# Gen::HelperScan reads app/helpers lexically; Gen::HelpersEmitter writes
# gen/helpers.rb from what it found. Text only: CRuby-portable.
PRICES = <<~'RUBY'
  module PricesHelper
    def price(value, unit: "USD", precision: 2)
      Cybertrain::Html.escape("#{value} #{unit}")
    end

    def self.not_a_helper(x)
      x
    end

    def badge(text, kind = "info", &block)
      "#{kind}: #{text} #{yield}"
    end

    def today = "now"

    private

    def hidden(x)
      x
    end
  end
RUBY

def scan(source, file = "app/helpers/prices_helper.rb")
  Cybertrain::Gen::HelperScan.scan_source(file, source)
end

def scan_error(source, file = "app/helpers/x.rb")
  msg = ""
  begin
    scan(source, file)
  rescue Cybertrain::Gen::HelperScan::Error => e
    msg = e.message
  end
  msg
end

test "the scan finds the module, its public defs and their parameters" do
  mods = scan(PRICES)
  assert_equal 1, mods.size
  assert_equal "PricesHelper", mods[0].name
  assert_equal ["price", "badge", "today"], mods[0].defs.map { |d| d.name }
  price = mods[0].defs[0]
  assert_equal ["value"], price.required
  assert_equal [], price.optional
  assert_equal [], price.keywords_required
  assert_equal ["unit", "precision"], price.keywords_optional
  assert_equal "", price.block
  badge = mods[0].defs[1]
  assert_equal ["text"], badge.required
  assert_equal ["kind"], badge.optional
  assert_equal "block", badge.block
  assert_equal 10, badge.line
end

test "keyword arguments with defaults count as optional, bare ones as required" do
  d = scan("module A\n  def f(a, b:, c: { x: 1 }, d: [1, 2])\n  end\nend\n")[0].defs[0]
  assert_equal ["b"], d.keywords_required
  assert_equal ["c", "d"], d.keywords_optional
end

test "a parameter list over several lines is joined" do
  d = scan("module A\n  def f(a,\n        b: 1)\n    a\n  end\nend\n")[0].defs[0]
  assert_equal ["a"], d.required
  assert_equal ["b"], d.keywords_optional
end

test "splats, ... and anonymous parameters are errors naming the file and line" do
  src = "module X\n  # rest\n  def a(*rest)\n  end\nend\n"
  assert_equal "app/helpers/x.rb:3: helper parameters must be named; templates pass values by position or keyword", scan_error(src)
  assert_includes scan_error("module X\n  def a(**opts)\n  end\nend\n"), "x.rb:2: helper parameters must be named"
  assert_includes scan_error("module X\n  def a(...)\n  end\nend\n"), "helper parameters must be named"
  assert_includes scan_error("module X\n  def a(&)\n  end\nend\n"), "helper parameters must be named"
end

test "more than three optional parameters asks to split the helper" do
  msg = scan_error("module X\n  def a(b = 1, c: 2, d: 3, e: 4)\n  end\nend\n")
  assert_equal "app/helpers/x.rb:2: 'a' has 4 optional parameters (at most 3: each one doubles the dispatch); split it into two helpers", msg
end

test "the same helper in two modules is an error naming both files" do
  dir = Dir.mktmpdir("cybertrain-gen-helpers")
  File.write("#{dir}/a_helper.rb", "module AHelper\n  def shout(x)\n  end\nend\n")
  File.write("#{dir}/b_helper.rb", "module BHelper\n\n  def shout(x)\n  end\nend\n")
  msg = ""
  begin
    Cybertrain::Gen::HelperScan.scan_dir(dir)
  rescue Cybertrain::Gen::HelperScan::Error => e
    msg = e.message
  end
  File.delete("#{dir}/a_helper.rb")
  File.delete("#{dir}/b_helper.rb")
  Dir.rmdir(dir)
  assert_equal "helper 'shout' is defined twice: #{dir}/a_helper.rb:2 and #{dir}/b_helper.rb:3", msg
end

test "nested modules are named in full and a wrapper module is left out" do
  mods = scan("module Admin\n  module UsersHelper\n    def role(user)\n    end\n  end\nend\n")
  assert_equal ["Admin::UsersHelper"], mods.map { |m| m.name }
  assert_equal ["role"], mods[0].defs.map { |d| d.name }
end

test "a nested class's methods are not helpers" do
  mods = scan("module A\n  class Box\n    def inner(x)\n    end\n  end\n\n  def outer\n  end\nend\n")
  assert_equal ["outer"], mods[0].defs.map { |d| d.name }
end

test "a name the framework's helpers use is an error naming the file and line" do
  assert_equal "app/helpers/x.rb:2: 'truncate' is a name the framework's template helpers already use; pick another helper name",
               scan_error("module X\n  def truncate(text)\n  end\nend\n")
  assert_includes scan_error("module X\n  def params\n  end\nend\n"), "x.rb:2: 'params' is a name"
  assert_includes scan_error("module X\n  def route(x)\n  end\nend\n"), "'route' is a name"
  assert_includes scan_error("module X\n  def escape(x) = x\nend\n"), "'escape' is a name"
  assert_includes scan_error("module X\n  def tag(x)\n  end\nend\n"), "'tag' is a name"
end

test "a name ending in _path or _url is an error" do
  assert_equal "app/helpers/x.rb:2: 'home_path' ends in _path or _url, which the route helpers answer; pick another helper name",
               scan_error("module X\n  def home_path\n  end\nend\n")
  assert_includes scan_error("module X\n  def home_url\n  end\nend\n"), "x.rb:2: 'home_url' ends in _path or _url"
end

test "a setter is not a helper" do
  mods = scan("module A\n  def value=(v)\n    @v = v\n  end\n\n  def value(x) = x\nend\n")
  assert_equal ["value"], mods[0].defs.map { |d| d.name }
  assert_equal ["x"], mods[0].defs[0].required
end

test "class << self without spaces is skipped" do
  mods = scan("module A\n  class<<self\n    def hidden(x)\n    end\n  end\n\n  def shown\n  end\nend\n")
  assert_equal ["shown"], mods[0].defs.map { |d| d.name }
end

test "a module inside a top-level class is not a helper module" do
  assert_equal [], scan("class Foo\n  module Bar\n    def baz\n    end\n  end\nend\n").map { |m| m.name }
  assert_equal ["After"], scan("class Foo\n  module Bar\n  end\nend\nmodule After\nend\n").map { |m| m.name }
end

test "an unindented module body keeps its later defs" do
  mods = scan("module A\ndef one(x)\n  x\nend\ndef two\nend\nprivate\ndef three\nend\nend\nmodule B\nend\n")
  assert_equal ["A", "B"], mods.map { |m| m.name }
  assert_equal ["one", "two"], mods[0].defs.map { |d| d.name }
end

test "a def body's lines are not read as defs or private" do
  mods = scan("module A\n  def one\n    private\n    def inner(x)\n    end\n  end\n\n  def two\n  end\nend\n")
  assert_equal ["one", "two"], mods[0].defs.map { |d| d.name }
end

EXPECTED_PRICES = <<~'RUBY'
  # Generated by `spin run gen` from app/helpers. Do not edit.
  class ApplicationHelpers < Cybertrain::Template::Helpers
    include ::Gen::UrlHelpers
    include ::PricesHelper
    include ::EmptyHelper

    def app_helper_call(name, args, kwargs, block, interp, env)
      case name
      when "price"
        helper_arity!(name, args, 1, 1)
        helper_keywords!(name, kwargs, ["unit", "precision"], 0)
        if kwargs.key?("unit") && kwargs.key?("precision") then price(args[0], unit: kwargs["unit"], precision: kwargs["precision"])
        elsif kwargs.key?("unit") then price(args[0], unit: kwargs["unit"])
        elsif kwargs.key?("precision") then price(args[0], precision: kwargs["precision"])
        else price(args[0])
        end
      when "badge"
        helper_arity!(name, args, 1, 2)
        helper_no_keywords!(name, kwargs)
        if args.size >= 2 then badge(args[0], args[1]) { app_block_content(block, interp, env) }
        else badge(args[0]) { app_block_content(block, interp, env) }
        end
      when "today"
        helper_arity!(name, args, 0, 0)
        helper_no_keywords!(name, kwargs)
        today
      when "label"
        helper_arity!(name, args, 0, 0)
        helper_keywords!(name, kwargs, ["target", "text"], 1)
        if kwargs.key?("text") then label(target: kwargs["target"], text: kwargs["text"])
        else label(target: kwargs["target"])
        end
      else super(name, args, kwargs, block, interp, env)
      end
    end
  end

  Cybertrain::Views.helpers_builder = ->(controller) { ApplicationHelpers.new(controller) }
RUBY

test "the emitter writes one arm per helper, one branch per optional subset" do
  mods = scan(PRICES)
  mods[0].defs << scan("module L\n  def label(target:, text: \"\")\n  end\nend\n")[0].defs[0]
  mods << scan("module EmptyHelper\nend\n", "app/helpers/empty_helper.rb")[0]
  assert_equal EXPECTED_PRICES, Cybertrain::Gen::HelpersEmitter.emit(mods)
end

test "a tree with no app/helpers gets a class that only calls super" do
  mods = Cybertrain::Gen::HelperScan.scan_dir("/nonexistent/app/helpers")
  assert_equal <<~'RUBY', Cybertrain::Gen::HelpersEmitter.emit(mods)
    # Generated by `spin run gen` from app/helpers. Do not edit.
    class ApplicationHelpers < Cybertrain::Template::Helpers
      include ::Gen::UrlHelpers

      def app_helper_call(name, args, kwargs, block, interp, env)
        super(name, args, kwargs, block, interp, env)
      end
    end

    Cybertrain::Views.helpers_builder = ->(controller) { ApplicationHelpers.new(controller) }
  RUBY
end

test "the output ends with the helpers_builder line" do
  assert Cybertrain::Gen::HelpersEmitter.emit(scan(PRICES)).end_with?("Cybertrain::Views.helpers_builder = ->(controller) { ApplicationHelpers.new(controller) }\n")
end

Cybertrain::Test.run!
