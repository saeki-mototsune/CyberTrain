Cybertrain::Schema.define(version: "20261112174320") do |s|
  s.create_table "articles" do |t|
    t.string "title"
    t.text "body"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "cover_key", null: false, default: "''"
    t.string "cover_filename", null: false, default: "''"
    t.string "cover_content_type", null: false, default: "''"
    t.integer "cover_byte_size", null: false, default: "0"
    t.string "cover_checksum", null: false, default: "''"
  end

  s.create_table "comments" do |t|
    t.string "commenter"
    t.text "body"
    t.integer "article_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
  end

  s.add_index "comments", ["article_id"], name: "index_comments_on_article_id"

  s.add_foreign_key "comments", "articles", column: "article_id"
end
