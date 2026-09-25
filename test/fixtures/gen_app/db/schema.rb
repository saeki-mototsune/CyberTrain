# The fixture app's schema: the blog tables, plus a NOT NULL column with a
# default (posts.views) and a nullable boolean with a default
# (comments.approved) to exercise the generated initial values.
Cybertrain::Schema.define(version: "20260924120000") do |s|
  s.create_table "comments" do |t|
    t.references :post
    t.string "commenter", null: false
    t.text "body", null: false
    t.boolean "approved", default: "false"
    t.timestamps
  end

  s.create_table "posts" do |t|
    t.string "title", null: false
    t.text "body"
    t.integer "views", null: false, default: "0"
    t.timestamps
  end
end
