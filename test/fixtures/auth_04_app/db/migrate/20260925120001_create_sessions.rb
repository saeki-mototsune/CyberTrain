class CreateSessions < Cybertrain::Migration::Base
  def change
    create_table "sessions" do |t|
      t.references :user
      t.string "ip_address"
      t.string "user_agent"
      t.timestamps
    end
  end
end
