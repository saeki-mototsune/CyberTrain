# SPIKE (throwaway): debug call_method on Model
require_relative "dbg_lib"
posts = build_posts
p0 = posts[1]
v = call_method(p0, :created_at, "created_at", [])
puts v.class
puts call_method(p0, :title, "title", []).class
puts call_method(p0, :comments, "comments", []).class
puts p0.read_attribute(:created_at).class
env = {}
env["post"] = p0
puts eval_expr(parse_expr("post.created_at"), env).class
puts eval_expr(parse_expr("post.created_at.year"), env)
