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

  s.create_table "sessions" do |t|
    t.integer "user_id", null: false
    t.string "ip_address"
    t.string "user_agent"
    t.boolean "remember", null: false, default: "false"
    t.datetime "last_active_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
  end

  s.create_table "users" do |t|
    t.string "email_address", null: false
    t.string "password_digest", null: false
    t.boolean "admin", null: false, default: "false"
    t.integer "failed_attempts", null: false, default: "0"
    t.datetime "locked_until"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
  end

  s.add_index "comments", ["article_id"], name: "index_comments_on_article_id"
  s.add_index "sessions", ["user_id"], name: "index_sessions_on_user_id"
  s.add_index "users", ["email_address"], unique: true, name: "index_users_on_email_address"

  s.add_foreign_key "comments", "articles", column: "article_id"
  s.add_foreign_key "sessions", "users", column: "user_id"
end
