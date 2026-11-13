require "cybertrain/migration"

class CreateUsers < Cybertrain::Migration::Base
  version "20261112000000"

  def change
    create_table "users" do |t|
      t.string "name", null: false
      t.timestamps
    end
  end
end
