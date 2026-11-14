# test/framework_names_compiles.rb's schema: columns named like a framework
# method with one fixed return type (Gen::ModelNaming::FRAMEWORK_METHOD_TYPES),
# each a String column, so gen accepts it: request_id NOT NULL (beside
# Cybertrain::Request#request_id) and release nullable (beside
# Cybertrain::Config#release).
Cybertrain::Schema.define(version: "20261114120000") do |s|
  s.create_table "audit_entries" do |t|
    t.string "request_id", null: false
    t.string "release"
    t.string "note", null: false
  end
end
