# A card with a title: the component test/components/card_component_test.rb
# renders with render_inline (ViewComponent::TestCase).
class CardComponent < Cybertrain::Component
  def initialize(title:)
    @title = title
  end
end
