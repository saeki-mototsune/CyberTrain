# Loaded by YARD (`-e` in .yardopts) before it parses anything.
#
# 1. What the API docs show: an object whose own doc comment says
#    `@api public`, and every namespace on the way to one. Nothing else --
#    the HTTP parser, the template compiler, the generator, the FFI layer --
#    is documented for applications, so it is left out, and a method added
#    later stays out until someone documents it as public. YARD's own
#    `--api public` cannot do this: it copies a namespace's @api tag to
#    every method inside, so tagging Cybertrain::Model would publish its
#    internals too. This reads the comment as written instead.
#
# 2. A public class keeps its public description. Several framework files
#    reopen a class (cybertrain/template/interpreter.rb reopens
#    Cybertrain::Model), and YARD would let the last comment parsed replace
#    the description; a comment without `@api public` never replaces one
#    with it.
#
# 3. Markdown as GitHub renders it: kramdown with its GFM parser, so the
#    doc comments and docs/api/README.md read the same here and on GitHub
#    (fenced code blocks, tables, inline code in table cells). Line breaks
#    inside a paragraph are not kept: doc comments are wrapped at 80 columns.
#
# 4. Relative links in docs/api/README.md, the one Markdown file of the
#    reference (the guides are built by script/guide-pages), as they work on
#    GitHub: a link to a file of the repository goes to it on GitHub. A link
#    that names no file of the repository (`top-level-namespace.html`) is
#    left as it is.
require "kramdown"
require "kramdown-parser-gfm"

module CybertrainApiFilter
  def self.public?(object)
    object.docstring.all.match?(/^@api public$/)
  end

  def self.visible?(object)
    return true if public?(object)

    object.is_a?(YARD::CodeObjects::NamespaceObject) && object.children.any? { |c| visible?(c) }
  end
end

module CybertrainKeepPublicDocstring
  def register_docstring(object, docstring = statement.comments, stmt = statement)
    if object.is_a?(YARD::CodeObjects::NamespaceObject) && CybertrainApiFilter.public?(object)
      text = docstring.is_a?(Array) ? docstring.join("\n") : docstring.to_s
      return unless text.match?(/^@api public$/)
    end
    super
  end
end
YARD::Handlers::Base.prepend(CybertrainKeepPublicDocstring)

module YARD
  module Templates
    module Helpers
      module HtmlHelper
        def html_markup_markdown(text)
          html = Kramdown::Document.new(text, input: "GFM", hard_wrap: false).to_html
          file = options.file
          return html unless file

          root = File.expand_path("../..", __dir__)
          base = File.dirname(File.expand_path(file.filename, root))
          html.gsub(/href="(?![a-z]+:|#|\/)([^"#]*)(#[^"]*)?"/) do
            target, anchor = File.expand_path($1, base), $2.to_s
            next $& unless File.exist?(target) && target.start_with?(root + "/")

            path = target.delete_prefix(root + "/")
            %(href="https://github.com/saeki-mototsune/CyberTrain/blob/main/#{path}#{anchor}")
          end
        end
      end
    end
  end
end
