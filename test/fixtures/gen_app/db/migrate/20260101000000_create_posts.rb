require "cybertrain/migration"

class CreatePosts < Cybertrain::Migration::Base
  def change
    create_table "posts" do |t|
      t.string "title", null: false
      t.timestamps
    end
  end
end
