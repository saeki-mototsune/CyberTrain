class CreateUsers < ActiveRecord::Migration[8.1]
  def change
    create_table :users do |t|
      t.string :email_address, null: false
      t.string :password_digest, null: false
      # Not generated: examples/blog's users have it (User#admin?).
      t.boolean :admin, null: false, default: false

      t.timestamps
    end
    add_index :users, :email_address, unique: true
  end
end
