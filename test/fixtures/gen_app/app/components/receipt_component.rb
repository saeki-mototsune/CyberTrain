# Its template calls PostsController's helper methods: a
# component rendered by a controller's template reaches them too.
class ReceiptComponent < Cybertrain::Component
  def initialize(cents:)
    @cents = cents
  end
end
