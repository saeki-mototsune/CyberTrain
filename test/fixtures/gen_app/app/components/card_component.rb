class CardComponent < Cybertrain::Component
  def initialize(title:, value: 0)
    @title = title
    @value = value
  end

  def value_text = "#{@value} pts"
end
