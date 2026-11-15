# test/framework_names_compiles.rb's schema: columns named like a framework
# method with one fixed return type (Cybertrain::Ident::FRAMEWORK_METHOD_TYPES),
# each read as a String, so gen accepts it: on audit_entries a string
# request_id NOT NULL (beside Cybertrain::Request#request_id) and a nullable
# string release (beside Cybertrain::Config#release); on release_notes the
# other column types gen accepts under those names, a text request_id NOT
# NULL and a nullable binary release (a String of raw bytes).
Cybertrain::Schema.define(version: "20261114120000") do |s|
  s.create_table "audit_entries" do |t|
    t.string "request_id", null: false
    t.string "release"
    t.string "note", null: false
  end
  s.create_table "release_notes" do |t|
    t.text "request_id", null: false
    t.binary "release"
  end
end
