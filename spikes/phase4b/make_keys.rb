# Phase 4b spike, item 6 (spec section 12): writes the 2,000-key data the
# other programs read, so they can be regenerated. CRuby only; a record,
# not a test.
#
# Run (from spikes/phase4b/):
#   ruby make_keys.rb
# It rewrites the generated module between the "# BEGIN generated" /
# "# END generated" lines of locale_case.rb (a `case`) and locale_hash.rb
# (a frozen Hash constant), both over the same keys.
#
# The keys: en: -> 40 sections (section_00 .. section_39) x 50 keys
# (key_00 .. key_49) = 2,000 keys. key_49 of sections 00 to 19 is a block
# sequence of 7 day names (20 sequences, for lookup_list); the other 1,980
# are scalars, by key number modulo 5: plain, with an apostrophe, with
# %{name} and double quotes (and, for key_07, an e acute), with %{count},
# and two lines.
DAYS = %w[Sunday Monday Tuesday Wednesday Thursday Friday Saturday].freeze

# [the String of a scalar, or nil for a sequence; the sequence's items, or
# nil] for section s, key k.
def entry(s, k)
  n = (s * 50) + k
  if k == 49 && s < 20
    items = DAYS.map { |d| "#{d}#{s}" }
    return [nil, items]
  end
  case k % 5
  when 0 then ["Value #{n} plain", nil]
  when 1 then ["It's value #{n}: quoted", nil]
  when 2
    if k == 7
      ["Caf\u00e9 %{name} \"#{n}\"", nil]
    else
      ["Hello %{name} \"#{n}\"", nil]
    end
  when 3 then ["about %{count} items #{n}", nil]
  else ["Line one of #{n}\nLine two of %{x}\n", nil]
  end
end

scalars = []
lists = []
40.times do |s|
  50.times do |k|
    text, items = entry(s, k)
    key = "en.section_%02d.key_%02d" % [s, k]
    if items
      lists << [key, items]
    else
      scalars << [key, text]
    end
  end
end

def splice(file, body)
  path = File.join(__dir__, file)
  src = File.read(path, encoding: "UTF-8")
  head, rest = src.split("# BEGIN generated\n", 2)
  _, tail = rest.split("# END generated\n", 2)
  File.write(path, "#{head}# BEGIN generated\n#{body}# END generated\n#{tail}")
end

lit = ->(s) { s.inspect }
case_src = +"module Gen\n  module Locales\n    def self.lookup(key)\n      case key\n"
scalars.each { |k, v| case_src << "      when #{lit.(k)} then #{lit.(v)}\n" }
case_src << "      end\n    end\n\n    def self.lookup_list(key)\n      case key\n"
lists.each { |k, v| case_src << "      when #{lit.(k)} then [#{v.map(&lit).join(", ")}]\n" }
case_src << "      else []\n      end\n    end\n  end\nend\n"
splice("locale_case.rb", case_src)

hash_src = +"module Gen\n  module Locales\n    TEXTS = {\n"
scalars.each { |k, v| hash_src << "      #{lit.(k)} => #{lit.(v)},\n" }
hash_src << "    }.freeze\n    LISTS = {\n"
lists.each { |k, v| hash_src << "      #{lit.(k)} => [#{v.map(&lit).join(", ")}],\n" }
hash_src << "    }.freeze\n\n    def self.lookup(key) = TEXTS[key]\n\n    def self.lookup_list(key) = LISTS.fetch(key, [])\n  end\nend\n"
splice("locale_hash.rb", hash_src)

# The same Hash, filled at load by one small method per 50 keys (40
# methods) instead of one literal: locale_hash_split.rb.
split_src = +"module Gen\n  module Locales\n"
scalars.each_slice(50).with_index do |slice, n|
  split_src << "    def self.fill_%02d(h)\n" % n
  slice.each { |k, v| split_src << "      h[#{lit.(k)}] = #{lit.(v)}\n" }
  split_src << "      h\n    end\n\n"
end
split_src << "    def self.texts\n      h = {}\n"
(scalars.size / 50.0).ceil.times { |n| split_src << "      fill_%02d(h)\n" % n }
split_src << "      h\n    end\n\n    TEXTS = Gen::Locales.texts.freeze\n    LISTS = {\n"
lists.each { |k, v| split_src << "      #{lit.(k)} => [#{v.map(&lit).join(", ")}],\n" }
split_src << "    }.freeze\n\n    def self.lookup(key) = TEXTS[key]\n\n    def self.lookup_list(key) = LISTS.fetch(key, [])\n  end\nend\n"
splice("locale_hash_split.rb", split_src)
puts "#{scalars.size} scalars, #{lists.size} sequences; locale_case.rb, locale_hash.rb, locale_hash_split.rb rewritten"
