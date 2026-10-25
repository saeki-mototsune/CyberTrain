require "cybertrain/test"
require "cybertrain/db"
require "cybertrain/model"
require "cybertrain/params"
require "cybertrain/http/query"
require "cybertrain/pagination"
require "cybertrain/config"

# Relation#page, Page, Params#page_number and Config#max_page (issue #75).
# This program links SQLite through FFI, so it cannot run under CRuby: its
# snapshot comes from the compiled binary (spikes/NOTES.md rule 23).
#
# Item/ItemRelation are hand-written in the shape the model generator emits
# (test/model.rb is the full specification of that shape): Relation#page is
# a base-class method, so a generated relation needs nothing new for it and
# its to_a still returns typed Items.

class ItemRelation < Cybertrain::Relation
  def where(h) = (add_where(h); self)
  def order(o) = (set_order(o); self)
  def limit(n) = (set_limit(n); self)
  def offset(n) = (set_offset(n); self)

  def to_a
    out = Array.new(0) { Item.new }
    found = rows
    i = 0
    while i < found.size
      out << Item.from_row(found[i])
      i += 1
    end
    out
  end

  def each(&blk) = to_a.each(&blk)
  def size = count
end

class Item < Cybertrain::Model
  def self.table_name = "items"
  def self.column_names = ["id", "name", "tag"]
  def model_name = "Item"

  attr_accessor :name, :tag

  def initialize(attrs = {})
    super()
    @name = ""
    @tag = ""
  end

  def self.from_row(row)
    rec = Item.new(Cybertrain::Model::NO_ATTRIBUTES)
    rec.load_row(row)
    rec
  end

  def load_row(row)
    set_id(Cybertrain::Cast.int(row["id"]))
    @name = Cybertrain::Cast.str(row["name"])
    @tag = Cybertrain::Cast.str(row["tag"])
    mark_persisted!
    nil
  end

  def read_attribute(name)
    case name
    when :id then @id
    when :name then @name
    when :tag then @tag
    else nil
    end
  end

  def self.all = ItemRelation.new("items")
end

Cybertrain::DB.connect(":memory:", size: 1)
Cybertrain::DB.with do |c|
  c.execute("CREATE TABLE items (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, tag TEXT NOT NULL)")
  i = 1
  while i <= 25
    c.execute("INSERT INTO items (name, tag) VALUES (?, ?)", ["item#{i}", i.even? ? "even" : "odd"])
    i += 1
  end
end

def names(items)
  items.map { |it| it.name }.join(",")
end

test "page fetches one page of typed records and knows whether more follow" do
  rel = Item.all.order("id")
  pg = rel.page(1, per: 10)
  items = rel.to_a
  assert_equal 10, items.size
  assert_equal "item1", items[0].name
  assert_equal "item10", items[9].name
  assert_equal 1, pg.number
  assert_equal 10, pg.per
  assert_equal 0, pg.row_offset
  assert pg.next?
  assert !pg.prev?
  assert_equal 2, pg.next_number
  assert_equal 1, pg.prev_number
  assert_equal "SELECT * FROM `items` ORDER BY `id` LIMIT 10", rel.to_sql
end

test "the middle and the last page" do
  rel = Item.all.order("id")
  pg = rel.page(2, per: 10)
  assert_equal "item11,item12,item13,item14,item15,item16,item17,item18,item19,item20", names(rel.to_a)
  assert pg.next?
  assert pg.prev?
  assert_equal 10, pg.row_offset
  assert_equal "SELECT * FROM `items` ORDER BY `id` LIMIT 10 OFFSET 10", rel.to_sql

  last = Item.all.order("id")
  lp = last.page(3, per: 10)
  assert_equal "item21,item22,item23,item24,item25", names(last.to_a)
  assert !lp.next?
  assert lp.prev?
  assert_equal 5, last.count
end

test "an exactly full last page has no next page (per + 1 decides)" do
  rel = Item.all.order("id")
  pg = rel.page(5, per: 5)
  assert_equal 5, rel.to_a.size
  assert !pg.next?
  rel = Item.all.order("id")
  pg = rel.page(4, per: 5)
  assert pg.next?
end

test "a page past the last row is empty" do
  rel = Item.all.order("id")
  pg = rel.page(9, per: 10)
  assert_equal 0, rel.to_a.size
  assert !pg.next?
  assert pg.prev?
  assert_equal 8, pg.prev_number
end

test "page keeps where conditions and their binds, and replaces an earlier limit" do
  rel = Item.all.where(tag: "even").order("id DESC").limit(2).offset(7)
  pg = rel.page(2, per: 5)
  assert_equal "item14,item12,item10,item8,item6", names(rel.to_a)
  assert pg.next?
  assert_equal "SELECT * FROM `items` WHERE `tag` = ? ORDER BY `id` DESC LIMIT 5 OFFSET 5", rel.to_sql
end

test "the page number is clamped to 1..Params.max_page" do
  rel = Item.all.order("id")
  assert_equal 1, rel.page(0, per: 10).number
  assert_equal "item1", rel.to_a[0].name
  assert_equal 1, Item.all.page(-7, per: 10).number
  saved = Cybertrain::Params.max_page
  Cybertrain::Params.max_page = 4
  far = Item.all.order("id")
  fp = far.page(1_000_000_000, per: 3)
  assert_equal 4, fp.number
  # The offset ceiling: never past (max_page - 1) * per.
  assert_equal 9, fp.row_offset
  assert_equal "item10,item11,item12", names(far.to_a)
  assert fp.next?
  Cybertrain::Params.max_page = 0
  assert_equal 1, Cybertrain::Params.max_page
  Cybertrain::Params.max_page = saved
  assert_equal 10_000, Cybertrain::Params.max_page
end

test "per outside 1..Page::MAX_PER is a programmer error" do
  msg = assert_raises("ArgumentError") { Item.all.page(1, per: 0) }
  assert_equal "page: per must be from 1 to 1000 (got 0)", msg
  msg = assert_raises("ArgumentError") { Item.all.page(1, per: 1001) }
  assert_equal "page: per must be from 1 to 1000 (got 1001)", msg
end

test "params.page_number reads ?page= safely" do
  assert_equal 3, Cybertrain::Query.parse("page=3").page_number
  assert_equal 1, Cybertrain::Query.parse("q=x").page_number
  assert_equal 1, Cybertrain::Query.parse("page=0").page_number
  assert_equal 1, Cybertrain::Query.parse("page=-2").page_number
  assert_equal 1, Cybertrain::Query.parse("page=abc").page_number
  assert_equal 10_000, Cybertrain::Query.parse("page=999999999").page_number
  # 20 digits: past 2**63-1, where String#to_i raises RangeError under
  # Spinel (NOTES rule 25); the bounded read gives the default instead.
  assert_equal 1, Cybertrain::Query.parse("page=99999999999999999999").page_number
  # The number read straight into Relation#page.
  rel = Item.all.order("id")
  pg = rel.page(Cybertrain::Query.parse("page=3").page_number, per: 10)
  assert_equal 3, pg.number
  assert_equal "item21", rel.to_a[0].name
end

test "Config#max_page comes from CYBERTRAIN_MAX_PAGE, bounded" do
  assert_equal 10_000, Cybertrain::Config.new.max_page
  ENV["CYBERTRAIN_MAX_PAGE"] = "250"
  assert_equal 250, Cybertrain::Config.new.max_page
  ENV["CYBERTRAIN_MAX_PAGE"] = "99999999999999999999"
  assert_equal 10_000, Cybertrain::Config.new.max_page
  ENV["CYBERTRAIN_MAX_PAGE"] = "0"
  assert_equal 10_000, Cybertrain::Config.new.max_page
  ENV["CYBERTRAIN_MAX_PAGE"] = "ten"
  assert_equal 10_000, Cybertrain::Config.new.max_page
  ENV["CYBERTRAIN_MAX_PAGE"] = ""
  config = Cybertrain::Config.new
  assert_equal "", config.max_page_error
  config.max_page = 0
  assert_equal "max_page must be an Integer of at least 1 (got 0)", config.max_page_error
end

Cybertrain::Test.run!
