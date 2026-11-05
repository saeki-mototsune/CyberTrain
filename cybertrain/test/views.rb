# Cybertrain::Test.render_partial / render_component (spec 3.5): render a
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
