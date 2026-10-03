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
    # NOTES rule 46). 12 is therefore a measured choice, not a guess: the
    # headroom is somewhere under 50, and 12 keeps a wide margin below it.
    # A generous default would trade a clean template error for a SIGSEGV.
    # Nesting used to be unlimited, so this is a visible break on upgrade for
    # an app whose partials legitimately recurse deeper (threaded comments, a
    # category tree: the page and the layout count as renders, leaving about
    # 10 levels): the error past the limit names max_render_depth, and the
    # README says so next to Config#max_render_depth. Such an app raises it
    # through Config#max_render_depth / Views.configure(root, max_render_depth: n).
    MAX_RENDER_DEPTH = 12
  end
end
