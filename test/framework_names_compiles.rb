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
# reader release beside Cybertrain::Config#release, and ReleaseNote's text
# request_id and nullable binary release (the other column types gen accepts
# under those names), all called in one program (one return type per method name, spikes/NOTES.md rules 10, 34).
# The models are the checked-in output of the emitter for
# test/fixtures/framework_names/db/schema.rb. SQLite is FFI, so the snapshot
# comes from the compiled binary (spikes/NOTES.md rule 23).
require_relative "fixtures/framework_names/db/schema"
require_relative "fixtures/framework_names/gen/models/audit_entry"
require_relative "fixtures/framework_names/gen/models/release_note"

FIXTURE = "test/fixtures/framework_names"

Cybertrain::DB.connect(":memory:", size: 1)
Cybertrain::DB.with do |c|
  c.exec_script("CREATE TABLE \"audit_entries\" (id INTEGER PRIMARY KEY AUTOINCREMENT, \"request_id\" TEXT NOT NULL, " \
                "\"release\" TEXT, \"note\" TEXT NOT NULL);" \
                "CREATE TABLE \"release_notes\" (id INTEGER PRIMARY KEY AUTOINCREMENT, \"request_id\" TEXT NOT NULL, " \
                "\"release\" BLOB);")
end

test "the checked-in gen/models files match the emitter (fixture stale otherwise)" do
  infos = Array.new(0) { Cybertrain::Gen::ModelInfo.empty("", "", Array.new(0) { "" }) }
  outputs = Cybertrain::Gen::ModelsEmitter.outputs(Cybertrain::Schema.current, infos)
  assert_equal ["gen/models/audit_entry.rb", "gen/models/release_note.rb"], outputs.keys
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

test "a text request_id and a nullable binary release read as Strings beside the framework's" do
  request = Cybertrain::Request.new("GET", "/", {}, "")
  request.request_id = "9d1e-req"
  Cybertrain.config.release = "v2.0.0"
  bytes = "v2\x00\xFF".b
  note = ReleaseNote.create!(request_id: request.request_id, release: bytes)
  found = ReleaseNote.find(note.id)
  assert_equal "9d1e-req", found.request_id
  assert_equal 8, found.request_id.size
  assert_equal 4, found.release.bytesize
  assert_equal 255, found.release.getbyte(3)
  assert_equal 0, found.release.getbyte(2)
  empty = ReleaseNote.create!(request_id: "r3")
  assert_nil ReleaseNote.find(empty.id).release
  assert_equal "9d1e-req", request.request_id
  assert_equal "v2.0.0", Cybertrain.config.release
end

Cybertrain::Test.run!
