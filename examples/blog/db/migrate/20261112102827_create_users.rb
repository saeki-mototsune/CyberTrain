class CreateUsers < Cybertrain::Migration::Base
  def change
    create_table "users" do |t|
      t.string "email_address", null: false
      t.string "password_digest", null: false
      t.boolean "admin", null: false, default: "false"
      t.integer "failed_attempts", null: false, default: "0"
      t.datetime "locked_until"
      t.timestamps
    end
    add_index "users", ["email_address"], unique: true
  end
end
