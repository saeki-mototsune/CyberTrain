require "stringio"
require "cybertrain/test"
require "cybertrain/db"
require "cybertrain/model"
require "cybertrain/config"
require "cybertrain/console"

# Cybertrain::Console.run: lines in through a StringIO, values out through
# another, over a temporary database with one hand-written model of the
# shape gen/models emits (test/model.rb is that shape's specification). The
# four Console.*_builder accessors are set here the way gen/console.rb
# sets them.
#
# It links SQLite through FFI, so it cannot run under CRuby: its snapshot
# comes from the compiled binary (spikes/NOTES.md rule 23).

ENV["CYBERTRAIN_ENV"] = "test"

class ArticleRelation < Cybertrain::Relation
  def where(h) = (add_where(h); self)
  def order(o) = (set_order(o); self)
  def limit(n) = (set_limit(n); self)

  def to_a
    out = Array.new(0) { Article.new }
    found = rows
    i = 0
    while i < found.size
      out << Article.from_row(found[i])
      i += 1
    end
    out
  end

  def first
    r = first_row
    return nil if r.nil?
    Article.from_row(r)
  end

  def find(id)
    rec = where(id: id).first
    raise Cybertrain::RecordNotFound, "Couldn't find Article with id=#{id}" if rec.nil?
    rec
  end
end

class Article < Cybertrain::Model
  def self.table_name = "articles"
  def self.column_names = ["id", "title", "body"]
  def model_name = "Article"

  validates :title, presence: true

  attr_accessor :title, :body

  def initialize(attrs = {})
    super()
    @title = ""
    @body = nil
    assign_attributes(attrs) unless attrs.empty?
  end

  def self.from_row(row)
    rec = Article.new(Cybertrain::Model::NO_ATTRIBUTES)
    rec.load_row(row)
    rec
  end

  def load_row(row)
    set_id(Cybertrain::Cast.int(row["id"]))
    @title = Cybertrain::Cast.str(row["title"])
    @body = Cybertrain::Cast.str_or_nil(row["body"])
    mark_persisted!
    nil
  end

  def read_attribute(name)
    case name
    when :id then @id
    when :title then @title
    when :body then @body
    else nil
    end
  end

  def write_attribute(name, value)
    case name
    when :title then @title = Cybertrain::Cast.str(value)
    when :body then @body = Cybertrain::Cast.str_or_nil(value)
    end
    nil
  end

  def assign_attributes(attrs)
    attrs.each { |k, v| write_attribute(k.to_s.to_sym, v) }
    self
  end

  def to_row
    {
      "title" => Cybertrain::Cast.to_sql(@title),
      "body" => Cybertrain::Cast.to_sql(@body)
    }
  end

  def self.all = ArticleRelation.new("articles")

  def self.create(attrs = {})
    rec = Article.new(attrs)
    rec.save
    rec
  end

  def headline = "#{@title}!"

  def call_view_method(name)
    case name
    when :headline then headline
    else nil
    end
  end
end

class PhotoRelation < Cybertrain::Relation
  def to_a
    out = Array.new(0) { Photo.new }
    found = rows
    i = 0
    while i < found.size
      out << Photo.from_row(found[i])
      i += 1
    end
    out
  end
end

# A binary column (t.binary "data", null: false), as gen/models types it.
class Photo < Cybertrain::Model
  def self.table_name = "photos"
  def self.column_names = ["id", "data", "name"]
  def model_name = "Photo"

  attr_accessor :data, :name

  def initialize(attrs = {})
    super()
    @data = ""
    @name = ""
    assign_attributes(attrs) unless attrs.empty?
  end

  def self.from_row(row)
    rec = Photo.new(Cybertrain::Model::NO_ATTRIBUTES)
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

  def self.all = PhotoRelation.new("photos")
end

# What gen/console.rb holds for these two models.
def console_scope(name)
  case name
  when "Article" then Article.all
  when "Photo" then Photo.all
  else Cybertrain::Console.unknown_model(name)
  end
end

def console_records(relation)
  case relation
  when ArticleRelation then relation.to_a
  when PhotoRelation then relation.to_a
  else Cybertrain::Console.no_records(relation)
  end
end

def console_create(name, attrs)
  case name
  when "Article" then Article.create(attrs)
  else Cybertrain::Console.unknown_record(name)
  end
end

def scope_lambda = ->(name) { console_scope(name) }
def records_lambda = ->(relation) { console_records(relation) }
def create_lambda = ->(name, attrs) { console_create(name, attrs) }

Cybertrain::Console.scope_builder = scope_lambda
Cybertrain::Console.records_builder = records_lambda
Cybertrain::Console.create_builder = create_lambda
Cybertrain::Console.model_names = ["Article", "Photo"]

DB_PATH = "tmp/console_test.sqlite3"

def remove_db
  [DB_PATH, "#{DB_PATH}-wal", "#{DB_PATH}-shm"].each { |f| File.delete(f) if File.exist?(f) }
end

Dir.mkdir("tmp") unless Dir.exist?("tmp")
remove_db
at_exit { remove_db }
Cybertrain::DB.connect(DB_PATH, size: 1)
Cybertrain::DB.with do |c|
  c.exec_script("CREATE TABLE articles (id INTEGER PRIMARY KEY AUTOINCREMENT, title VARCHAR NOT NULL, body TEXT)")
  c.exec_script("CREATE TABLE photos (id INTEGER PRIMARY KEY AUTOINCREMENT, data BLOB NOT NULL, name VARCHAR NOT NULL)")
end

BANNER = "Cybertrain console (test). Type help for commands, exit to quit.\n"

# The output of one console session reading `lines`, and its exit status.
def session(lines, config = Cybertrain::Config.new)
  input = StringIO.new(lines)
  output = StringIO.new
  status = Cybertrain::Console.run(input, output, config)
  "#{status}|#{output.string}"
end

test "queries, a create, _ and errors that do not end the session" do
  lines = +""
  lines << "Article.count\n"
  lines << "Article.create(title: \"x\")\n"
  lines << "Article.where(title: \"x\").count\n"
  lines << "Article.find(1).title\n"
  lines << "_\n"
  lines << "Article.order(id: :desc).limit(1).to_a\n"
  lines << "Article.find(9)\n"
  lines << "Nope.count\n"
  lines << "Article.find(1).headline\n"
  lines << "exit\n"
  lines << "Article.count\n"
  expected = +"0|"
  expected << BANNER
  expected << ">> 0\n"
  expected << ">> #<Article id: 1, title: \"x\", body: nil>\n"
  expected << ">> 1\n"
  expected << ">> \"x\"\n"
  expected << ">> \"x\"\n"
  expected << ">> #<Article id: 1, title: \"x\", body: nil>\n1 record\n"
  expected << ">> Cybertrain::RecordNotFound: Couldn't find Article with id=9\n"
  expected << ">> UnknownModel: no model \"Nope\" (models: Article, Photo)\n"
  expected << ">> \"x!\"\n"
  expected << ">> "
  assert_equal expected, session(lines)
end

test "update, destroy, first, last, find_by, exists?, pluck and a local" do
  lines = +""
  lines << "Article.create(title: \"second\", body: \"b\")\n"
  lines << "Article.find(1).update(title: \"y\")\n"
  lines << "Article.find(1).title\n"
  lines << "Article.first.title\n"
  lines << "Article.last.title\n"
  lines << "Article.order(:title).pluck_str(:title)\n"
  lines << "a = Article.find_by(title: \"second\")\n"
  lines << "a.body\n"
  lines << "Article.where(title: \"nothing\").exists?\n"
  lines << "Article.find(2).destroy\n"
  lines << "Article.count\n"
  expected = +"0|"
  expected << BANNER
  expected << ">> #<Article id: 2, title: \"second\", body: \"b\">\n"
  expected << ">> true\n"
  expected << ">> \"y\"\n"
  expected << ">> \"y\"\n"
  expected << ">> \"second\"\n"
  expected << ">> \"second\"\n\"y\"\n2 elements\n"
  expected << ">> #<Article id: 2, title: \"second\", body: \"b\">\n"
  expected << ">> \"b\"\n"
  expected << ">> false\n"
  expected << ">> true\n"
  expected << ">> 1\n"
  expected << ">> \n"
  assert_equal expected, session(lines)
end

test "sql, tables, help, a syntax error and a long value" do
  long = "a" * 100
  lines = +""
  lines << "sql \"SELECT count(*) AS n FROM articles\"\n"
  lines << "sql \"SELECT id, title, body FROM articles\"\n"
  lines << "tables\n"
  lines << "Article.where(\n"
  lines << "Article.find(1).update(title: \"#{long}\")\n"
  lines << "Article.find(1)\n"
  lines << "help\n"
  expected = +"0|"
  expected << BANNER
  expected << ">> n\n-\n1\n(1 row)\n"
  expected << ">> id | title | body\n---+-------+-----\n1  | y     | NULL\n(1 row)\n"
  expected << ">> articles\nphotos\n"
  expected << ">> SyntaxError: console:4: unexpected end of expression in 'Article.where('\n"
  expected << ">> true\n"
  expected << ">> #<Article id: 1, title: \"#{"a" * 80}\"…, body: nil>\n"
  out = session(lines)
  assert out.start_with?(expected)
  assert_includes out, "\n>> Expressions are the template language's"
  assert_includes out, "  sql \"SELECT ...\"   run SQL and print the rows\n"
  assert_includes out, "Models: Article, Photo\n>> \n"
end

test "a relation prints its SQL and count; delete_all" do
  lines = +""
  lines << "Article.where(title: \"y\")\n"
  lines << "Article.where(title: \"y\").delete_all\n"
  lines << "Article.count\n"
  lines << "Article.limit(\"x\")\n"
  lines << "Article.frobnicate\n"
  lines << "sql \"SELECT x'00ff01' AS b, NULL AS n\"\n"
  out = session(lines)
  assert_includes out, ">> b         | n\n----------+-----\n<3 bytes> | NULL\n(1 row)\n"
  assert_includes out, ">> #<ArticleRelation SELECT * FROM `articles` WHERE `title` = ? binds: [\"y\"]>\n0 records\n"
  assert_includes out, "\n>> 0\n>> 1\n>> ArgumentError: 'limit' expects an Integer\n"
  assert_includes out, ">> Error: undefined method 'frobnicate' for ArticleRelation\n"
end

test "a stored relation keeps its conditions; offset, where_sql, page, save, errors, reload" do
  lines = +""
  lines << "Article.create(title: \"p1\")\n"
  lines << "Article.create(title: \"p2\")\n"
  lines << "r = Article.where_sql(\"title LIKE ?\", [\"p%\"])\n"
  lines << "r.first.title\n"
  lines << "r.find_by(title: \"p2\").id\n"
  lines << "r.last.id\n"
  lines << "r.count\n"
  lines << "r.find(1)\n"
  lines << "Article.where_sql(\"title LIKE ?\", [\"p%\"]).order(:id).offset(1).to_a\n"
  lines << "Article.where_sql(\"title LIKE ?\", [\"p%\"]).page(2, per: 1).to_a\n"
  lines << "a = Article.find(3)\n"
  lines << "a.update(title: \"\")\n"
  lines << "a.errors\n"
  lines << "a.reload.title\n"
  lines << "a.save\n"
  lines << "sql \"INSERT INTO photos (data, name) VALUES (x'00ff01', 'raw')\"\n"
  lines << "Photo.first\n"
  expected = +"0|"
  expected << BANNER
  expected << ">> #<Article id: 3, title: \"p1\", body: nil>\n"
  expected << ">> #<Article id: 4, title: \"p2\", body: nil>\n"
  expected << ">> #<ArticleRelation SELECT * FROM `articles` WHERE title LIKE ? binds: [\"p%\"]>\n2 records\n"
  expected << ">> \"p1\"\n"
  expected << ">> 4\n"
  expected << ">> 4\n"
  expected << ">> 2\n"
  expected << ">> Cybertrain::RecordNotFound: Couldn't find Article with id=1\n"
  expected << ">> #<Article id: 4, title: \"p2\", body: nil>\n1 record\n"
  expected << ">> #<Article id: 4, title: \"p2\", body: nil>\n1 record\n"
  expected << ">> #<Article id: 3, title: \"p1\", body: nil>\n"
  expected << ">> false\n"
  expected << ">> #<Errors [\"Title can't be blank\"]>\n"
  expected << ">> \"p1\"\n"
  expected << ">> true\n"
  expected << ">> (0 rows)\n"
  expected << ">> #<Photo id: 1, data: <3 bytes>, name: \"raw\">\n"
  expected << ">> \n"
  assert_equal expected, session(lines)
end

test "the production banner, and EOF ends with status 0" do
  config = Cybertrain::Config.new
  config.env = "production"
  out = session("", config)
  assert out.start_with?("0|WARNING: this console runs against the production database")
  assert out.end_with?("Cybertrain console (production). Type help for commands, exit to quit.\n>> \n")
end

test "templates still refuse constants" do
  message = assert_raises("SyntaxError") do
    Cybertrain::Template::Parser.parse_statement("Article.count", "t", 1)
  end
  assert_includes message, "constants are not supported: 'Article'"
end

Cybertrain::Test.run!
