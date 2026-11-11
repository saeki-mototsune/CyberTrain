# Cybertrain::TurboStreams -- what {Controller#turbo_stream} returns in an
# action, turbo-rails' controller-side `turbo_stream`:
#
#   def create
#     @comment = Comment.create(comment_params)
#     render turbo_stream: [
#       turbo_stream.append("comments", partial: "comments/comment", locals: { comment: @comment }),
#       turbo_stream.update("count", html: Comment.count.to_s)
#     ]
#   end
#
# Each action returns the `<turbo-stream>` element as a SafeString
# ({Cybertrain::Turbo} builds it); `render turbo_stream:` sends one or an
# Array of them. A partial is rendered with the controller's helpers and
# instance variables, as `render partial:` would, and found the same way
# ("comment" in the controller's view directory, "comments/comment" in
# another).
require "cybertrain/html"
require "cybertrain/turbo"
require "cybertrain/views"
require "cybertrain/template/helpers"

module Cybertrain
  # @api public
  class TurboStreams
    # @param controller [Controller]
    def initialize(controller)
      @controller = controller
    end

    # `<turbo-stream action="replace" target="...">`: the target (a DOM id
    # String, or a record, whose dom_id it is) replaced by exactly one of
    # the partial (with its locals) and `html:` (escaped unless a
    # {SafeString}).
    # @param target [String, Model]
    # @param partial [String] a partial's name, `""` for none
    # @param locals [Hash{Symbol => Object}] the partial's locals
    # @param html [String, SafeString, nil]
    # @return [SafeString]
    # @api public
    def replace(target, partial: "", locals: {}, html: nil)
      stream("replace", target, partial, locals, html)
    end

    # The target's content replaced (see {#replace} for the arguments).
    # @return [SafeString]
    # @api public
    def update(target, partial: "", locals: {}, html: nil)
      stream("update", target, partial, locals, html)
    end

    # Added at the end of the target's content (see {#replace}).
    # @return [SafeString]
    # @api public
    def append(target, partial: "", locals: {}, html: nil)
      stream("append", target, partial, locals, html)
    end

    # Added at the start of the target's content (see {#replace}).
    # @return [SafeString]
    # @api public
    def prepend(target, partial: "", locals: {}, html: nil)
      stream("prepend", target, partial, locals, html)
    end

    # Inserted before the target (see {#replace}).
    # @return [SafeString]
    # @api public
    def before(target, partial: "", locals: {}, html: nil)
      stream("before", target, partial, locals, html)
    end

    # Inserted after the target (see {#replace}).
    # @return [SafeString]
    # @api public
    def after(target, partial: "", locals: {}, html: nil)
      stream("after", target, partial, locals, html)
    end

    # `<turbo-stream action="remove" target="...">`.
    # @param target [String, Model]
    # @return [SafeString]
    # @api public
    def remove(target)
      Turbo.remove(target)
    end

    private

    def stream(action, target, partial, locals, html)
      given = 0
      given += 1 unless partial.empty?
      given += 1 unless html.nil?
      unless given == 1
        msg = "turbo_stream.#{action} needs exactly one of partial:, html:"
        raise ArgumentError, msg
      end
      if partial.empty? && !locals.empty?
        msg = "turbo_stream.#{action} locals: go with partial:, not html:"
        raise ArgumentError, msg
      end
      content = partial.empty? ? Html.out(html) : @controller.partial_body(partial, locals).to_s
      Turbo.action(action, target, SafeString.of(content))
    end
  end
end
