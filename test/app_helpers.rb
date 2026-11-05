require "tmpdir"
require "cybertrain/test"
require "cybertrain/controller"
require "cybertrain/flash"

# Application helpers (spec 3.1): a helper module and the ApplicationHelpers
# class hand-written in the shape gen/helpers.rb emits, installed as
# Views.helpers_builder; controllers then render through it.
#
# cybertrain/model links SQLite through FFI, so this program cannot run under
# CRuby: its snapshot comes from the compiled binary (spikes/NOTES.md rule 23).

module Gen
  module UrlHelpers
    def home_path
      "/home"
    end
  end
end

module ShoutHelper
  def shout(text)
    "#{Cybertrain::FormBuilder.value_text(text).upcase}!"
  end

  def badge(text, kind = "info", &block)
    Cybertrain::SafeString.of("<span class=\"#{kind}\">#{Cybertrain::Html.escape(Cybertrain::FormBuilder.value_text(text))}#{yield}</span>")
  end

  def price(value, unit: "USD")
    "#{Cybertrain::FormBuilder.value_text(value)} #{Cybertrain::FormBuilder.value_text(unit)}"
  end

  def home_link(text)
    link_to_path(text, home_path, class: "nav")
  end

  def delete_button(path)
    button_to_path("Delete", path, method: "delete", class: "danger")
  end
end

class ApplicationHelpers < Cybertrain::Template::Helpers
  include ::Gen::UrlHelpers
  include ::ShoutHelper

  def app_helper_call(name, args, kwargs, block, interp, env)
    case name
    when "shout"
      helper_arity!(name, args, 1, 1)
      helper_no_keywords!(name, kwargs)
      shout(args[0])
    when "badge"
      helper_arity!(name, args, 1, 2)
      helper_no_keywords!(name, kwargs)
      if args.size >= 2 then badge(args[0], args[1]) { app_block_content(block, interp, env) }
      else badge(args[0]) { app_block_content(block, interp, env) }
      end
    when "price"
      helper_arity!(name, args, 1, 1)
      helper_keywords!(name, kwargs, ["unit"], 0)
      if kwargs.key?("unit") then price(args[0], unit: kwargs["unit"])
      else price(args[0])
      end
    when "home_link"
      helper_arity!(name, args, 1, 1)
      helper_no_keywords!(name, kwargs)
      home_link(args[0])
    when "delete_button"
      helper_arity!(name, args, 1, 1)
      helper_no_keywords!(name, kwargs)
      delete_button(args[0])
    else super(name, args, kwargs, block, interp, env)
    end
  end
end

Cybertrain::Views.helpers_builder = ->(controller) { ApplicationHelpers.new(controller) }

ROOT = Dir.mktmpdir("cybertrain-app-helpers")
Dir.mkdir("#{ROOT}/pages")
File.write("#{ROOT}/pages/home.html.erb", "<p><%= shout 'hi' %></p>")
File.write("#{ROOT}/pages/_card.html.erb", "[<%= shout name %>]")
at_exit do
  File.delete("#{ROOT}/pages/home.html.erb")
  File.delete("#{ROOT}/pages/_card.html.erb")
  Dir.rmdir("#{ROOT}/pages")
  Dir.rmdir(ROOT)
end
Cybertrain::Views.configure(ROOT, cache: false)

class PagesController < Cybertrain::Controller
  def home
  end

  def card
    render partial: "card", locals: { name: "ann" }
  end

  def view_assigns
    { "page" => 1 }
  end
end

def dispatch(action)
  ctx = Cybertrain::Context.new(Cybertrain::Request.new("GET", "/", { "host" => "example.test" }, ""))
  c = PagesController.new(ctx)
  case action
  when :home then c.process(:home) { |x| x.home }
  when :card then c.process(:card) { |x| x.card }
  end
  c
end

def render_inline(src)
  template = Cybertrain::Template::Template.parse(src, "pages/inline")
  env = { "__template_dir" => "pages" }
  Cybertrain::Template::Interpreter.new(Cybertrain::Views.helpers_builder.call(nil)).render(template, env)
end

def render_error(src)
  msg = ""
  begin
    render_inline(src)
  rescue StandardError => e
    msg = e.message
  end
  msg
end

test "a controller's template reaches the application's helpers" do
  assert_equal "<p>HI!</p>", dispatch(:home).response.body
end

test "a controller's partial reaches them too" do
  assert_equal "[ANN!]", dispatch(:card).response.body
end

test "an optional positional and a block" do
  assert_equal "<span class=\"info\">a&amp;b</span>", render_inline("<%= badge 'a&b' %>")
  assert_equal "<span class=\"warn\">x <i>y</i></span>", render_inline("<%= badge 'x', 'warn' do %> <i>y</i><% end %>")
end

test "an unknown name is still an undefined helper" do
  assert_equal "pages/inline:1: undefined helper 'nope'", render_error("<%= nope %>")
end

test "the generated arms check their arguments" do
  assert_equal "pages/inline:1: wrong number of arguments for 'shout' (given 2, expected 1)", render_error("<%= shout 'a', 'b' %>")
  assert_equal "pages/inline:1: wrong number of arguments for 'badge' (given 0, expected 1..2)", render_error("<%= badge %>")
  assert_equal "pages/inline:1: 'shout' takes no keyword arguments (given loud)", render_error("<%= shout 'a', loud: true %>")
end

test "an omitted keyword gets the method's own default" do
  assert_equal "3 USD|3 EUR", render_inline("<%= price 3 %>|<%= price 3, unit: 'EUR' %>")
  assert_equal "pages/inline:1: unknown keyword 'units' for 'price' (known: unit)", render_error("<%= price 3, units: 'EUR' %>")
end

test "link_to_path and button_to_path from a Ruby helper" do
  assert_equal "<a href=\"/home\" class=\"nav\">Go &amp; see</a>", render_inline("<%= home_link 'Go & see' %>")
  assert_equal "<form class=\"button_to\" method=\"post\" action=\"/p/1\"><input type=\"hidden\" name=\"_method\" value=\"delete\"><button class=\"danger\" type=\"submit\">Delete</button></form>", render_inline("<%= delete_button '/p/1' %>")
end

test "the built-in helpers still come first" do
  assert_equal "&lt;b&gt;", render_inline("<%= h '<b>' %>")
end

Cybertrain::Test.run!
