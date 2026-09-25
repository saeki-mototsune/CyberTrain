require "cybertrain/migration"

class CreateComments < Cybertrain::Migration::Base
  version "20260101000100"

  def change
    create_table "comments" do |t|
      t.references :post
      t.string "commenter", null: false
      t.timestamps
    end
  end
end
