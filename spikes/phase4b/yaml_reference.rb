# Phase 4b spike, item 6a's reference (CRuby only): the files named in
# ARGV through Psych.parse, flattened as yaml_subset.rb flattens them, each
# scalar as its node's text (so `3` stays "3", `false` "false", `:year`
# ":year", D4), a plain `~`, `null` or empty node as "". yaml_subset.rb's
# header has the commands and the result. A record, not a test.
require "yaml"

def text_of(node)
  return "" if node.plain && ["~", "null", ""].include?(node.value)

  node.value
end

def walk(node, prefix, out)
  node.children.each_slice(2) do |k, v|
    key = prefix.empty? ? k.value : "#{prefix}.#{k.value}"
    case v
    when Psych::Nodes::Mapping then walk(v, key, out)
    when Psych::Nodes::Sequence then out << "#{key}=[#{v.children.map { |c| text_of(c) }.join("|")}]"
    else out << "#{key}=#{text_of(v)}"
    end
  end
end

ARGV.each do |path|
  out = []
  walk(Psych.parse(File.read(path)).root, "", out)
  out.map { |l| l.gsub("\n", "\\n") }.sort.each { |l| puts l }
end
