# Cybertrain::Test.render_partial / render_component (spec 3.5) and the
# top-level render_inline (phase 5 spec 9.1): render a
# partial or a component with no controller, to assert on the HTML.
#
#   require "cybertrain/test/views"
#   html = Cybertrain::Test.render_component(CardComponent.new(title: "x"))
#   assert_includes html, "<h3>x</h3>"
#
# A file of its own, not cybertrain/test.rb: every test program requires
# that one, and most of them have no views.
require "cybertrain/test"
require "cybertrain/views"
require "cybertrain/template/helpers"
require "cybertrain/test/test_case"

module Cybertrain
  module Test
    # Views.render_partial("articles/article", article: a).
    # @api public
    def self.render_partial(name, locals = {})
      Views.render_partial(name, locals)
    end

    # Views.render_component, with the block's HTML as `content:`.
    # @api public
    def self.render_component(component, content: "")
      Views.render_component(component, content)
    end
  end
end

# The namespace of view_component's test base class, kept for Rails'
# spelling (`ViewComponent::TestCase`).
module ViewComponent
  # Rails' (view_component's) base class for component tests:
  # `render_inline` and `assert_select`, beside every assertion of
  # ActiveSupport::TestCase.
  # @example test/components/card_component_test.rb
  #   require "test_helper"
  #
  #   class CardComponentTest < ViewComponent::TestCase
  #     test "renders the title" do
  #       render_inline(CardComponent.new(title: "Hello"))
  #       assert_select "div.card > h2", text: "Hello"
  #     end
  #   end
  # @api public
  class TestCase < ActiveSupport::TestCase
  end
end

# Renders a component (`render_inline(CardComponent.new(title: "x"))`, its
# content as `content:`) or a partial (`render_inline(partial:
# "articles/form", locals: { article: Article.new })`) outside any request,
# answers the HTML and keeps it for `assert_select` (spec section 9.1).
# Rails answers a Nokogiri fragment and takes the content as a block; here
# the answer is the String and a block is refused. Request-bound helpers
# raise Views::OutsideRequest, as in Views.render_partial.
# @example
#   html = render_inline(partial: "articles/form", locals: { article: Article.new })
#   assert_select "form[action=\"/articles\"] input[name=\"article[title]\"]"
#   assert_includes html, "Save"
# @param component [Cybertrain::Component, nil]
# @param content [String] the component's content, unescaped
# @param partial [String] a partial's name, as `render` takes it
# @param locals [Hash] the partial's locals
# @return [String] the HTML
# @raise [ArgumentError] for neither or both of a component and `partial:`,
#   for `content:` with a partial, `locals:` with a component, and for a
#   block
# @api public
def render_inline(component = nil, content: "", partial: "", locals: {})
  if block_given?
    message = "render_inline: pass the content as content:, not a block"
    raise ArgumentError, message
  end
  if component.nil? == (partial == "")
    message = "render_inline: pass a component or partial:, not #{component.nil? ? "neither" : "both"}"
    raise ArgumentError, message
  end
  html = ""
  if partial == ""
    unless locals.empty?
      message = "render_inline: locals: are for a partial; a component takes its values in new(...)"
      raise ArgumentError, message
    end
    html = Cybertrain::Views.render_component(component, content).to_s
  else
    unless content == ""
      message = "render_inline: content: is for a component; a partial takes locals:"
      raise ArgumentError, message
    end
    html = Cybertrain::Views.render_partial(partial, locals).to_s
  end
  Cybertrain::Test.last_html = html
  html
end
