# Cybertrain::Template::TurboStreamBuilder -- what `turbo_stream` is in a
# template (turbo-rails' `turbo_stream.replace` and the rest):
#
#   <%= turbo_stream.replace @comment, partial: "comments/comment", locals: { comment: @comment } %>
#   <%= turbo_stream.append "comments", html: "<li>x</li>" %>      (escaped: not a SafeString)
#   <%= turbo_stream.update "count" do %><%= @count %><% end %>
#   <%= turbo_stream.remove @comment %>
#
# replace, update, append, prepend, before and after take a target (a DOM
# id String, or a record, whose dom_id it is) and exactly one of a block,
# `partial:` (with `locals:`, found as `render` finds it from the template)
# and `html:`; remove takes the target alone. Each returns the
# `<turbo-stream>` element as a SafeString ({Cybertrain::Turbo} builds it).
#
# The interpreter hands `turbo_stream.x` to Helpers#call_object_method,
# which calls call_method here (Spinel has no `send`: the actions are a
# `case`). A block is rendered by the helpers before the call and arrives
# as its output, so the builder never holds one (spikes/NOTES.md rule 88).
require "cybertrain/html"
require "cybertrain/turbo"
require "cybertrain/template/form_builder"

module Cybertrain
  module Template
    # @api public
    class TurboStreamBuilder
      # The keywords of the actions that carry content.
      KEYWORDS = %w[partial locals html]

      # helpers: the Template::Helpers rendering the template; interp and
      # env: the template's, for partials.
      def initialize(helpers, interp, env)
        @helpers = helpers
        @interp = interp
        @env = env
      end

      # `turbo_stream.replace(target, partial:, locals:, html:)` and the
      # other actions, without a block.
      # @return [SafeString]
      def call_method(name_sym, args, kwargs)
        build(name_sym, args, kwargs, "", false)
      end

      # The same with a block, whose output (`content`) is the element's
      # content.
      # @return [SafeString]
      def call_method_with_block(name_sym, args, kwargs, content)
        build(name_sym, args, kwargs, content, true)
      end

      # `<%= turbo_stream %>` alone prints nothing.
      def to_s = ""

      private

      def build(name_sym, args, kwargs, content, has_block)
        case name_sym
        when :replace then stream("replace", args, kwargs, content, has_block)
        when :update then stream("update", args, kwargs, content, has_block)
        when :append then stream("append", args, kwargs, content, has_block)
        when :prepend then stream("prepend", args, kwargs, content, has_block)
        when :before then stream("before", args, kwargs, content, has_block)
        when :after then stream("after", args, kwargs, content, has_block)
        when :remove then remove_stream(args, kwargs, has_block)
        else
          msg = "undefined method '#{name_sym}' for turbo_stream"
          raise ArgumentError, msg
        end
      end

      def stream(action, args, kwargs, content, has_block)
        name = "turbo_stream.#{action}"
        Helpers.helper_arity!(name, args, 1, 1)
        Helpers.helper_keywords!(name, kwargs, KEYWORDS, 0)
        given = 0
        given += 1 if has_block
        given += 1 if kwargs.key?("partial")
        given += 1 if kwargs.key?("html")
        unless given == 1
          msg = "#{name} needs exactly one of a block, partial:, html:"
          raise ArgumentError, msg
        end
        html = ""
        if has_block
          html = content
        elsif kwargs.key?("partial")
          rendered = @helpers.partial_html(FormBuilder.value_text(kwargs["partial"]), locals_of(name, kwargs), @interp, @env)
          html = rendered.to_s
        else
          html = FormBuilder.html_text(kwargs["html"])
        end
        Turbo.action(action, args[0], SafeString.of(html))
      end

      def remove_stream(args, kwargs, has_block)
        Helpers.helper_arity!("turbo_stream.remove", args, 1, 1)
        Helpers.helper_no_keywords!("turbo_stream.remove", kwargs)
        raise ArgumentError, "turbo_stream.remove takes no block" if has_block

        Turbo.remove(args[0])
      end

      # locals: as a Hash with String keys (a template's Hash literal has
      # them); none is an empty one.
      def locals_of(name, kwargs)
        given = kwargs["locals"]
        case given
        when Hash then return given
        when nil
          none = { "" => [nil, 0, 0.0, "", true][0] }
          none.delete("")
          return none
        end
        msg = "#{name} locals: must be a Hash"
        raise ArgumentError, msg
      end
    end
  end
end
