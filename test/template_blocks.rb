require "cybertrain/test"
require "cybertrain/template"

# Blocks on Array and Hash methods in templates: `{ |x| expr }` and
# `do |x| ... end` (docs/guide/template-language.md, "Blocks").
# cybertrain/model links SQLite through FFI, so this program only runs
# compiled: its snapshot comes from the binary (spikes/NOTES.md rule 23).

# A hand-written model in the generated shape (as test/template_interpreter.rb's).
class LineItem < Cybertrain::Model
  def initialize(id, kind, price)
    super()
    set_id(id)
    @kind = kind
    @price = price
  end

  def model_name = "LineItem"

  def read_attribute(name)
    case name
    when :id then @id
    when :kind then @kind
    when :price then @price
    else nil
    end
  end

  def attribute_or_method?(name)
    case name
    when :id, :kind, :price then true
    else false
    end
  end
end

class BlockHelpers < Cybertrain::Template::HelperBase
end

def render_blocks(src, env)
  template = Cybertrain::Template::Template.parse(src, "items/blocks")
  Cybertrain::Template::Interpreter.new(BlockHelpers.new).render(template, env)
end

# A Hash<String, value>, as every template environment.
def blocks_env
  env = {}
  env["nums"] = [3, 1, 2]
  env["words"] = ["pear", "fig", "apple"]
  env["mixed"] = [1, nil, [2, [3, nil]], 1, 2.5]
  env["empty"] = []
  env["counts"] = { "apples" => 3, "pears" => 0, "figs" => 5 }
  env["line_items"] = [LineItem.new(1, "fruit", 3), LineItem.new(2, "veg", 4), LineItem.new(3, "fruit", 5)]
  env["x"] = "outer"
  env
end

def blocks_runtime_error(src)
  assert_raises("Cybertrain::Template::RuntimeError") { render_blocks(src, blocks_env) }
end

def blocks_syntax_error(src)
  assert_raises("Cybertrain::Template::SyntaxError") { render_blocks(src, blocks_env) }
end

test "map with a brace block, then a chained call" do
  assert_equal "6,2,4", render_blocks("<%= nums.map { |x| x * 2 }.join(',') %>", blocks_env)
  assert_equal "PEAR FIG APPLE", render_blocks("<%= words.map { |w| w.upcase }.join(' ') %>", blocks_env)
end

test "select, reject, find, any?, all?, none?, count" do
  env = blocks_env
  assert_equal "3,2", render_blocks("<%= nums.select { |x| x > 1 }.join(',') %>", env)
  assert_equal "1", render_blocks("<%= nums.reject { |x| x > 1 }.join(',') %>", env)
  assert_equal "fig|", render_blocks("<%= words.find { |w| w.size == 3 } %>|<%= words.find { |w| w.size == 9 } %>", env)
  assert_equal "true false", render_blocks("<%= nums.any? { |x| x > 2 } %> <%= nums.any? { |x| x > 3 } %>", env)
  assert_equal "true false", render_blocks("<%= nums.all? { |x| x > 0 } %> <%= nums.all? { |x| x > 1 } %>", env)
  assert_equal "true false", render_blocks("<%= nums.none? { |x| x > 3 } %> <%= nums.none? { |x| x > 2 } %>", env)
  assert_equal "2 3", render_blocks("<%= nums.count { |x| x > 1 } %> <%= nums.count %>", env)
end

test "sum with and without a block" do
  env = blocks_env
  assert_equal "12", render_blocks("<%= line_items.sum { |i| i.price } %>", env)
  assert_equal "6", render_blocks("<%= nums.sum %>", env)
  assert_equal "0", render_blocks("<%= empty.sum %>", env)
  assert_equal "3.5", render_blocks("<%= [1, 2.5].sum %>", env)
  assert_equal "items/blocks:1: sum: use join for Strings", blocks_runtime_error("<%= ['a'].sum %>")
  assert_equal "items/blocks:1: sum: cannot add nil", blocks_runtime_error("<%= [1, nil].sum %>")
  # Kahan-Babuska compensation, as CRuby's Array#sum: 0.6, not 0.6000000000000001.
  assert_equal "0.6 0.6", render_blocks("<%= [0.1, 0.2, 0.3].sum %> <%= [0.1, 0.2, 0.3].sum { |f| f } %>", env)
  assert_equal "3.5", render_blocks("<%= [1, 0.5, 2].sum %>", env)
  assert_equal "items/blocks:1: wrong number of arguments for 'sum'", blocks_runtime_error("<%= nums.sum(10) %>")
  assert_equal "items/blocks:1: wrong number of arguments for 'min'", blocks_runtime_error("<%= nums.min(2) %>")
  assert_equal "items/blocks:1: wrong number of arguments for 'flatten'", blocks_runtime_error("<%= mixed.flatten(1) %>")
end

test "sort_by, min_by, max_by" do
  env = blocks_env
  assert_equal "fig,pear,apple", render_blocks("<%= words.sort_by { |w| w.size }.join(',') %>", env)
  assert_equal "fig apple", render_blocks("<%= words.min_by { |w| w.size } %> <%= words.max_by { |w| w.size } %>", env)
  assert_equal "|", render_blocks("<%= empty.min_by { |w| w } %>|<%= empty.max_by { |w| w } %>", env)
  assert_equal "3,1", render_blocks("<%= line_items.sort_by { |i| 0 - i.price }.map { |i| i.id }.select { |i| i != 2 }.join(',') %>", env)
  assert_equal "items/blocks:1: comparison of String with Integer failed", blocks_runtime_error("<%= ['a', 1].sort_by { |w| w } %>")
end

test "group_by, then each over the groups" do
  src = "<% line_items.group_by { |i| i.kind }.each do |kind, list| %><%= kind %>=<%= list.map { |i| i.id }.join('+') %>;<% end %>"
  assert_equal "fruit=1+3;veg=2;", render_blocks(src, blocks_env)
end

test "each_slice with a do block and as a value" do
  env = blocks_env
  assert_equal "[pear fig][apple ]", render_blocks("<% words.each_slice(2) do |pair| %>[<%= pair.first %> <%= pair[1] %>]<% end %>", env)
  assert_equal "pear/fig;apple/;", render_blocks("<% words.each_slice(2) do |a, b| %><%= a %>/<%= b %>;<% end %>", env)
  assert_equal "2 1", render_blocks("<%= words.each_slice(2).size %> <%= words.each_slice(2).last.size %>", env)
  assert_equal "items/blocks:1: 'each_slice' expects a positive size, got 0", blocks_runtime_error("<%= words.each_slice(0) %>")
end

# Templates cannot mutate an accumulator, so each_with_object is not in the
# table: with or without a block it is an undefined method.
test "each_with_object is an undefined method" do
  assert_equal "items/blocks:1: undefined method 'each_with_object' for Array", blocks_runtime_error("<%= nums.each_with_object([]) %>")
  assert_equal "items/blocks:1: undefined method 'each_with_object' for Array", blocks_runtime_error("<%= nums.each_with_object([]) { |x, acc| x } %>")
  assert_equal "items/blocks:1: undefined method 'each_with_object' for Array", blocks_runtime_error("<% nums.each_with_object([]) do |x, acc| %><% end %>")
  assert_equal "items/blocks:1: undefined method 'nope' for String", blocks_runtime_error("<%= x.nope { |c| c } %>")
  assert_equal "items/blocks:1: undefined method 'nope' for Hash", blocks_runtime_error("<%= counts.nope { |c| c } %>")
end

test "Hash map, select, reject, sort_by, find, any?, all?, sum, to_a" do
  env = blocks_env
  assert_equal "apples:3,pears:0,figs:5", render_blocks("<%= counts.map { |k, v| k + ':' + v.to_s }.join(',') %>", env)
  assert_equal "apples,figs", render_blocks("<%= counts.select { |k, v| v > 0 }.keys.join(',') %>", env)
  assert_equal "pears", render_blocks("<%= counts.reject { |k, v| v > 0 }.keys.join(',') %>", env)
  assert_equal "pears apples figs", render_blocks("<% counts.sort_by { |k, v| 0 - v }.reverse.each do |k, v| %><%= k %> <% end %>", env).strip
  assert_equal "figs=5", render_blocks("<% pair = counts.find { |k, v| v > 4 } %><%= pair[0] %>=<%= pair[1] %>", env)
  assert_equal "true false 8", render_blocks("<%= counts.any? { |k, v| v == 0 } %> <%= counts.all? { |k, v| v > 0 } %> <%= counts.sum { |k, v| v } %>", env)
  assert_equal "3", render_blocks("<%= counts.to_a.size %>", env)
  assert_equal "[&quot;apples&quot;, 3]", render_blocks("<%= counts.map { |pair| pair }.first %>", env)
end

test "Array methods without a block" do
  env = blocks_env
  assert_equal "1 3 apple pear", render_blocks("<%= nums.min %> <%= nums.max %> <%= words.min %> <%= words.max %>", env)
  assert_equal "|", render_blocks("<%= empty.min %>|<%= empty.max %>", env)
  assert_equal "1,2,3 apple,fig,pear", render_blocks("<%= nums.sort.join(',') %> <%= words.sort.join(',') %>", env)
  assert_equal "[1, nil, [2, [3, nil]], 2.5]", render_blocks("<%== mixed.uniq %>", env)
  assert_equal "[1, [2, [3, nil]], 1, 2.5]", render_blocks("<%== mixed.compact %>", env)
  assert_equal "[1, nil, 2, 3, nil, 1, 2.5]", render_blocks("<%== mixed.flatten %>", env)
  assert_equal "3,1 1,2", render_blocks("<%= nums.take(2).join(',') %> <%= nums.drop(1).join(',') %>", env)
  assert_equal "[] []", render_blocks("<%= nums.take(0) %> <%= nums.drop(5) %>", env)
  assert_equal "3pear 1fig 2apple ", render_blocks("<% nums.zip(words).each do |n, w| %><%= n %><%= w %> <% end %>", env)
  assert_equal "items/blocks:1: 'take' expects a non-negative size, got -1", blocks_runtime_error("<%= nums.take(-1) %>")
end

test "do ... end blocks: the last statement is the value" do
  env = blocks_env
  assert_equal "4,2,3", render_blocks("<% bumped = nums.map do |x| %>\n  <% y = x + 1 %>\n  <% y %>\n<% end %><%= bumped.join(',') %>", env)
  assert_equal "[6, 2, 4]", render_blocks("<%== nums.map do |x| %><% x * 2 %><% end %>", env)
  refute env.key?("y")
  assert_equal "items/blocks:1: map's block must end in a value", blocks_runtime_error("<%= nums.map do |x| %><% y = x %><% end %>")
  assert_equal "items/blocks:1: select's block must end in a value", blocks_runtime_error("<%= nums.select do |x| %>text<% end %>")
end

test "a block on a method that takes none is a SyntaxError" do
  assert_equal "items/blocks:1: String#upcase takes no block", blocks_syntax_error("<%= x.upcase { |c| c } %>")
  assert_equal "items/blocks:1: Array#first takes no block", blocks_syntax_error("<%= nums.first { |c| c } %>")
  assert_equal "items/blocks:1: Hash#keys takes no block", blocks_syntax_error("<%= counts.keys { |c| c } %>")
  assert_equal "items/blocks:1: LineItem#price takes no block", blocks_syntax_error("<%= line_items.first.price { |c| c } %>")
  assert_equal "items/blocks:1: a { } block needs a receiver (helper calls take do ... end)", blocks_syntax_error("<%= shout { |c| c } %>")
  assert_equal "items/blocks:1: a do block needs a method call: '1 + 2'", blocks_syntax_error("<% 1 + 2 do |x| %><% end %>")
end

test "block parameters shadow and are restored after the call" do
  env = blocks_env
  assert_equal "6,2,4 outer", render_blocks("<%= nums.map { |x| x * 2 }.join(',') %> <%= x %>", env)
  assert_equal "outer", env["x"]
  refute env.key?("k")
  render_blocks("<%= counts.map { |k, v| v } %>", env)
  refute env.key?("k")
  refute env.key?("v")
end

test "locals and the output are restored when a block raises" do
  env = blocks_env
  env["n"] = [1, 2]
  assert_equal "items/blocks:1: undefined method 'nope' for Integer", assert_raises("Cybertrain::Template::RuntimeError") { render_blocks("<%= n.map { |x| x.nope } %>", env) }
  assert_equal "outer", env["x"]
  assert_raises("Cybertrain::Template::RuntimeError") { render_blocks("<%= n.any? do |x| %><% y = 1 %>text<% x.nope %><% end %>", env) }
  assert_equal "outer", env["x"]
  refute env.key?("y")
  assert_equal "kept outer", render_blocks("kept <%= x %>", env)
end

test "blocks nest" do
  src = "<%= [[1, 2], [3]].map { |row| row.map { |x| x * 10 }.sum }.join(',') %>"
  assert_equal "30,30", render_blocks(src, blocks_env)
end

Cybertrain::Test.run!
