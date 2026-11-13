Cybertrain::Schema.define(version: "20261112000000") do |s|
  s.create_table "articles" do |t|
    t.references :user
    t.string "title", null: false
    t.timestamps
  end

  s.create_table "users" do |t|
    t.string "name", null: false
    t.timestamps
  end
end
