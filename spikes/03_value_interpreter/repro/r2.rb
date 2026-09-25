# SPIKE (throwaway): repro - does tparse.rb compile alone?
require_relative "../tparse"
t = parse_template("a<% if x %>b<% else %>c<% end %><%= y.z(1) %>")
puts t.size
