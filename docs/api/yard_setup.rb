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
#    doc comments and docs/*.md read the same here and on GitHub (fenced
#    code blocks, tables, inline code in table cells). Line breaks inside a
#    paragraph are not kept: doc comments are wrapped at 80 columns.
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
          Kramdown::Document.new(text, input: "GFM", hard_wrap: false).to_html
        end
      end
    end
  end
end
