require "json"
require "cybertrain/context"
require "cybertrain/html"
require "cybertrain/http/client_error"
require "cybertrain/logger"
require "cybertrain/callback"
require "cybertrain/views"
require "cybertrain/template/helpers"
require "cybertrain/generator/inflector"

module Cybertrain
  class MissingTemplate < StandardError
  end

  class UnknownCallback < StandardError
  end

  # Base class of every application controller, through the app's
  # `ApplicationController`. One instance handles one request: the router
  # builds it, runs the before callbacks, the action, the implicit render and
  # the after callbacks.
  #
  #     class ArticlesController < ApplicationController
  #       before_action :set_article, only: [:show, :edit, :update, :destroy]
  #
  #       def index
  #         @articles = Article.all.to_a
  #       end
  #
  #       def new_action   # GET /articles/new: a method named `new` would shadow ArticlesController.new
  #         @article = Article.new
  #       end
  #
  #       def create
  #         @article = Article.new(article_params)
  #         if @article.save
  #           flash[:notice] = "Article was successfully created."
  #           redirect_to article_path(@article), status: :see_other
  #         else
  #           render :new, status: :unprocessable_entity
  #         end
  #       end
  #
  #       private
  #
  #       def set_article
  #         @article = Article.find(params[:id])
  #       end
  #
  #       def article_params
  #         params.require(:article).permit(:title, :body)
  #       end
  #     end
  #
  # Rules that differ from Rails, all because Spinel compiles ahead of time
  # with no `send` or `instance_exec`:
  #
  # - Actions are public methods; the `new` action is `def new_action`
  #   (its view is still `new.html.erb`, its action name `"new"`).
  # - Templates see the instance variables assigned (`@x = ...`) in the
  #   controller's file or its parents' files, found by `spin run gen`; re-run
  #   it after adding one (`cybertrain server` does).
  # - A block callback takes the controller as its argument
  #   (`before_action { |c| ... }`), so it can call public methods only.
  # - `render` and `redirect_to` do not end the action, and a second one
  #   replaces the first; `return` after them when more code follows.
  # - Every controller also has the route helpers (`article_path(...)`,
  #   see {Gen::UrlHelpers}).
  #
  # Implementation: the router calls
  # `process(:show) { |c| c.show }`, so the action name and
  # the action body both arrive as literals (no send).
  #
  # Callback and rescue declarations are runtime data keyed by class name;
  # symbol callbacks are dispatched through run_callback(name), which
  # gen/controllers.rb overrides in each controller with a case table.
  # @api public
  class Controller
    CALLBACKS = {}   # class name => Array<Callback>
    RESCUES = {}     # class name => Array<RescueHandler>

    # The Symbols `status:` accepts in {#render}, {#head} and
    # {#redirect_to}. Any other status must be given as an Integer.
    # @api public
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

    # Runs a method or a block before the action. The chain runs the
    # parent classes' callbacks first, then each class's in declaration order,
    # and stops at the first callback that renders, redirects or calls
    # {#head}: the action, the implicit render and the after callbacks are
    # then skipped.
    #
    # One method name per call. The method is called without a receiver, so
    # it may be private; it must be named on the same line as
    # `before_action` for `spin run gen` to find it.
    #
    # @example
    #   before_action :set_article, only: [:show, :edit, :update, :destroy]
    #   before_action(except: [:index, :show]) { |c| c.head :forbidden unless c.session[:user_id] }
    # @param name [Symbol, nil] a method of this controller, or nil with a block
    # @param only [Array<Symbol>] run for these actions only (`:new` for
    #   `new_action`)
    # @param except [Array<Symbol>] run for every action but these
    # @yieldparam controller [Controller] the controller (no implicit self)
    # @return [nil]
    # @api public
    def self.before_action(name = nil, only: [], except: [], &block)
      add_callback(Callback.new(:before, name, block, only, except))
    end

    # Runs a method or a block after the action and its implicit render,
    # in the same order as {.before_action} (not reversed). Skipped when a
    # before callback halted or anything raised.
    # @example
    #   after_action { |c| c.response.set_header("Cache-Control", "no-store") }
    # @param name [Symbol, nil]
    # @param only [Array<Symbol>]
    # @param except [Array<Symbol>]
    # @yieldparam controller [Controller]
    # @return [nil]
    # @api public
    def self.after_action(name = nil, only: [], except: [], &block)
      add_callback(Callback.new(:after, name, block, only, except))
    end

    def self.add_callback(callback)
      (CALLBACKS[self.name] ||= []) << callback
      nil
    end

    # Handles an exception raised by a callback, the action or its render:
    # `rescue_from NotFound, with: :not_found` or
    # `rescue_from(NotFound) { |c, e| c.head :not_found }`.
    #
    # Unlike Rails, the class must match exactly (a subclass does not), and
    # the first handler found wins, looking in this class before its parents.
    # A `with:` method reads the exception from {#rescued_exception}; keep
    # `with:` on the same line as `rescue_from`. A handler that renders
    # nothing leaves an empty 200.
    #
    # Unhandled, a {Params::ParameterMissing} or malformed query answers 400
    # and anything else 500 (a {RecordNotFound} too: the generated
    # ApplicationController rescues it to a 404).
    # @example
    #   rescue_from Cybertrain::RecordNotFound, with: :record_not_found
    #
    #   private
    #
    #   def record_not_found
    #     render plain: "Not Found", status: :not_found
    #   end
    # @param klass [Class] an exception class
    # @param with [Symbol, nil] a method of this controller, or nil with a block
    # @yieldparam controller [Controller]
    # @yieldparam exception [StandardError]
    # @return [nil]
    # @api public
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
      i = 0
      while i < names.size
        list = CALLBACKS[names[i]]
        unless list.nil?
          j = 0
          while j < list.size
            chain << list[j]
            j += 1
          end
        end
        i += 1
      end
      chain
    end

    def self.rescues_for(klass)
      handlers = []
      k = klass
      while k
        list = RESCUES[k.name]
        unless list.nil?
          j = 0
          while j < list.size
            handlers << list[j]
            j += 1
          end
        end
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

    attr_reader :ctx

    # The request: method, path, headers, raw body.
    # @return [Request]
    # @api public
    attr_reader :request

    # The response being built. {#render}, {#redirect_to} and {#head} fill
    # it; set headers and cookies on it directly.
    # @example
    #   response.set_header("Cache-Control", "no-store")
    # @return [Response]
    # @api public
    attr_reader :response

    # The request parameters: the query string, a urlencoded form body and
    # the route's `:id`-style segments (in that order, later ones winning).
    # @example
    #   params[:id]
    #   params.require(:article).permit(:title, :body)
    # @return [Params]
    # @api public
    attr_reader :params

    # The action being run, by its route name: `"show"`, and `"new"` for
    # `new_action`.
    # @return [String]
    # @api public
    attr_reader :action_name

    # The exception a {.rescue_from} `with:` method is handling.
    # @return [StandardError, nil]
    # @api public
    attr_reader :rescued_exception

    # This visitor's session, kept in a signed cookie.
    #
    # The session and flash installed by SessionStore (nil when the
    # middleware is not in the stack, e.g. in bare unit tests).
    # @return [Session]
    # @api public
    def session
      @ctx.session
    end

    # Messages for the next request (`flash[:notice] = "Saved."` before a
    # redirect) or, through `flash.now`, for this one.
    # @return [Flash]
    # @api public
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
      # keys + while: an each_key block is a Proc and closure per request.
      assign_keys = assigns.keys
      i = 0
      while i < assign_keys.size
        env[assign_keys[i]] = assigns[assign_keys[i]]
        i += 1
      end
      extra_keys = extra.keys
      i = 0
      while i < extra_keys.size
        env[extra_keys[i]] = extra[extra_keys[i]]
        i += 1
      end
      env["flash"] = Template::Helpers.flash_messages(flash)
      env["params"] = @params
      path = controller_path
      env["__template_dir"] = path
      env["__controller_path"] = path
      env
    end

    # "posts" for PostsController: the directory under `app/views/` its
    # templates come from.
    # @return [String]
    # @api public
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

    # Renders the response from a template, text, HTML or JSON: exactly
    # one of template, plain:, html:, json: or partial:.
    #
    # An action that renders nothing renders its own template
    # (`app/views/<controller_path>/<action>.html.erb`) in the layout.
    #
    # - `template`: `app/views/<controller_path>/<template>.html.erb`, always
    #   this controller's directory, inside the layout
    #   (`app/views/layouts/application.html.erb`, when it exists) unless
    #   `layout: false`.
    # - `plain:` the String as `text/plain`.
    # - `html:` as `text/html`; a plain String is escaped, a
    #   {SafeString} is sent as it is.
    # - `json:` as `application/json`; a String is sent as it is (taken to be
    #   JSON already), anything else goes through `JSON.generate`. For a
    #   record, pass {Model#as_json} or {Model#to_json}.
    # - `partial:` `_<name>.html.erb` (`"form"` in this controller's
    #   directory, `"comments/comment"` in another), never in a layout.
    #
    # It does not end the action: a later `render` or `redirect_to`
    # replaces it.
    # @example
    #   render :new, status: :unprocessable_entity
    #   render plain: "Not Found", status: :not_found
    #   render json: { ok: true }, status: :created
    #   render json: @article.to_json
    # @param template [Symbol, String, nil] an action's template, `:new`
    # @param plain [String, nil]
    # @param html [String, SafeString, nil]
    # @param json [Object, nil]
    # @param partial [String, nil]
    # @param status [Integer, Symbol] see {STATUS_SYMBOLS}; 200 by default
    # @param content_type [String, nil] replaces the content type
    # @param locals [Hash{Symbol => Object}] extra template variables
    # @param layout [Boolean] false renders a template without the layout
    # @return [nil]
    # @raise [ArgumentError] when not exactly one of template, `plain:`,
    #   `html:`, `json:`, `partial:` is given, or the status is unknown
    # @raise [Template::MissingTemplate] when the template does not exist
    # @api public
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

    # Answers with a redirect (302 by default) to a URL String: build it with
    # a route helper. After a form submission use `status: :see_other`
    # (303), as the scaffold does, so the browser follows with a GET. It
    # does not end the action. To show a message on the next page, set
    # {#flash} first.
    # @example
    #   flash[:notice] = "Article was successfully created."
    #   redirect_to article_path(@article), status: :see_other
    # @param location [String] a path or URL (a record is not accepted)
    # @param status [Integer, Symbol] see {STATUS_SYMBOLS}
    # @return [nil]
    # @raise [ArgumentError] when the location holds a CR or LF
    # @api public
    def redirect_to(location, status: DEFAULT_REDIRECT_STATUS)
      @response.redirect(location, Controller.status_code(status))
      nil
    end

    # Answers with a status and an empty body.
    #
    # status defaults to :ok only so that Spinel boxes the parameter (see
    # DEFAULT_STATUS); callers are expected to pass one.
    # @example
    #   head :forbidden
    #   head 401
    # @param status [Integer, Symbol] see {STATUS_SYMBOLS}
    # @return [nil]
    # @api public
    def head(status = DEFAULT_STATUS)
      @response.status = Controller.status_code(status)
      @response.body = ""
      @response.performed!
      nil
    end

    # @return [Boolean] true once this request has been rendered,
    #   redirected or answered with {#head}
    # @api public
    def performed?
      @response.performed?
    end

    private

    def run_action(action, body)
      @action_name = action.to_s
      # Built once per request and walked by both passes.
      chain = Controller.chain_for(self.class)
      begin
        if run_before_callbacks(chain, action)
          body.call(self)
          default_render(action) unless performed?
          run_after_callbacks(chain, action)
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

    # false when a callback rendered or redirected (the chain halts). A
    # while loop, not `each` with a `return` inside the block: under Spinel
    # a return out of a block costs a setjmp and a Proc on every call.
    def run_before_callbacks(chain, action)
      i = 0
      n = chain.size
      while i < n
        cb = chain[i]
        if cb.kind == :before && cb.applies?(action)
          run_one(cb)
          return false if performed?
        end
        i += 1
      end
      true
    end

    def run_after_callbacks(chain, action)
      i = 0
      while i < chain.size
        cb = chain[i]
        run_one(cb) if cb.kind == :after && cb.applies?(action)
        i += 1
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
      # a Query.parse of its own past Query's limits) answers 400 with its
      # message in plain text, like Rails' bad-request page, instead of
      # surfacing as a 500. The decision is ClientError's, the same one the
      # error pages use, by class name (NOTES rules 46, 47): comparing the
      # full "Cybertrain::Params::ParameterMissing" here would miss under
      # Spinel, where Class#name is the bare "ParameterMissing". Which
      # headers survive is Response#client_error!'s policy; then performed!
      # so the chain stops. classify also logs the "rejected request" info
      # line, which the error pages write for the same fault one layer up
      # (Cybertrain.logger, as Dev::ErrorPage does), so an answer given here
      # is as visible as one given there. It is called only once status_for
      # has said 400: for anything else classify would log an error line, and
      # this method re-raises that exception to ErrorPages, which classifies
      # (and logs) it again, once, as the 500.
      if ClientError.status_for(e) == 400
        ClientError.classify(e, Cybertrain.logger)
        @response.client_error!(400, e.message)
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
      keys = locals.keys
      i = 0
      while i < keys.size
        out[keys[i].to_s] = locals[keys[i]]
        i += 1
      end
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
