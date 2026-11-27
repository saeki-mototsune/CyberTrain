# The polymorphic fixture's schema (docs/design.md D94): comments point to a
# post or a photo through the NOT NULL pair commentable_type /
# commentable_id, notes to either through the nullable pair notable_type /
# notable_id, each with the index Rails names after the reference.
Cybertrain::Schema.define(version: "20261127120000") do |s|
  s.create_table "comments" do |t|
    t.text "body", null: false
    t.references :commentable, polymorphic: true
    t.timestamps
  end

  s.create_table "notes" do |t|
    t.text "body"
    t.references :notable, polymorphic: true, null: true
  end

  s.create_table "photos" do |t|
    t.string "url", null: false
  end

  s.create_table "posts" do |t|
    t.string "title", null: false
  end
end
