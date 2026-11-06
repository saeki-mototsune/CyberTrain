require "cybertrain/test"
require "cybertrain/db"
require "cybertrain/db/schema_dumper"
require "cybertrain/db/sqlite_ddl"
require "cybertrain/model"
require "cybertrain/schema"
require "cybertrain/generator/models_emitter"

# BLOB columns end to end: the schema DSL's t.binary, the DDL and the
# dumper, DB::Blob binds, BLOB cells read back byte for byte (a NUL in the
# first byte, bytes above 127, 0, 1 and 70,000 bytes), and a model of the
# shape the generator emits (hand-written below, as test/model.rb does) with
# a binary attribute. A TEXT column holding the invalid UTF-8 "\xff\xfe"
# binds as text and round-trips too (Review Focus 5 of the phase-1 plan).
#
# It links SQLite through FFI, so it cannot run under CRuby: its snapshot
# comes from the compiled binary (spikes/NOTES.md rule 23).

DB = Cybertrain::DB

def docs_schema
  Cybertrain::Schema.define(version: "1") do |s|
    s.create_table "docs" do |t|
      t.binary "body"
      t.string "note"
    end
    s.create_table "images" do |t|
      t.binary "data", null: false
      t.string "name", null: false
    end
  end
end

def docs_db
  conn = DB::Connection.new(":memory:")
  definition = docs_schema
  definition.tables.each { |table| conn.exec_script(DB::SqliteDDL.create_table(table)) }
  conn
end

# 70,000 bytes after "\0ab": every byte value, from a fixed linear
# congruential sequence (no Random: the same bytes on every run). Built
# with << (rule 60).
def sample_bytes(size)
  out = +"\0ab"
  out.force_encoding("BINARY")
  seed = 12_345
  i = 0
  while i < size
    seed = (seed * 1_103_515_245 + 12_345) % 2_147_483_648
    out << (seed / 65_536 % 256).chr
    i += 1
  end
  out
end

def same_bytes?(a, b)
  return false unless a.bytesize == b.bytesize

  i = 0
  n = a.bytesize
  while i < n
    return false unless a.getbyte(i) == b.getbyte(i)
    i += 1
  end
  true
end

# ---- the shape gen/models/image.rb takes (see the emitter test below) ----

class ImageRelation < Cybertrain::Relation
  # What the emitter writes for a table with a BLOB column.
  def binary_column?(name)
    case name
    when "data" then true
    else false
    end
  end

  def where(h) = (add_where(h); self)
  def where_sql(s, b = []) = (add_where_sql(s, b); self)
  def limit(n) = (set_limit(n); self)

  def first
    r = first_row
    return nil if r.nil?
    Image.from_row(r)
  end

  def find(id)
    rec = where(id: id).first
    raise Cybertrain::RecordNotFound, "Couldn't find Image with id=#{id}" if rec.nil?
    rec
  end
end

class Image < Cybertrain::Model
  def self.table_name = "images"
  def self.column_names = ["id", "data", "name"]
  def model_name = "Image"

  attr_accessor :data, :name

  def initialize(attrs = {})
    super()
    @data = ""
    @name = ""
    assign_attributes(attrs) unless attrs.empty?
  end

  def self.from_row(row)
    rec = Image.new(Cybertrain::Model::NO_ATTRIBUTES)
    rec.load_row(row)
    rec
  end

  def load_row(row)
    set_id(Cybertrain::Cast.int(row["id"]))
    @data = Cybertrain::Cast.binary(row["data"])
    @name = Cybertrain::Cast.str(row["name"])
    mark_persisted!
    nil
  end

  def read_attribute(name)
    case name
    when :id then @id
    when :data then @data
    when :name then @name
    else nil
    end
  end

  def write_attribute(name, value)
    case name
    when :data then @data = Cybertrain::Cast.binary(value)
    when :name then @name = Cybertrain::Cast.str(value)
    end
    nil
  end

  def assign_attributes(attrs)
    attrs.each { |k, v| write_attribute(k.to_s.to_sym, v) }
    self
  end

  def to_row
    {
      "data" => Cybertrain::DB::Blob.wrap(@data),
      "name" => Cybertrain::Cast.to_sql(@name)
    }
  end

  def self.all = ImageRelation.new("images")
  def self.find(id) = all.find(id)
end

# docs.body is a nullable binary column: str_or_nil, and nil binds NULL
# through Blob.wrap.
class DocRelation < Cybertrain::Relation
  def where(h) = (add_where(h); self)

  def first
    r = first_row
    return nil if r.nil?
    Doc.from_row(r)
  end
end

class Doc < Cybertrain::Model
  def self.table_name = "docs"
  def self.column_names = ["id", "body", "note"]
  def model_name = "Doc"

  attr_accessor :body, :note

  def initialize(attrs = {})
    super()
    @body = nil
    @note = nil
    assign_attributes(attrs) unless attrs.empty?
  end

  def self.from_row(row)
    rec = Doc.new(Cybertrain::Model::NO_ATTRIBUTES)
    rec.load_row(row)
    rec
  end

  def load_row(row)
    set_id(Cybertrain::Cast.int(row["id"]))
    @body = Cybertrain::Cast.str_or_nil(row["body"])
    @note = Cybertrain::Cast.str_or_nil(row["note"])
    mark_persisted!
    nil
  end

  def read_attribute(name)
    case name
    when :id then @id
    when :body then @body
    when :note then @note
    else nil
    end
  end

  def write_attribute(name, value)
    case name
    when :body then @body = Cybertrain::Cast.str_or_nil(value)
    when :note then @note = Cybertrain::Cast.str_or_nil(value)
    end
    nil
  end

  def assign_attributes(attrs)
    attrs.each { |k, v| write_attribute(k.to_s.to_sym, v) }
    self
  end

  def to_row
    {
      "body" => Cybertrain::DB::Blob.wrap(@body),
      "note" => Cybertrain::Cast.to_sql(@note)
    }
  end

  def self.all = DocRelation.new("docs")
end

test "t.binary declares a BLOB column" do
  table = docs_schema.table("docs")
  assert_equal "binary", table.column("body").type.to_s
  assert_equal "CREATE TABLE docs (id INTEGER PRIMARY KEY AUTOINCREMENT, body BLOB, note VARCHAR)",
               DB::SqliteDDL.create_table(table)
end

test "a Blob bind round-trips 70,003 bytes byte for byte, next to invalid UTF-8 text" do
  conn = docs_db
  bytes = sample_bytes(70_000)
  assert_equal 70_003, bytes.bytesize
  assert_equal 0, bytes.getbyte(0)
  note = "\xff\xfe".b
  conn.execute("INSERT INTO docs (body, note) VALUES (?, ?)", [DB::Blob.new(bytes), note])
  rows = conn.execute("SELECT body, note, typeof(body) AS tb, typeof(note) AS tn FROM docs")
  assert_equal "blob", rows[0]["tb"]
  assert_equal "text", rows[0]["tn"]
  body = Cybertrain::Cast.binary(rows[0]["body"])
  assert_equal 70_003, body.bytesize
  assert same_bytes?(bytes, body)
  assert_equal 0, body.getbyte(0)
  text = Cybertrain::Cast.str(rows[0]["note"])
  assert_equal 2, text.bytesize
  assert_equal 255, text.getbyte(0)
  assert_equal 254, text.getbyte(1)
  conn.close
end

test "empty and one-byte blobs, a NULL, and Cast.binds" do
  conn = docs_db
  conn.execute("INSERT INTO docs (body, note) VALUES (?, ?)", Cybertrain::Cast.binds(DB::Blob.new(""), "empty"))
  conn.execute("INSERT INTO docs (body, note) VALUES (?, ?)", [DB::Blob.new("\0"), "one"])
  conn.execute("INSERT INTO docs (body, note) VALUES (?, ?)", [nil, "null"])
  rows = conn.execute("SELECT body, typeof(body) AS tb FROM docs ORDER BY id")
  assert_equal "blob", rows[0]["tb"]
  assert_equal "", Cybertrain::Cast.binary(rows[0]["body"])
  assert_equal 1, Cybertrain::Cast.binary(rows[1]["body"]).bytesize
  assert_equal 0, Cybertrain::Cast.binary(rows[1]["body"]).getbyte(0)
  assert_equal "null", rows[2]["tb"]
  assert_nil rows[2]["body"]
  conn.close
end

test "Cast.binary narrows" do
  assert_equal "", Cybertrain::Cast.binary(nil)
  assert_equal "ab", Cybertrain::Cast.binary("ab")
  assert_equal "cd", Cybertrain::Cast.binary(DB::Blob.new("cd"))
  assert_nil DB::Blob.wrap(nil)
  assert_equal "x", DB::Blob.wrap("x").blob_bytes
end

test "the dumper writes t.binary back" do
  conn = docs_db
  schema = DB::SchemaDumper.dump_to_ruby(conn)
  assert_includes schema, "    t.binary \"body\"\n"
  assert_includes schema, "    t.binary \"data\", null: false\n"
  assert_equal "binary", DB::SchemaDumper.dump(conn).table("docs").column("body").type.to_s
  conn.close
end

test "add_column with :binary adds a BLOB column" do
  op = Cybertrain::Migration::Operation.for_add_column("docs", "thumb", :binary, true, nil, 0)
  assert_equal ["ALTER TABLE docs ADD COLUMN thumb BLOB"], DB::SqliteDDL.statements(op)
  conn = docs_db
  DB::SqliteDDL.statements(op).each { |sql| conn.exec_script(sql) }
  assert_equal "binary", DB::SchemaDumper.dump(conn).table("docs").column("thumb").type.to_s
  conn.close
end

test "the generator types a binary column as a String and binds it as a Blob" do
  definition = docs_schema
  none = Array.new(0) { "" }
  no_scopes = Array.new(0) { Cybertrain::Gen::ScopeInfo.new("", "", "", "", 0) }
  docs = Cybertrain::Gen::ModelsEmitter.emit(definition.table("docs"), definition, none, no_scopes)
  assert_includes docs, "    @body = Cybertrain::Cast.str_or_nil(row[\"body\"])\n"
  assert_includes docs, "      \"body\" => Cybertrain::DB::Blob.wrap(@body),\n"
  assert_includes docs, "      \"note\" => Cybertrain::Cast.to_sql(@note)\n"
  images = Cybertrain::Gen::ModelsEmitter.emit(definition.table("images"), definition, none, no_scopes)
  assert_includes images, "    @data = \"\"\n"
  assert_includes images, "    @data = Cybertrain::Cast.binary(row[\"data\"])\n"
  assert_includes images, "    when :data then @data = Cybertrain::Cast.binary(value)\n"
  assert_includes images, "      \"data\" => Cybertrain::DB::Blob.wrap(@data),\n"
  # ImageRelation answers binary_column? for data (through column_type), so
  # where(data: bytes) binds a Blob.
  assert_includes images, "  end\n\n  def column_type(name)\n    case name\n" \
                          "    when \"id\" then :integer\n    when \"data\" then :binary\n"
  assert_includes images, "  def binary_column?(name) = column_type(name) == :binary\n"
  assert_includes docs, "    when \"body\" then :binary\n"
  assert_includes docs, "  def binary_column?(name) = column_type(name) == :binary\n"
  articles = Cybertrain::Schema.define(version: "1") { |s| s.create_table("articles") { |t| t.string "title" } }
  assert_nil Cybertrain::Gen::ModelsEmitter.emit(articles.table("articles"), articles, none, no_scopes).index("binary_column?")
end

test "a binary column with a default is refused by the generator" do
  with_default = Cybertrain::Schema.define(version: "1") do |s|
    s.create_table "thumbs" do |t|
      t.binary "bytes_column", null: false, default: "x'4142'"
      t.binary "other", default: "NULL"
    end
  end
  none = Array.new(0) { "" }
  no_scopes = Array.new(0) { Cybertrain::Gen::ScopeInfo.new("", "", "", "", 0) }
  msg = assert_raises("ArgumentError") { Cybertrain::Gen::ModelsEmitter.emit(with_default.table("thumbs"), with_default, none, no_scopes) }
  assert_equal "table thumbs: column \"bytes_column\" is a binary column with a default (x'4142'); a BLOB column takes no default, set the bytes in the model instead", msg
  only_null = Cybertrain::Schema.define(version: "1") { |s| s.create_table("thumbs") { |t| t.binary "other", default: "NULL" } }
  assert_includes Cybertrain::Gen::ModelsEmitter.emit(only_null.table("thumbs"), only_null, none, no_scopes), "@other = nil"
end

test "a model with a binary attribute saves and reloads its bytes" do
  path = "tmp/db_blob_test.sqlite3"
  Dir.mkdir("tmp") unless Dir.exist?("tmp")
  [path, "#{path}-wal", "#{path}-shm"].each { |f| File.delete(f) if File.exist?(f) }
  DB.connect(path, size: 1)
  definition = docs_schema
  DB.with { |c| c.exec_script(DB::SqliteDDL.create_table(definition.table("images"))) }
  bytes = sample_bytes(1_000)
  image = Image.new(name: "logo")
  image.data = bytes
  assert image.save
  loaded = Image.find(image.id)
  assert_equal "logo", loaded.name
  assert_equal 1_003, loaded.data.bytesize
  assert same_bytes?(bytes, loaded.data)
  loaded.data = "\0\x01\x02".b
  assert loaded.save
  again = Image.find(image.id)
  assert_equal 3, again.data.bytesize
  assert_equal 2, again.data.getbyte(2)
  kind = DB.with { |c| c.execute("SELECT typeof(data) AS t FROM images") }
  assert_equal "blob", kind[0]["t"]

  # where(data: bytes) binds the bytes as a BLOB (a TEXT bind never equals
  # the stored BLOB), as does a Blob given to where_sql; a bind in IN too.
  found = Image.all.where(data: "\0\x01\x02".b).first
  refute found.nil?, "expected where(data: bytes) to find the row"
  assert_equal image.id, found.id
  assert_nil Image.all.where(data: "\0\x01\x03".b).first
  assert_equal image.id, Image.all.where_sql("data = ?", [DB::Blob.new("\0\x01\x02".b)]).first.id
  assert_nil Image.all.where_sql("data = ?", ["\0\x01\x02".b]).first
  assert_equal image.id, Image.all.where(data: ["\0\x01\x02".b, "zz"]).first.id

  # 0 and 1 bytes through the model.
  empty = Image.new(name: "empty")
  empty.data = ""
  assert empty.save
  assert_equal 0, Image.find(empty.id).data.bytesize
  one = Image.new(name: "one")
  one.data = "\0"
  assert one.save
  loaded_one = Image.find(one.id)
  assert_equal 1, loaded_one.data.bytesize
  assert_equal 0, loaded_one.data.getbyte(0)

  # A nullable binary attribute set to nil stores NULL; bytes come back.
  DB.with { |c| c.exec_script(DB::SqliteDDL.create_table(definition.table("docs"))) }
  doc = Doc.new(note: "none")
  assert doc.save
  stored = DB.with { |c| c.execute("SELECT typeof(body) AS t FROM docs WHERE id = ?", [doc.id]) }
  assert_equal "null", stored[0]["t"]
  assert_nil Doc.all.where(id: doc.id).first.body
  doc.body = "\0z"
  assert doc.save
  assert_equal 2, Doc.all.where(id: doc.id).first.body.to_s.bytesize
  DB.disconnect
  [path, "#{path}-wal", "#{path}-shm"].each { |f| File.delete(f) if File.exist?(f) }
end

Cybertrain::Test.run!
