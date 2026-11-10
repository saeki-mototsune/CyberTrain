# The fixture app's schema: the blog tables, plus a NOT NULL column with a
# default (posts.views) and a nullable boolean with a default
# (comments.approved) to exercise the generated initial values, and the
# phase-2 types: a nullable decimal with a scale, a nullable json and a
# nullable date on posts, and a NOT NULL json, a NOT NULL date and a NOT
# NULL date with a default on comments; posts.comments_count is the counter
# of Comment's `belongs_to :post, counter_cache: true`; posts.thumbnail is a
# nullable binary column; posts.hidden is the flag of the Visible model
# concern's scope.
Cybertrain::Schema.define(version: "20260924120000") do |s|
  s.create_table "comments" do |t|
    t.references :post
    t.string "commenter", null: false
    t.text "body", null: false
    t.boolean "approved", default: "false"
    t.json "extras", null: false
    t.date "seen_on", null: false
    t.date "due_on", null: false, default: "'2026-01-01'"
    t.timestamps
  end

  s.create_table "posts" do |t|
    t.string "title", null: false
    t.text "body"
    t.integer "views", null: false, default: "0"
    t.decimal "price", precision: 10, scale: 2
    t.integer "comments_count", null: false, default: "0"
    t.json "meta"
    t.date "published_on"
    t.text "secret_note"
    t.binary "thumbnail"
    t.integer "hidden", null: false, default: "0"
    t.timestamps
  end
end
