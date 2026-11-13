Cybertrain::Schema.define(version: "20261112000000") do |s|
  s.create_table "articles" do |t|
    t.string "title", null: false
    t.text "body"
    t.integer "author_id", null: false
    t.boolean "published", null: false, default: "false"
    t.datetime "published_at"
    t.decimal "price", precision: 10, scale: 2
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
  end

  s.create_table "users" do |t|
    t.string "name", null: false
    t.string "email", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
  end
end
