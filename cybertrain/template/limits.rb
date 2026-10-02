# Cybertrain::Template::MAX_RENDER_DEPTH -- a leaf file (it requires nothing)
# so that cybertrain/config.rb can read the constant without loading the whole
# template interpreter (html, params, model and through it db and the SQLite
# FFI): every program that loads Config, such as cybertrain/db/cli.rb, would
# pull all of that in otherwise.
module Cybertrain
  module Template
    # How many renders may be nested (page -> partial -> partial ...). A
    # partial that renders itself, or two that render each other, would
    # otherwise recurse until the native stack is gone: SystemStackError is
    # not a StandardError (every rescue misses it) and under Spinel it is a
    # SIGSEGV of the whole process. Past the limit render raises a located
    # Template::RuntimeError like any other template error. Real pages nest
    # a handful of levels (layout, page, a partial or two). The limit is
    # low on purpose: a render costs about 14 frames under CRuby and more
    # under Spinel, whose thread stacks are small -- 50 nested renders
    # already overflowed one in CI (macOS and Linux, test/template_partial_depth.rb;
    # NOTES rule 46). An app whose partials legitimately recurse deeper
    # (threaded comments, a tree menu) raises it through
    # Config#max_render_depth / Views.configure(root, max_render_depth: n).
    MAX_RENDER_DEPTH = 12
  end
end
