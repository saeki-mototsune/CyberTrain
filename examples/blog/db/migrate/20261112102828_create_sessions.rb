class CreateSessions < Cybertrain::Migration::Base
  def change
    create_table "sessions" do |t|
      t.references :user
      t.string "ip_address"
      t.string "user_agent"
      t.boolean "remember", null: false, default: "false"
      t.datetime "last_active_at"
      t.timestamps
    end
  end
end
