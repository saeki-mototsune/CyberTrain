# The fixture app of test/nested_includes.rb (docs/design.md D95): five
# models in a chain deep enough for nested includes over every pair of
# has_many, has_one and belongs_to. An author has one profile and many
# articles; an article has many comments; a comment belongs to its article
# and, optionally (a nullable key), to an author, and has many likes.
Cybertrain::Schema.define(version: "20261127120000") do |s|
  s.create_table "authors" do |t|
    t.string "name", null: false
  end

  s.create_table "profiles" do |t|
    t.references :author
    t.string "bio", null: false
  end

  s.create_table "articles" do |t|
    t.references :author
    t.string "title", null: false
  end

  s.create_table "comments" do |t|
    t.references :article
    t.references :author, null: true
    t.string "body", null: false
  end

  s.create_table "likes" do |t|
    t.references :comment
    t.string "who", null: false
  end
end
