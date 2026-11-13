require "cybertrain/migration"

class CreateArticles < Cybertrain::Migration::Base
  version "20261112000100"

  def change
    create_table "articles" do |t|
      t.references :user
      t.string "title", null: false
      t.timestamps
    end
  end
end
