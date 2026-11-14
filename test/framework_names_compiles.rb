require "cybertrain/test"
require "cybertrain/config"
require "cybertrain/db"
require "cybertrain/model"
require "cybertrain/schema"
require "cybertrain/http/request"
require "cybertrain/generator/model_scan"
require "cybertrain/generator/models_emitter"

# Proves that a model column named like a framework method with one fixed
# return type builds and runs when gen accepts it
# (Gen::ModelNaming::FRAMEWORK_METHOD_TYPES): AuditEntry's String reader
# request_id beside Cybertrain::Request#request_id, and its nullable String
# reader release beside Cybertrain::Config#release, all four called in one
# program (one return type per method name, spikes/NOTES.md rules 10, 34).
# The model is the checked-in output of the emitter for
# test/fixtures/framework_names/db/schema.rb. SQLite is FFI, so the snapshot
# comes from the compiled binary (spikes/NOTES.md rule 23).
require_relative "fixtures/framework_names/db/schema"
require_relative "fixtures/framework_names/gen/models/audit_entry"

FIXTURE = "test/fixtures/framework_names"

Cybertrain::DB.connect(":memory:", size: 1)
Cybertrain::DB.with do |c|
  c.exec_script("CREATE TABLE \"audit_entries\" (id INTEGER PRIMARY KEY AUTOINCREMENT, \"request_id\" TEXT NOT NULL, " \
                "\"release\" TEXT, \"note\" TEXT NOT NULL);")
end

test "the checked-in gen/models file matches the emitter (fixture stale otherwise)" do
  infos = Array.new(0) { Cybertrain::Gen::ModelInfo.empty("", "", Array.new(0) { "" }) }
  outputs = Cybertrain::Gen::ModelsEmitter.outputs(Cybertrain::Schema.current, infos)
  assert_equal ["gen/models/audit_entry.rb"], outputs.keys
  outputs.each do |path, source|
    Cybertrain::Test.count_assertion
    flunk("fixture stale: #{path}") unless File.read(FIXTURE + "/" + path) == source
  end
end

test "a String request_id column reads and writes beside Request#request_id" do
  request = Cybertrain::Request.new("GET", "/", {}, "")
  assert_equal "", request.request_id
  request.request_id = "3f2a-req"
  entry = AuditEntry.create!(request_id: request.request_id, note: "export")
  assert_equal "3f2a-req", entry.request_id
  found = AuditEntry.find(entry.id)
  assert_equal "3f2a-req", found.request_id
  assert_equal 8, found.request_id.size
  found.request_id = "4b7c-req"
  assert_equal true, found.save
  assert_equal "4b7c-req", AuditEntry.find(entry.id).request_id
  assert_equal "4b7c-req", AuditEntry.find(entry.id).read_attribute(:request_id).to_s
  assert_equal 1, AuditEntry.where(request_id: "4b7c-req").count
  assert_equal "3f2a-req", request.request_id
end

test "a nullable String release column reads nil and a String beside Config#release" do
  Cybertrain.config.release = "v1.2.0"
  entry = AuditEntry.create!(request_id: "r1", note: "no release")
  assert_nil AuditEntry.find(entry.id).release
  assert_equal true, AuditEntry.find(entry.id).release.nil?
  tagged = AuditEntry.create!(request_id: "r2", note: "tagged", release: Cybertrain.config.release)
  release = AuditEntry.find(tagged.id).release
  assert_equal "v1.2.0", release
  assert_equal false, release.nil?
  assert_equal "v1.2.0", Cybertrain.config.release
  assert_equal 6, Cybertrain.config.release.size
  tagged.release = nil
  assert_equal true, tagged.save
  assert_nil AuditEntry.find(tagged.id).release
end

Cybertrain::Test.run!
