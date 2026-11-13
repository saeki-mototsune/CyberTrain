require "cybertrain/test_help"
require_relative "../config/app"

# The application's base class: every test starts from empty tables and
# one author.
class ApplicationTest < ActiveSupport::TestCase
  setup do
    Article.all.delete_all
    User.all.delete_all
    @author = User.create(name: "Ann", email: "ann@example.com")
  end

  def write_article(title)
    Article.create(title: title, body: "A body.", author_id: @author.id)
  end
end
