require "json"
require "cybertrain/context"
require "cybertrain/html"
require "cybertrain/http/client_error"
require "cybertrain/callback"
require "cybertrain/views"
require "cybertrain/template/helpers"
require "cybertrain/generator/inflector"

module Cybertrain
  class MissingTemplate < StandardError
  end

  class UnknownCallback < StandardError
  end

  # Base class of every application controller. The router builds one per
  # request and calls `process(:show) { |c| c.show }`, so the action name and
  # the action body both arrive as literals (no send).
  #
  # Callback and rescue declarations are runtime data keyed by class name;
  # symbol callbacks are dispatched through run_callback(name), which
  # gen/controllers.rb overrides in each controller with a case table.
  class Controller
    CALLBACKS = {}   # class name => Array<Callback>
    RESCUES = {}     # class name => Array<RescueHandler>

    STATUS_SYMBOLS = {
      ok: 200, created: 201, no_content: 204,
      moved_permanently: 301, found: 302, see_other: 303,
      bad_request: 400, forbidden: 403, not_found: 404,
      unprocessable_entity: 422, internal_server_error: 500
    }

    # Default statuses for render/head and redirect_to. They are 200 and 302
    # under CRuby, but Spinel types them as polymorphic values (an element
    # of a mixed Integer/Symbol Array), and that is the point: Spinel types a
    # parameter from its direct call sites and its default only, never from
    # calls made inside stored blocks. With a plain `status: 200` default, an
    # app whose only symbolic call is `before_action { |c| c.head :forbidden }`
    # or `rescue_from(X) { |c, e| c.head :not_found }` gets an sp_int
    # parameter and the Symbol's internal id arrives as the status. A
    # polymorphic default keeps the parameter boxed whatever the call-site
    # mix is. (test/controller_status.rb)
    DEFAULT_STATUS = [200, :ok][0]
    DEFAULT_REDIRECT_STATUS = [302, :found][0]

    def self.before_action(name = nil, only: [], except: [], &block)
      add_callback(Callback.new(:before, name, block, only, except))
    end

    def self.after_action(name = nil, only: [], except: [], &block)
      add_callback(Callback.new(:after, name, block, only, except))
    end

    def self.add_callback(callback)
      (CALLBACKS[self.name] ||= []) << callback
      nil
    end

    # `rescue_from NotFound, with: :not_found` or
    # `rescue_from(NotFound) { |c, e| c.head :not_found }`.
    def self.rescue_from(klass, with: nil, &block)
      (RESCUES[self.name] ||= []) << RescueHandler.new(klass.name, with, block)
      nil
    end

    # The class is passed in rather than read from self: an inherited class
    # method called as self.class.chain_for binds self to the base class
    # under Spinel.
    def self.chain_for(klass)
      names = []
      k = klass
      while k
        names.unshift(k.name)
        break if k == Controller

        k = k.superclass
      end
      chain = []
      names.each do |n|
        list = CALLBACKS[n]
        list.each { |cb| chain << cb } unless list.nil?
      end
      chain
    end

    def self.rescues_for(klass)
      handlers = []
      k = klass
      while k
        list = RESCUES[k.name]
        list.each { |h| handlers << h } unless list.nil?
        break if k == Controller

        k = k.superclass
      end
      handlers
    end

    # Always returns a plain Integer: the result lands in Response#status,
    # which must stay an unboxed Integer for the rest of the stack.
    def self.status_code(value)
      code = -1
      case value
      when Integer then code = value.to_i
      else code = STATUS_SYMBOLS.fetch(value, -1).to_i
      end
      raise ArgumentError, "unknown status #{value.inspect}" if code < 0

      code
    end

    attr_reader :ctx, :request, :response, :params, :action_name, :rescued_exception

    # The session and flash installed by SessionStore (nil when the
    # middleware is not in the stack, e.g. in bare unit tests).
    def session
      @ctx.session
    end

    def flash
      @ctx.flash
    end

    def initialize(ctx)
      @ctx = ctx
      @request = ctx.request
      @response = ctx.response
      @params = ctx.params
      @action_name = ""
      @rescued_exception = nil
    end

    # Runs the before callbacks (stopping as soon as one renders or
    # redirects), the action body (the block), the implicit render, then the
    # after callbacks. An exception is handed to the first matching
    # rescue_from handler, or re-raised when there is none.
    #
    # The work happens in run_action, which takes the block as a plain Proc:
    # Spinel inlines a method that yields at every call site with self typed
    # as the subclass, and both `yield self` and a `rescue => e` inside such
    # an inlined body produce C that does not compile.
    def process(action, &body)
      run_action(action, body)
    end

    def run_callback(name)
      raise UnknownCallback, "unknown callback :#{name} in #{self.class.name} (run `spin run gen`)"
    end

    # The implicit render after an action that rendered nothing:
    # app/views/<controller_path>/<action>.html.erb inside the layout.
    def default_render(action)
      raise MissingTemplate, "no template for #{self.class.name}##{action}" if Views.engine.nil?

      render_template(action.to_s)
    end

    # The instance variables templates can read, as { "post" => @post };
    # gen/controllers.rb overrides it in every controller.
    def view_assigns
      {}
    end

    # What a template sees: view_assigns, then the locals (extra, keyed by
    # String), then flash (a Hash of the current messages), params and the
    # directory partials are looked up in.
    def view_env(extra)
      env = {}
      assigns = view_assigns
      assigns.each_key { |key| env[key] = assigns[key] }
      extra.each_key { |key| env[key] = extra[key] }
      env["flash"] = Template::Helpers.flash_messages(flash)
      env["params"] = @params
      path = controller_path
      env["__template_dir"] = path
      env["__controller_path"] = path
      env
    end

    # "posts" for PostsController.
    def controller_path
      name = Inflector.underscore(self.class.name)
      name.end_with?("_controller") ? name[0, name.length - 11] : name
    end

    # Renders <controller_path>/<name> with the process-wide Views engine,
    # inside Views.layout_name when that layout exists and layout is true.
    def render_template(name, locals = {}, layout: true)
      engine = Views.engine
      raise MissingTemplate, "no template #{name} for #{self.class.name}" if engine.nil?

      path = "#{controller_path}/#{name}"
      env = view_env(string_keys(locals))
      helpers = Template::Helpers.new(self)
      frame = Views.layout_name
      if layout && !frame.empty? && engine.exists?(frame)
        send_html(engine.render_with_layout(path, frame, env, helpers))
      else
        send_html(engine.render(path, env, helpers))
      end
    end

    # Exactly one of template, plain:, html:, json: or partial:.
    #
    #   render :new, status: :unprocessable_entity
    #   render :show, layout: false
    #   render partial: "form", locals: { post: @post }   (never a layout)
    def render(template = nil, plain: nil, html: nil, json: nil, status: DEFAULT_STATUS, content_type: nil,
               partial: nil, locals: {}, layout: true)
      given = 0
      given += 1 unless template.nil?
      given += 1 unless plain.nil?
      given += 1 unless html.nil?
      given += 1 unless json.nil?
      given += 1 unless partial.nil?
      raise ArgumentError, "render needs exactly one of template, plain:, html:, json:, partial:" if given != 1

      @response.status = Controller.status_code(status)
      if !plain.nil?
        @response.body = plain
        @response.content_type = "text/plain; charset=utf-8"
      elsif !html.nil?
        @response.body = Html.out(html)
        @response.content_type = "text/html; charset=utf-8"
      elsif !json.nil?
        @response.body = json_body(json)
        @response.content_type = "application/json; charset=utf-8"
      elsif !partial.nil?
        render_partial(partial.to_s, locals)
      else
        render_template(template.to_s, locals, layout: layout)
      end
      @response.content_type = content_type unless content_type.nil?
      @response.performed!
      nil
    end

    def redirect_to(location, status: DEFAULT_REDIRECT_STATUS)
      @response.redirect(location, Controller.status_code(status))
      nil
    end

    # status defaults to :ok only so that Spinel boxes the parameter (see
    # DEFAULT_STATUS); callers are expected to pass one.
    def head(status = DEFAULT_STATUS)
      @response.status = Controller.status_code(status)
      @response.body = ""
      @response.performed!
      nil
    end

    def performed?
      @response.performed?
    end

    private

    def run_action(action, body)
      @action_name = action.to_s
      begin
        if run_before_callbacks(action)
          body.call(self)
          default_render(action) unless performed?
          run_after_callbacks(action)
        end
      rescue JSON::ParserError, StandardError => e
        # JSON::ParserError named (NOTES rule 33: not a StandardError under
        # Spinel) so an action's bad JSON.parse goes through
        # rescue_with_handler like any other exception. A `rescue_from
        # JSON::ParserError` handler fires under CRuby; under Spinel the
        # constant cannot be referenced as a value (rule 48), so no app can
        # register one there and the exception goes on to the error pages.
        rescue_with_handler(e)
      end
      nil
    end

    # false when a callback rendered or redirected (the chain halts).
    def run_before_callbacks(action)
      Controller.chain_for(self.class).each do |cb|
        next unless cb.kind == :before && cb.applies?(action)

        run_one(cb)
        return false if performed?
      end
      true
    end

    def run_after_callbacks(action)
      Controller.chain_for(self.class).each do |cb|
        run_one(cb) if cb.kind == :after && cb.applies?(action)
      end
      nil
    end

    def run_one(cb)
      name = cb.name
      if name.nil?
        cb.block.call(self)
      else
        run_callback(name)
      end
    end

    # Re-raises e when no rescue_from handler matches its class name.
    def rescue_with_handler(e)
      class_name = e.class.name
      Controller.rescues_for(self.class).each do |h|
        next unless h.class_name == class_name

        @rescued_exception = e
        with = h.with
        if with.nil?
          h.block.call(self, e)
        else
          run_callback(with)
        end
        return nil
      end
      # A client fault raised inside an action (a missing required parameter;
      # a Query.parse of its own past Query's limits) answers 400
      # with its message in plain text, like Rails' bad-request page, instead
      # of surfacing as a 500. The decision is ClientError's, the same one the
      # error pages use, by class name (NOTES rules 46, 47): comparing the
      # full "Cybertrain::Params::ParameterMissing" here would miss under
      # Spinel, where Class#name is the bare "ParameterMissing".
      #
      # reset_to, not render(plain:, status: 400): the action may already have
      # set a cookie, called redirect_to or set Content-Disposition before the
      # parameter error raised, and ErrorPages, Dev::ErrorPage and Server all
      # drop those the same way (a stale Location or attachment header would
      # hide the 400). It leaves a text/plain 400 whose body is the message
      # ("" would become the status text), then performed! so the chain stops.
      if ClientError.status(e) == 400
        @response.reset_to(400, e.message)
        @response.performed!
        return nil
      end
      raise e
    end

    def render_partial(name, locals)
      engine = Views.engine
      raise MissingTemplate, "no partial #{name} for #{self.class.name}" if engine.nil?

      path = Template::Helpers.partial_path(controller_path, name)
      given = string_keys(locals)
      Template::Helpers.check_locals(engine.template(path), given.keys)
      send_html(engine.render(path, view_env(given), Template::Helpers.new(self)))
    end

    def send_html(body)
      @response.body = body
      @response.content_type = "text/html; charset=utf-8"
      @response.performed!
      nil
    end

    # `locals: { post: @post }` comes with Symbol keys; templates look
    # names up by String.
    def string_keys(locals)
      out = {}
      locals.each_key { |key| out[key.to_s] = locals[key] }
      out
    end

    # A String is taken to be JSON already.
    def json_body(value)
      case value
      when String then value
      else JSON.generate(value)
      end
    end
  end
end
