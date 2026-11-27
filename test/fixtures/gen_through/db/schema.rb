# The has_many :through fixture (docs/design.md D93): posts tagged through
# taggings, authors with posts and the posts' comments. posts.author_id is
# nullable, so the paths through it (Post#co_posts, Comment#writers) read
# a nullable key.
Cybertrain::Schema.define(version: "20261127120000") do |s|
  s.create_table "authors" do |t|
    t.string "name", null: false
  end

  s.create_table "comments" do |t|
    t.references :post
    t.text "body", null: false
  end

  s.create_table "posts" do |t|
    t.string "title", null: false
    t.integer "author_id"
  end

  s.create_table "taggings" do |t|
    t.references :post
    t.references :tag
  end

  s.create_table "tags" do |t|
    t.string "name", null: false
  end

  s.add_foreign_key "posts", "authors", column: "author_id"
end
