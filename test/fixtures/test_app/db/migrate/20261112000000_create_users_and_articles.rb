class CreateUsersAndArticles < Cybertrain::Migration::Base
  def change
    create_table "users" do |t|
      t.string "name", null: false
      t.string "email", null: false
      t.timestamps
    end

    create_table "articles" do |t|
      t.string "title", null: false
      t.text "body"
      t.integer "author_id", null: false
      t.boolean "published", null: false, default: "false"
      t.datetime "published_at"
      t.decimal "price", precision: 10, scale: 2
      t.timestamps
    end
  end
end
